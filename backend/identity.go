package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/hkdb/flugo/pkg/bridge"
	"github.com/hkdb/flugo/pkg/keyring"
	"github.com/instacryptio/icfx/bundle"
	"github.com/instacryptio/icfx/config"
	"github.com/instacryptio/icfx/crypto"
	"github.com/instacryptio/icfx/format"
	"github.com/instacryptio/icfx/hardware/chalresp"
	"github.com/instacryptio/icfx/identity"
	"github.com/instacryptio/icfx/identity/handoff"
	"github.com/instacryptio/icfx/keystore"
	"github.com/instacryptio/icfx/profile"
	"github.com/instacryptio/icfx/qr"
	"github.com/instacryptio/icfx/validate"
)

// KeychainAvailable returns whether OS keychain or platform keyring is available.
// On Android, surfaces JNI diagnostic errors so they can be displayed in the UI.
func (s *IcfxService) KeychainAvailable() (bool, error) {
	if keystore.KeychainAvailable() {
		return true, nil
	}
	if runtime.GOOS == "android" {
		kr := keyring.New()
		if kr.Available() {
			return true, nil
		}
		// Surface the JNI diagnostic error so it shows in the UI
		if diag := keyring.LastError(); diag != "" {
			return false, fmt.Errorf("android keyring unavailable: %s", diag)
		}
		return false, fmt.Errorf("android keyring unavailable (JNI status: %s)", bridge.JNIStatus())
	}
	return false, nil
}

// HasKeys checks whether the user has any identities. Reads only the
// plaintext index — no unlock, no passphrase needed.
func (s *IcfxService) HasKeys() (bool, error) {
	idStore, err := newIdentityStore()
	if err != nil {
		return false, err
	}
	entries, err := idStore.LoadIndex()
	if err != nil {
		return false, fmt.Errorf("loading identity index: %w", err)
	}
	return len(entries) > 0, nil
}

// ShouldShowWelcome reports whether the first-launch welcome wizard should be
// shown. A persisted welcome_completed flag is authoritative; on the very first
// run an existing standalone user (who already has identities) is migrated by
// setting the flag so the wizard never appears for them.
func (s *IcfxService) ShouldShowWelcome() (bool, error) {
	ensurePathsApplied()
	cfg, err := config.Load()
	if err != nil {
		return false, fmt.Errorf("loading config: %w", err)
	}
	if cfg.WelcomeCompleted {
		return false, nil
	}
	hasKeys, err := s.HasKeys()
	if err != nil {
		return false, err
	}
	if hasKeys {
		// Existing user upgrading into the wizard build: mark done, don't onboard.
		cfg.WelcomeCompleted = true
		if err := cfg.Save(); err != nil {
			return false, fmt.Errorf("saving config: %w", err)
		}
		return false, nil
	}
	return true, nil
}

// MarkWelcomeCompleted persists that the welcome wizard has been finished or
// skipped, so it never re-shows. Called on every wizard exit path.
func (s *IcfxService) MarkWelcomeCompleted() error {
	ensurePathsApplied()
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	cfg.WelcomeCompleted = true
	if err := cfg.Save(); err != nil {
		return fmt.Errorf("saving config: %w", err)
	}
	return nil
}

// ListIdentities returns the index entries (name + alias + backend + hw flag)
// as a JSON array. Alias is plaintext in the index, so it surfaces here without
// unlocking; the rest of the rich metadata (email, public keys, etc.) lives in
// per-identity encrypted meta files and is fetched on-demand via ShowIdentity —
// that's the strict-minimum-plaintext design.
func (s *IcfxService) ListIdentities() (string, error) {
	idStore, err := newIdentityStore()
	if err != nil {
		return "", err
	}
	entries, err := idStore.LoadIndex()
	if err != nil {
		return "", fmt.Errorf("loading identity index: %w", err)
	}

	def := resolveDefaultIdentityName(entries)
	out := make([]map[string]interface{}, 0, len(entries))
	for _, e := range entries {
		out = append(out, map[string]interface{}{
			"name":       e.Name,
			"alias":      e.Alias,
			"backend":    e.Backend,
			"hw_key":     e.HWKey,
			"is_default": e.Name == def,
		})
	}

	data, err := json.Marshal(out)
	if err != nil {
		return "", fmt.Errorf("marshaling identities: %w", err)
	}
	return string(data), nil
}

// ShowIdentity returns a single identity's full metadata as JSON. Requires
// unlocking the identity (decrypts the per-identity meta file).
func (s *IcfxService) ShowIdentity(name string) (string, error) {
	unlocked, err := openIdentity(name)
	if err != nil {
		return "", fmt.Errorf("opening identity %q: %w", name, err)
	}
	defer unlocked.Close()

	data, err := json.Marshal(unlocked.Info())
	if err != nil {
		return "", fmt.Errorf("marshaling identity: %w", err)
	}
	return string(data), nil
}

// EditIdentity updates mutable fields of an identity. Backend is not editable
// (storage decision, not metadata). HWKey is toggleable via hwAction:
//
//   - ""        — no change to HW state
//   - "enable"  — turn HW protection ON (re-encrypt keys with HW-augmented KEK)
//   - "disable" — turn HW protection OFF (re-encrypt with passphrase-only KEK)
//
// Enable/disable is a re-encryption operation: the existing keys are loaded
// under the current KEK, then written back under the new KEK. Rollback is
// best-effort in-memory — if any post-write step fails, the original
// plaintext key bytes (still held in memory from the load) are written
// back under the original keystore so the identity is restored to its
// pre-toggle state.
//
// Mirrors ic-cli's enableHWKey / disableHWKey
// (`internal/cli/identity_hwkey.go:68-193`).
func (s *IcfxService) EditIdentity(name, alias, email, firstName, lastName, hwAction string) (string, error) {
	alias = strings.ToLower(strings.TrimSpace(alias))
	if err := validate.Alias(alias); err != nil {
		return "", err
	}
	idStore, entries, idx, err := resolveIdentity(name)
	if err != nil {
		return "", err
	}
	// Resolve to the canonical name (the caller may have passed an alias) so the
	// uniqueness self-exclusion and index sync below key off the right entry.
	name = idx.Name
	if err := identity.CheckAliasUnique(entries, alias, name); err != nil {
		return "", err
	}

	unlocked, err := openIdentity(name)
	if err != nil {
		return "", fmt.Errorf("opening identity %q: %w", name, err)
	}
	id := unlocked.Info()
	id.Alias = alias
	id.Email = email
	id.FirstName = firstName
	id.LastName = lastName

	hwChanged := false
	switch hwAction {
	case "", "no-change":
		// metadata-only edit
	case "enable":
		if id.HWKey {
			unlocked.Close()
			return "", fmt.Errorf("identity %q is already hardware-key-protected", name)
		}
		if err := toggleHWKeyOn(idx, &id); err != nil {
			unlocked.Close()
			return "", err
		}
		hwChanged = true
	case "disable":
		if !id.HWKey {
			unlocked.Close()
			return "", fmt.Errorf("identity %q is not hardware-key-protected", name)
		}
		if err := toggleHWKeyOff(idx, &id); err != nil {
			unlocked.Close()
			return "", err
		}
		hwChanged = true
	default:
		unlocked.Close()
		return "", fmt.Errorf("unknown hwAction %q (want \"\", \"enable\", or \"disable\")", hwAction)
	}

	if err := idStore.SaveMeta(id); err != nil {
		unlocked.Close()
		return "", fmt.Errorf("saving identity meta: %w", err)
	}
	unlocked.Close()

	// Sync the plaintext index: the alias always (it's the readable-without-
	// unlock copy that drives filenames + selection) and the HWKey flag when it
	// changed (so subsequent loads pick the right keystore dispatch).
	for i := range entries {
		if entries[i].Name == name {
			entries[i].Alias = id.Alias
			if hwChanged {
				entries[i].HWKey = id.HWKey
			}
			break
		}
	}
	if err := idStore.SaveIndex(entries); err != nil {
		return "", fmt.Errorf("saving identity index: %w", err)
	}
	if hwChanged {
		// Clear cached HW session so the next op re-detects (lets the user
		// swap devices between toggle-on and the next crypto operation
		// without weird state).
		closeSessionHWKey()
	}

	return "Identity updated", nil
}

// toggleHWKeyOn re-encrypts an existing identity's stored keys with the
// HW-augmented KEK. Mirrors ic-cli's `enableHWKey`.
func toggleHWKeyOn(idx *identity.IdentityIndex, id *identity.Identity) error {
	keysDir, err := config.KeysDir()
	if err != nil {
		return fmt.Errorf("resolving keys directory: %w", err)
	}

	srcKs, err := nonHWStoreForBackend(idx.Backend)
	if err != nil {
		return err
	}
	encID, err := srcKs.LoadEncryptionIdentity(id.Name)
	if err != nil {
		return fmt.Errorf("loading existing encryption key: %w", err)
	}
	signKey, err := srcKs.LoadSigningKey(id.Name)
	if err != nil {
		return fmt.Errorf("loading existing signing key: %w", err)
	}

	hw, err := openDesktopHWChalresp()
	if err != nil {
		return err
	}
	programmed, err := chalresp.IsSlot2Programmed(hw.Descriptor())
	if err != nil {
		return fmt.Errorf("reading hardware key status: %w", err)
	}
	if !programmed {
		return fmt.Errorf("hardware key's slot 2 is not programmed for HMAC-SHA1 challenge-response. Program it first via ykman or KeePassXC, then retry")
	}

	passFn := hwPassFnForBackend(idx.Backend, id.Name)
	hwDec := keystore.NewHardwareKeyDecorator(plainInnerForBackend(idx.Backend, keysDir), hw, keysDir, passFn)

	challenge, err := hwDec.EnsureChallenge(id.Name)
	if err != nil {
		return fmt.Errorf("generating challenge: %w", err)
	}
	if _, err := hw.Challenge(challenge); err != nil {
		_ = hwDec.RemoveChallenge(id.Name)
		return fmt.Errorf("hardware key smoke test failed: %w", err)
	}

	rollback := func() {
		_ = srcKs.StoreEncryptionIdentity(id.Name, encID)
		_ = srcKs.StoreSigningKey(id.Name, signKey)
		_ = hwDec.RemoveChallenge(id.Name)
	}

	if err := hwDec.StoreEncryptionIdentity(id.Name, encID); err != nil {
		rollback()
		return fmt.Errorf("re-encrypting encryption key with HW KEK: %w", err)
	}
	if err := hwDec.StoreSigningKey(id.Name, signKey); err != nil {
		rollback()
		return fmt.Errorf("re-encrypting signing key with HW KEK: %w", err)
	}

	// Verify round-trip via a fresh decorator instance before declaring success.
	verifyDec := keystore.NewHardwareKeyDecorator(plainInnerForBackend(idx.Backend, keysDir), hw, keysDir, passFn)
	if _, err := verifyDec.LoadEncryptionIdentity(id.Name); err != nil {
		rollback()
		return fmt.Errorf("verification failed after HW re-encryption (encryption key): %w", err)
	}
	if _, err := verifyDec.LoadSigningKey(id.Name); err != nil {
		rollback()
		return fmt.Errorf("verification failed after HW re-encryption (signing key): %w", err)
	}

	id.HWKey = true
	return nil
}

// toggleHWKeyOff reverses toggleHWKeyOn: loads keys via the HW decorator
// (triggering a touch), re-encrypts with the configured non-HW backend,
// and deletes the challenge file. Mirrors ic-cli's `disableHWKey`.
func toggleHWKeyOff(idx *identity.IdentityIndex, id *identity.Identity) error {
	keysDir, err := config.KeysDir()
	if err != nil {
		return fmt.Errorf("resolving keys directory: %w", err)
	}

	hw, err := openDesktopHWChalresp()
	if err != nil {
		return err
	}
	passFn := hwPassFnForBackend(idx.Backend, id.Name)
	hwDec := keystore.NewHardwareKeyDecorator(plainInnerForBackend(idx.Backend, keysDir), hw, keysDir, passFn)

	encID, err := hwDec.LoadEncryptionIdentity(id.Name)
	if err != nil {
		return fmt.Errorf("loading existing encryption key with HW KEK: %w", err)
	}
	signKey, err := hwDec.LoadSigningKey(id.Name)
	if err != nil {
		return fmt.Errorf("loading existing signing key with HW KEK: %w", err)
	}

	dstKs, err := nonHWStoreForBackend(idx.Backend)
	if err != nil {
		return err
	}

	rollback := func() {
		_ = hwDec.StoreEncryptionIdentity(id.Name, encID)
		_ = hwDec.StoreSigningKey(id.Name, signKey)
	}

	if err := dstKs.StoreEncryptionIdentity(id.Name, encID); err != nil {
		rollback()
		return fmt.Errorf("re-encrypting encryption key with passphrase only: %w", err)
	}
	if err := dstKs.StoreSigningKey(id.Name, signKey); err != nil {
		rollback()
		return fmt.Errorf("re-encrypting signing key with passphrase only: %w", err)
	}

	// Verify round-trip with a fresh non-HW store before removing the challenge.
	verifyKs, err := nonHWStoreForBackend(idx.Backend)
	if err != nil {
		rollback()
		return err
	}
	if _, err := verifyKs.LoadEncryptionIdentity(id.Name); err != nil {
		rollback()
		return fmt.Errorf("verification failed after passphrase re-encryption (encryption key): %w", err)
	}
	if _, err := verifyKs.LoadSigningKey(id.Name); err != nil {
		rollback()
		return fmt.Errorf("verification failed after passphrase re-encryption (signing key): %w", err)
	}

	// Re-encryption verified. Delete the challenge file. Failure here is
	// non-fatal — the stored bytes can no longer decrypt with HW KEK and
	// the decorator would surface that error clearly if anyone tried.
	_ = hwDec.RemoveChallenge(id.Name)

	id.HWKey = false
	return nil
}

// RemoveIdentity removes a specific identity by name. Wipes the keystore
// entry, deletes the encrypted meta file, and removes the index entry.
// Refuses to remove the configured default identity if other identities
// exist (set a different default first).
// RemoveIdentity deletes an identity. Delete + re-key orchestration lives in
// icfx/handoff: it blocks removing the only identity, and when the victim is the
// default it re-keys the self-lock cloud resources (contacts/groups/settings) to
// the chosen successor before deleting so those blobs don't orphan. When the
// victim is the default and no successor is supplied, it returns a JSON marker
// {"need_successor":true,"candidates":[...]} for the UI to prompt on and retry.
func (s *IcfxService) RemoveIdentity(name, successor string, force bool) (string, error) {
	cfg, err := config.Load()
	if err != nil {
		return "", fmt.Errorf("loading config: %w", err)
	}

	// Accept a name OR an alias: resolve to the canonical name, since
	// handoff.HandoffAndDelete keys by name.
	_, _, idx, err := resolveIdentity(name)
	if err != nil {
		return "", err
	}
	name = idx.Name

	ctx := context.Background()
	c := cloudClientIfEnabled(ctx)
	host := newHandoffHost(cfg)
	defer host.close()

	err = handoff.HandoffAndDelete(ctx, c, cfg, name, successor, host, force)
	if err == nil {
		return "Identity removed", nil
	}
	// Only identity and not forced: hand the UI a marker so it can show the
	// danger dialog and retry with force=true. (With force, handoff bypasses
	// this and deletes — abandoning cloud data sealed to it until re-keyed from
	// a device that still holds the up-to-date copy.)
	if errors.Is(err, handoff.ErrLastIdentity) {
		raw, merr := json.Marshal(map[string]any{"need_force": true})
		if merr != nil {
			return "", merr
		}
		return string(raw), nil
	}
	var need *handoff.SuccessorRequiredError
	if errors.As(err, &need) {
		raw, merr := json.Marshal(map[string]any{"need_successor": true, "candidates": need.Candidates})
		if merr != nil {
			return "", merr
		}
		return string(raw), nil
	}
	return "", err
}

// SetDefaultIdentity changes the default identity, re-keying the self-lock cloud
// resources to it (via icfx/handoff) so contacts/groups/settings don't orphan.
func (s *IcfxService) SetDefaultIdentity(name string) (string, error) {
	cfg, err := config.Load()
	if err != nil {
		return "", fmt.Errorf("loading config: %w", err)
	}
	_, _, idx, err := resolveIdentity(name)
	if err != nil {
		return "", err
	}
	// Accept a name OR an alias; handoff + config key by the canonical name.
	name = idx.Name

	ctx := context.Background()
	c := cloudClientIfEnabled(ctx)
	host := newHandoffHost(cfg)
	defer host.close()

	if err := handoff.SetDefault(ctx, c, cfg, name, host); err != nil {
		return "", err
	}
	return "Default identity updated", nil
}

// RekeyCloudData re-seals every self-lock cloud resource (contacts snapshot,
// settings, groups, notifications) to the CURRENT default identity from this
// device's local data. It repairs cloud blobs left sealed to a superseded key —
// e.g. after deleting the last identity then creating/importing a new default,
// which no handoff re-keyed, so the blobs stay unreadable on other devices.
// Run it on the device that HOLDS the data (the empty-source guard makes it a
// safe no-op on a device without it). Requires cloud on + signed in.
func (s *IcfxService) RekeyCloudData() (string, error) {
	cfg, err := config.Load()
	if err != nil {
		return "", fmt.Errorf("loading config: %w", err)
	}
	ctx := context.Background()
	c := cloudClientIfEnabled(ctx)
	if c == nil {
		return "", fmt.Errorf("cloud is off or not signed in")
	}
	host := newHandoffHost(cfg)
	defer host.close()

	if err := handoff.RekeyDefault(ctx, c, cfg, host); err != nil {
		return "", err
	}
	return "Cloud data re-keyed to your current identity", nil
}

// CreateKeys generates a new identity keypair and stores it. The new identity's
// backend is recorded as the configured default backend at creation time —
// switching the global keystore setting later does not migrate existing
// identities.
//
// When useHWKey is true the new identity is protected with a hardware key
// (the 2nd factor; 1st factor is whatever the backend provides at rest).
// The hardware key must be plugged in, slot 2 must already be programmed
// for HMAC-SHA1 challenge-response (via ykman or KeePassXC — icfx does
// not program slots), and a smoke-test challenge runs before any keys
// are written. Failure at any HW step rolls back without leaving partial
// state on disk.
func (s *IcfxService) CreateKeys(name, alias, email, firstName, lastName string, useHWKey bool) (string, error) {
	// The name becomes a filesystem path component (keystore/meta files) —
	// reject separators / traversal / control chars up front.
	if err := validate.ValidateName(name); err != nil {
		return "", fmt.Errorf("invalid identity name: %w", err)
	}
	alias = strings.ToLower(strings.TrimSpace(alias))
	if err := validate.Alias(alias); err != nil {
		return "", err
	}
	if err := config.EnsureDirectories(); err != nil {
		return "", fmt.Errorf("creating directories: %w", err)
	}

	idStore, err := newIdentityStore()
	if err != nil {
		return "", err
	}
	entries, err := idStore.LoadIndex()
	if err != nil {
		return "", fmt.Errorf("loading identity index: %w", err)
	}
	// Reject a name that collides with an existing identity's name OR alias
	// (so a new name can't shadow an existing alias).
	if err := identity.CheckNameAvailable(entries, name); err != nil {
		return "", fmt.Errorf("identity name %q is already taken (by a name or alias)", name)
	}
	if err := identity.CheckAliasUnique(entries, alias, ""); err != nil {
		return "", err
	}

	backend := defaultBackend()

	storeKs, err := keystoreForCreation(backend)
	if err != nil {
		return "", err
	}

	// HW setup, if requested. Dispatches desktop vs mobile internally —
	// desktop uses libykpers inline (presence + IsSlot2Programmed +
	// EnsureChallenge + smoke test); mobile consumes the Dart-prepared
	// challenge + response from the per-name caches.
	var hwDec *keystore.HardwareKeyDecorator
	if useHWKey {
		var err error
		hwDec, err = setupHWForNewIdentity(name, backend)
		if err != nil {
			return "", err
		}
		storeKs = hwDec
	}

	kp, err := crypto.GenerateKeyPair()
	if err != nil {
		return "", fmt.Errorf("generating keypair: %w", err)
	}

	if err := storeKs.StoreEncryptionIdentity(name, kp.EncryptionIdentity); err != nil {
		if hwDec != nil {
			_ = hwDec.RemoveChallenge(name)
		}
		return "", fmt.Errorf("storing encryption key: %w", err)
	}
	if err := storeKs.StoreSigningKey(name, kp.SigningPrivateKey); err != nil {
		if hwDec != nil {
			_ = hwDec.RemoveChallenge(name)
		}
		return "", fmt.Errorf("storing signing key: %w", err)
	}

	createdAt := time.Now()
	icID := crypto.GenerateInstacryptID(kp.EncryptionRecipient, kp.SigningPublicKey, createdAt)
	isFirst := len(entries) == 0

	id := identity.Identity{
		ID:          icID,
		Name:        name,
		Alias:       alias,
		FirstName:   firstName,
		LastName:    lastName,
		Email:       email,
		EncPubKey:   kp.EncryptionRecipient,
		SignPubKey:  base64.StdEncoding.EncodeToString(kp.SigningPublicKey),
		Fingerprint: kp.Fingerprint,
		IsPrimary:   isFirst,
		Status:      identity.StatusActive,
		Backend:     backend,
		HWKey:       useHWKey,
		CreatedAt:   createdAt,
	}

	// Self-sign the lock so every shared/published copy is authenticated.
	lockSig, err := identity.SealLockSigWithKey(kp.SigningPrivateKey, id)
	if err != nil {
		return "", fmt.Errorf("sealing lock signature: %w", err)
	}
	id.LockSig = lockSig

	if err := idStore.SaveMeta(id); err != nil {
		return "", fmt.Errorf("saving identity meta: %w", err)
	}
	entries = append(entries, identity.IdentityIndex{
		Name:        name,
		Backend:     backend,
		HWKey:       useHWKey,
		Fingerprint: id.Fingerprint,
		Alias:       alias,
	})
	if err := idStore.SaveIndex(entries); err != nil {
		return "", fmt.Errorf("saving identity index: %w", err)
	}

	if isFirst {
		cfg, err := config.Load()
		if err == nil {
			cfg.DefaultIdentity = name
			_ = cfg.Save()
			rekeyCloudToNewDefault(cfg)
		}
	}

	return "Identity created successfully", nil
}

// rekeyCloudToNewDefault best-effort re-keys the self-lock cloud blobs to the
// just-established default identity, so cloud data sealed to a PRIOR (deleted)
// identity doesn't strand as an orphan on other devices. Safe no-op when cloud
// is off / not signed in, or when this device has no local data to re-seal from
// (the reseal empty-source guard). Failure is swallowed — the Cloud tab's
// "Re-key Cloud Data" action repeats it if this couldn't run.
//
// No surprise hardware-key tap at create/import time: for a HW-backed default,
// OpenIdentity returns the "hardware key required" MARKER error rather than
// prompting, so this swallows it and skips — those blobs re-key on the next sync
// (recoverOrphan) or via the manual action.
func rekeyCloudToNewDefault(cfg *config.Config) {
	ctx := context.Background()
	c := cloudClientIfEnabled(ctx)
	if c == nil {
		return
	}
	host := newHandoffHost(cfg)
	defer host.close()
	_ = handoff.RekeyDefault(ctx, c, cfg, host)
}

// RevokeIdentity marks an identity as revoked. Keys are retained so old
// ciphertexts can still be decrypted.
func (s *IcfxService) RevokeIdentity(name string) (string, error) {
	idStore, err := newIdentityStore()
	if err != nil {
		return "", err
	}

	unlocked, err := openIdentity(name)
	if err != nil {
		return "", fmt.Errorf("opening identity %q: %w", name, err)
	}
	defer unlocked.Close()
	id := unlocked.Info()

	if id.Status == identity.StatusRevoked {
		return "", fmt.Errorf("identity %q is already revoked", name)
	}

	id.Status = identity.StatusRevoked
	id.RevokedAt = time.Now()

	if err := idStore.SaveMeta(id); err != nil {
		return "", fmt.Errorf("saving identity meta: %w", err)
	}

	// Sign the revocation with the key being revoked and notify cloud contacts
	// so they stop using it. Best-effort — a local revoke still succeeds offline.
	rev := bundle.NewRevocation(id.ID, id.Fingerprint)
	if sealed, serr := bundle.SealRevocation(unlocked, rev); serr == nil {
		broadcastRevocationToCloud(sealed)
	}

	return "Identity revoked", nil
}

// RotateIdentity revokes the current keys (renamed to <name>-revoked-<ts>
// for archival) and generates a new keypair under the same name with the
// same IC ID. Both old and new entries appear in the identity index.
func (s *IcfxService) RotateIdentity(name, alias, email, firstName, lastName string) (string, error) {
	alias = strings.ToLower(strings.TrimSpace(alias))
	if err := validate.Alias(alias); err != nil {
		return "", err
	}
	if err := config.EnsureDirectories(); err != nil {
		return "", fmt.Errorf("creating directories: %w", err)
	}

	idStore, entries, idx, err := resolveIdentity(name)
	if err != nil {
		return "", err
	}
	// The caller may have passed an alias; use the canonical name for all the
	// keystore operations below (they're keyed by name).
	name = idx.Name
	if err := identity.CheckAliasUnique(entries, alias, name); err != nil {
		return "", err
	}

	unlocked, err := openIdentityByIndex(*idx, idStore)
	if err != nil {
		return "", fmt.Errorf("opening identity: %w", err)
	}
	prevID := unlocked.Info()
	if prevID.Status == identity.StatusRevoked {
		unlocked.Close()
		return "", fmt.Errorf("identity %q is already revoked", name)
	}

	revokedAt := time.Now()
	prevName := name + "-revoked-" + revokedAt.Format("20060102-150405")

	ks, err := keystoreForIdentity(*idx)
	if err != nil {
		unlocked.Close()
		return "", err
	}
	prevEncID, lerr := ks.LoadEncryptionIdentity(name)
	if lerr != nil {
		unlocked.Close()
		return "", fmt.Errorf("reading previous encryption key: %w", lerr)
	}
	prevSignKey, lerr := ks.LoadSigningKey(name)
	if lerr != nil {
		unlocked.Close()
		return "", fmt.Errorf("reading previous signing key: %w", lerr)
	}
	if err := ks.StoreEncryptionIdentity(prevName, prevEncID); err != nil {
		unlocked.Close()
		return "", fmt.Errorf("renaming previous encryption key: %w", err)
	}
	if err := ks.StoreSigningKey(prevName, prevSignKey); err != nil {
		unlocked.Close()
		return "", fmt.Errorf("renaming previous signing key: %w", err)
	}

	prevID.Name = prevName
	prevID.Status = identity.StatusRevoked
	prevID.RevokedAt = revokedAt
	if err := idStore.SaveMeta(prevID); err != nil {
		unlocked.Close()
		return "", fmt.Errorf("saving revoked meta: %w", err)
	}
	unlocked.Close()

	_ = idStore.RemoveMeta(name)

	kp, err := crypto.GenerateKeyPair()
	if err != nil {
		return "", fmt.Errorf("generating keypair: %w", err)
	}
	if err := ks.StoreEncryptionIdentity(name, kp.EncryptionIdentity); err != nil {
		return "", fmt.Errorf("storing encryption key: %w", err)
	}
	if err := ks.StoreSigningKey(name, kp.SigningPrivateKey); err != nil {
		return "", fmt.Errorf("storing signing key: %w", err)
	}

	newID := identity.Identity{
		ID:          prevID.ID,
		Name:        name,
		Alias:       alias,
		FirstName:   firstName,
		LastName:    lastName,
		Email:       email,
		EncPubKey:   kp.EncryptionRecipient,
		SignPubKey:  base64.StdEncoding.EncodeToString(kp.SigningPublicKey),
		Fingerprint: kp.Fingerprint,
		IsPrimary:   prevID.IsPrimary,
		Status:      identity.StatusActive,
		Backend:     idx.Backend,
		CreatedAt:   time.Now(),
	}
	// Self-sign the new lock with the NEW key.
	lockSig, err := identity.SealLockSigWithKey(kp.SigningPrivateKey, newID)
	if err != nil {
		return "", fmt.Errorf("sealing new lock signature: %w", err)
	}
	newID.LockSig = lockSig
	if err := idStore.SaveMeta(newID); err != nil {
		return "", fmt.Errorf("saving new meta: %w", err)
	}

	// The live entry for `name` now resolves to the new keypair — refresh its
	// cached fingerprint (the sync key-swap gate compares against it). Archive
	// the renamed-revoked slot with the previous fingerprint.
	for i := range entries {
		if entries[i].Name == name {
			entries[i].Fingerprint = kp.Fingerprint
			entries[i].Alias = alias
			break
		}
	}
	// The archived revoked slot deliberately carries no alias — the alias
	// belongs to the live identity, and a duplicate would trip CheckAliasUnique.
	entries = append(entries, identity.IdentityIndex{
		Name:        prevName,
		Backend:     idx.Backend,
		Fingerprint: prevID.Fingerprint,
	})
	if err := idStore.SaveIndex(entries); err != nil {
		return "", fmt.Errorf("saving identity index: %w", err)
	}

	// If the rotated identity is the current default, its lock just changed —
	// re-key the self-lock cloud resources to the new lock so they don't orphan
	// (uniform with delete/set-default). Best-effort + no-op off-cloud.
	rekeyRotatedDefault(context.Background(), name)

	// Build the signed rotation (new lock self-signed above; continuity signed
	// by the OLD key captured before archiving) and notify cloud contacts so
	// they update to the new key. Best-effort — rotation still succeeds offline.
	rot := bundle.RotationBundle{
		Revocation: bundle.NewRevocation(newID.ID, prevID.Fingerprint),
		NewLock:    identity.LockBundleOf(newID),
	}
	if sealed, serr := bundle.SealRotation(keySigner{prevSignKey}, rot); serr == nil {
		broadcastRotationToCloud(sealed)
	}

	return "Identity rotated", nil
}

// rekeyRotatedDefault re-keys the self-lock cloud resources to a just-rotated
// default identity's new lock. Best-effort — a failure is recovered on the next
// sync's re-seal gate — and a no-op when cloud is off or name isn't the default.
func rekeyRotatedDefault(ctx context.Context, name string) {
	cfg, err := config.Load()
	if err != nil {
		return
	}
	c := cloudClientIfEnabled(ctx)
	if c == nil {
		return
	}
	newU, err := openIdentity(name)
	if err != nil {
		return
	}
	defer newU.Close()
	host := newHandoffHost(cfg)
	defer host.close()
	_ = handoff.RekeyDefaultAfterRotate(ctx, c, cfg, name, newU, host)
}

// ExportLock exports an identity's public keys as an armored lock string.
func (s *IcfxService) ExportLock(name string) (string, error) {
	unlocked, err := openIdentity(name)
	if err != nil {
		return "", fmt.Errorf("opening identity %q: %w", name, err)
	}
	defer unlocked.Close()

	// Same bundle shape (incl. the self-signature) the QR export ships, so a
	// file-exported lock verifies identically to a QR-shared one.
	lockBundle := identity.LockBundleOf(unlocked.Info())

	data, err := json.MarshalIndent(lockBundle, "", "  ")
	if err != nil {
		return "", fmt.Errorf("marshaling lock: %w", err)
	}

	armored := format.ArmorEncode(data, format.ArmorLockLabel)
	return string(armored), nil
}

// ExportLockQR exports an identity's public keys as a base64-encoded
// animated QR code GIF (looping multi-frame sequence).
func (s *IcfxService) ExportLockQR(name string) (string, error) {
	unlocked, err := openIdentity(name)
	if err != nil {
		return "", fmt.Errorf("opening identity %q: %w", name, err)
	}
	defer unlocked.Close()

	lockBundle := identity.LockBundleOf(unlocked.Info())

	gifBytes, err := qr.GenerateAnimatedQRGIF(lockBundle, 512, qr.DefaultFrameDelay)
	if err != nil {
		return "", fmt.Errorf("generating animated QR code: %w", err)
	}

	return base64.StdEncoding.EncodeToString(gifBytes), nil
}

// --- Identity backup export ---
//
// ExportIdentity (private keys + public-key metadata) goes through
// identity.Unlocked.Export. Plaintext key bytes never leave icfx —
// the bundle is encrypted with the user's passphrase inside the library.

// ExportIdentity exports an identity (private key + public metadata) as a
// passphrase-protected armored string. The bundle passphrase (a standalone
// secret, independent from the session unlock passphrase) is consumed from
// the staged enclave — see StageBundlePassphrase.
func (s *IcfxService) ExportIdentity(name string) (string, error) {
	pass, done, err := takeBundlePassphrase()
	if err != nil {
		return "", err
	}
	defer done()
	unlocked, err := openIdentity(name)
	if err != nil {
		return "", fmt.Errorf("opening identity %q: %w", name, err)
	}
	encrypted, err := unlocked.ExportBytes(pass)
	unlocked.Close()
	if err != nil {
		return "", fmt.Errorf("exporting identity: %w", err)
	}

	armored := format.ArmorEncode(encrypted, format.ArmorIdentityLabel)
	return string(armored), nil
}

// IdentityBackupFilename returns the default filename for an identity backup
// ("<alias-or-name>.icid") without unlocking — the Dart save dialog uses it to
// pre-fill the filename. The user can still choose a different path. `name` may
// be a name or an alias.
func (s *IcfxService) IdentityBackupFilename(name string) (string, error) {
	_, _, idx, err := resolveIdentity(name)
	if err != nil {
		return "", err
	}
	return identity.IndexBackupFilename(*idx), nil
}

// ProfileBackupFilename returns the default filename for a whole-profile backup
// ("<alias-or-name>-profile.tar.icfx"), resolved from the default identity's
// plaintext index entry (no unlock). The Dart save dialog uses it to pre-fill
// the filename; the user can still choose a different path.
func (s *IcfxService) ProfileBackupFilename() (string, error) {
	return profile.DefaultBackupFilename(), nil
}

// --- Identity restore (`.icid` import) ---
//
// A `.icid` backup is the icfx full-identity bundle (private keys + public
// metadata). ic-cli's `icc identity import` and ic-app's Restore flow both go
// through `identity.Import`.

// PeekIdentityBundle decrypts just enough of a backup bundle to expose the
// identity's name, fingerprint, and HW-protection flag, plus whether an
// identity of that name already exists locally. The Dart UI calls this before
// ImportIdentity so it can show the conflict-check / HW-preserve dialogs with
// concrete information from the bundle. Returns JSON of shape
// `{"name", "fingerprint", "hw_key", "conflict"}`.
//
// Wrong-passphrase errors propagate verbatim so the UI can re-prompt.
func (s *IcfxService) PeekIdentityBundle(filePath string) (string, error) {
	pass, done, err := takeBundlePassphrase()
	if err != nil {
		return "", err
	}
	defer done()
	data, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("reading file: %w", err)
	}
	if format.IsArmored(data) {
		payload, derr := format.ArmorDecodeExpect(data, format.ArmorIdentityLabel)
		if derr != nil {
			return "", fmt.Errorf("not an identity backup: %w", derr)
		}
		data = payload
	}
	info, hwKey, challenge, err := identity.PeekBytesFull(data, pass)
	if err != nil {
		return "", err
	}

	idStore, err := newIdentityStore()
	if err != nil {
		return "", err
	}
	entries, err := idStore.LoadIndex()
	if err != nil {
		return "", fmt.Errorf("loading identity index: %w", err)
	}
	conflict := false
	for _, e := range entries {
		if e.Name == info.Name {
			conflict = true
			break
		}
	}

	result := map[string]any{
		"name":         info.Name,
		"fingerprint":  info.Fingerprint,
		"hw_key":       hwKey,
		"hw_challenge": base64.StdEncoding.EncodeToString(challenge), // "" when non-HW
		"conflict":     conflict,
	}
	out, err := json.Marshal(result)
	if err != nil {
		return "", fmt.Errorf("marshaling peek result: %w", err)
	}
	return string(out), nil
}

// ImportIdentity restores a `.icid` backup. Mirrors ic-cli's
// `identityImportCmd` (`internal/cli/identity_profile.go:118-191`) with
// ic-app's session-passphrase and keystore-selection patterns.
//
// preserveHW only applies to HW-protected bundles: true reuses the bundle's
// challenge and re-binds it to the local hardware key; false drops HW
// protection and stores the keys under the configured non-HW backend.
//
// renameTo "" means use the bundle's original name. Rename is rejected for
// HW bundles (the challenge file is keyed by name and would orphan).
//
// On success, writes both the per-identity meta file and appends the index
// entry — required for ListIdentities to see the imported identity.
func (s *IcfxService) ImportIdentity(filePath string, preserveHW bool, renameTo string) (string, error) {
	pass, done, err := takeBundlePassphrase()
	if err != nil {
		return "", err
	}
	defer done()
	if err := config.EnsureDirectories(); err != nil {
		return "", fmt.Errorf("creating directories: %w", err)
	}

	data, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("reading file: %w", err)
	}
	if format.IsArmored(data) {
		payload, derr := format.ArmorDecodeExpect(data, format.ArmorIdentityLabel)
		if derr != nil {
			return "", fmt.Errorf("not an identity backup: %w", derr)
		}
		data = payload
	}

	peeked, peekedHW, err := identity.PeekBytes(data, pass)
	if err != nil {
		return "", err
	}

	backend := defaultBackend()
	keysDir, err := config.KeysDir()
	if err != nil {
		return "", fmt.Errorf("resolving keys directory: %w", err)
	}

	ks, err := keystoreForCreation(backend)
	if err != nil {
		return "", err
	}

	var hwRestore identity.HWRestoreFn
	if peekedHW {
		hwRestore = func(challenge []byte) (keystore.Keystore, error) {
			if !preserveHW {
				return nil, nil
			}
			// Mobile: consume the cached NFC/USB response the Dart ceremony
			// injected for this identity; desktop: enumerate the plugged key.
			hw, herr := openHWForOp(peeked.Name)
			if herr != nil {
				return nil, herr
			}
			passFn := hwPassFnForBackend(backend, peeked.Name)
			dec := keystore.NewHardwareKeyDecorator(plainInnerForBackend(backend, keysDir), hw, keysDir, passFn)
			if werr := dec.WriteChallenge(peeked.Name, challenge); werr != nil {
				return nil, fmt.Errorf("persisting challenge file: %w", werr)
			}
			return dec, nil
		}
	}

	info, err := identity.ImportBytes(data, pass, ks, hwRestore)
	if err != nil {
		return "", fmt.Errorf("importing: %w", err)
	}

	if renameTo != "" && renameTo != info.Name {
		if info.HWKey {
			_ = ks.Clear(info.Name)
			return "", fmt.Errorf("renaming a hardware-key-protected identity on import is not supported; import with the original name (%q) and rename afterward", info.Name)
		}
		encID, lerr := ks.LoadEncryptionIdentity(info.Name)
		if lerr != nil {
			return "", fmt.Errorf("re-reading imported encryption identity: %w", lerr)
		}
		sigKey, lerr := ks.LoadSigningKey(info.Name)
		if lerr != nil {
			return "", fmt.Errorf("re-reading imported signing key: %w", lerr)
		}
		if serr := ks.StoreEncryptionIdentity(renameTo, encID); serr != nil {
			return "", fmt.Errorf("re-storing under %q: %w", renameTo, serr)
		}
		if serr := ks.StoreSigningKey(renameTo, sigKey); serr != nil {
			return "", fmt.Errorf("re-storing under %q: %w", renameTo, serr)
		}
		_ = ks.Clear(info.Name)
		info.Name = renameTo
	}

	idStore, err := newIdentityStore()
	if err != nil {
		return "", err
	}
	// Persist meta + plaintext index entry (incl. Alias) via the shared icfx
	// helper — the single source of truth both clients use so import can't
	// diverge (and so imported identities get their alias into the index).
	isFirst, _, err := identity.PersistImported(idStore, info, backend)
	if err != nil {
		return "", err
	}

	if isFirst {
		cfg, cerr := config.Load()
		if cerr == nil {
			cfg.DefaultIdentity = info.Name
			_ = cfg.Save()
			rekeyCloudToNewDefault(cfg)
		}
	}

	return fmt.Sprintf("Identity %q restored from backup", info.Name), nil
}

// --- Profile export / import ---

// ExportProfile creates a passphrase-protected backup of the user's complete
// icfx state (config + identities + per-identity meta + contacts + per-
// identity encrypted key bundles) and returns the encrypted bytes as base64.
// The Dart side writes them to disk via the file picker.
//
// All identities are included regardless of backend (file or keychain) —
// each identity is exported via Unlocked.Export inside the tarball, so the
// keys travel as encrypted bundles rather than raw on-disk files.
func (s *IcfxService) ExportProfile() (string, error) {
	pass, done, err := takeBundlePassphrase()
	if err != nil {
		return "", err
	}
	defer done()
	data, err := profile.ExportToBytesWithPass(pass, openIdentity)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(data), nil
}

// ImportProfile decrypts a profile backup and REPLACES the local installation.
// The bundle passphrase is consumed from the staged enclave (see
// StageBundlePassphrase). The boolean options correspond to the
// import-confirm dialog's checkboxes:
//
//   - includeSettings: apply the bundle's DefaultIdentity / Format /
//     Keystore / Verbose / Banner / AutoLockMinutes to local config.
//   - includePaths: apply the bundle's ConfPath / DataPath / KeyPath to
//     local config (and re-resolve the active paths for this import).
//   - preserveHW: if true, HW-flagged identities are re-bound to the local
//     hardware key (requires a key plugged in); if false, they're imported
//     as non-HW (the keys are re-encrypted under the destination's non-HW
//     KEK).
//
// DESTRUCTIVE — callers should confirm with the user before invoking.
func (s *IcfxService) ImportProfile(filePath string, includeSettings, includePaths, preserveHW bool) (string, error) {
	pass, done, err := takeBundlePassphrase()
	if err != nil {
		return "", err
	}
	defer done()
	opts := profile.ImportOptions{
		PassphraseBytes: pass,
		IncludeSettings: includeSettings,
		IncludePaths:    includePaths,
	}
	if preserveHW {
		opts.HWRestore = profileHWRestoreFactory()
	}
	destKsFn := func() (keystore.Keystore, string, error) {
		backend := defaultBackend()
		ks, err := keystoreForCreation(backend)
		if err != nil {
			return nil, "", err
		}
		return ks, backend, nil
	}
	if err := profile.Import(filePath, opts, destKsFn); err != nil {
		return "", err
	}
	return "Profile imported", nil
}

// PeekProfileManifest decrypts only the manifest entry of a profile bundle
// and returns it as JSON, so the Dart UI can pre-flight what's in the
// bundle (identity count, HW flags, contact count, export timestamp)
// before showing the destructive-confirm dialog.
//
// Wrong-passphrase errors propagate verbatim so the UI can re-prompt
// without committing to any writes.
func (s *IcfxService) PeekProfileManifest(filePath string) (string, error) {
	pass, done, err := takeBundlePassphrase()
	if err != nil {
		return "", err
	}
	defer done()
	raw, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("reading profile bundle: %w", err)
	}
	manifest, err := profile.PeekManifestFromBytesWithPass(raw, pass)
	if err != nil {
		return "", err
	}
	out, err := json.Marshal(manifest)
	if err != nil {
		return "", fmt.Errorf("marshaling manifest: %w", err)
	}
	return string(out), nil
}

// PeekProfileHWChallenges returns a JSON object mapping each hardware-key
// identity name in a profile bundle to its base64 HW challenge, so the mobile
// Dart layer can run the NFC ceremony per identity before ImportProfile.
// (json.Marshal encodes the []byte challenge values as base64 strings.)
func (s *IcfxService) PeekProfileHWChallenges(filePath string) (string, error) {
	pass, done, err := takeBundlePassphrase()
	if err != nil {
		return "", err
	}
	defer done()
	raw, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("reading profile bundle: %w", err)
	}
	challenges, err := profile.PeekHWChallengesFromBytes(raw, pass)
	if err != nil {
		return "", err
	}
	out, err := json.Marshal(challenges)
	if err != nil {
		return "", fmt.Errorf("marshaling hw challenges: %w", err)
	}
	return string(out), nil
}

// profileHWRestoreFactory returns a per-identity HW restore factory for
// profile import. Each HW-flagged identity in the bundle gets a fresh
// callback bound to its name, which opens the session HW key, persists
// the bundle's challenge bytes under that identity's name, and returns
// the HW-decorated keystore.
//
// Mirrors ic-cli's profileHWRestoreFactory (`internal/cli/profile.go`).
func profileHWRestoreFactory() profile.HWRestoreFactoryFn {
	return func(name string) identity.HWRestoreFn {
		return func(challenge []byte) (keystore.Keystore, error) {
			// Mobile: consume the cached NFC/USB response the Dart ceremony
			// injected for this identity; desktop: enumerate the plugged key.
			hw, err := openHWForOp(name)
			if err != nil {
				return nil, fmt.Errorf("opening hardware key for %q: %w", name, err)
			}
			keysDir, err := config.KeysDir()
			if err != nil {
				return nil, fmt.Errorf("resolving keys directory: %w", err)
			}
			backend := defaultBackend()
			passFn := hwPassFnForBackend(backend, name)
			dec := keystore.NewHardwareKeyDecorator(plainInnerForBackend(backend, keysDir), hw, keysDir, passFn)
			if err := dec.WriteChallenge(name, challenge); err != nil {
				return nil, fmt.Errorf("persisting challenge for %q: %w", name, err)
			}
			return dec, nil
		}
	}
}

// InjectHWResponse caches a hardware-key challenge-response result for the
// named identity from the response staged via StageHWResponse. Mobile
// platforms call StageHWResponse (secure channel) then this BEFORE invoking a
// crypto op against an HW-protected identity — the Dart layer has already
// performed the NFC/USB tap via flugo's hardware_key plugin and computed the
// 20-byte HMAC-SHA1 response against the identity's stored challenge bytes.
// openHWForOp consumes the cached response.
//
// The 20-byte response is the keystore KEK factor (for keychain-backed
// HWKEKNone identities it is the whole KEK secret), so it rides the secure
// raw-bytes channel via StageHWResponse — never crossing the FFI as JSON.
// serial/family are non-secret device metadata for display and pass as plain
// args, mirroring StageBundlePassphrase.
//
// The cached response is kept for the auto-lock window and reused across
// operations, exactly like the session passphrase — NOT one tap per op. It is
// wiped on Lock / auto-lock (now including HWKEKNone identities that never
// cache a passphrase); callers may also call ClearHWResponse(name) to drop it
// early (e.g. a canceled flow).
//
// No-op on desktop (the desktop path uses libykpers directly via
// openDesktopHWChalresp; the cache is only consulted on android/ios).
func (s *IcfxService) InjectHWResponse(identityName, serial, family string) error {
	if identityName == "" {
		return fmt.Errorf("identity name required")
	}
	resp, done, err := takeStagedHWResponse()
	if err != nil {
		return err
	}
	defer done()
	cached, err := crypto.NewCachedHWResponse(resp, serial, family)
	if err != nil {
		return err
	}
	hwResponses.Lock()
	if hwResponses.byName == nil {
		hwResponses.byName = make(map[string]*crypto.CachedHWResponse)
	}
	hwResponses.byName[identityName] = cached
	hwResponses.Unlock()
	touchActivity() // a fresh tap resets the auto-lock idle clock
	return nil
}

// HasHWResponse reports whether a response is cached for the named identity.
// Lets the Dart layer skip the NFC re-prompt when a response is still cached
// within the auto-lock window (the intended reuse behavior).
func (s *IcfxService) HasHWResponse(identityName string) (bool, error) {
	hwResponses.Lock()
	defer hwResponses.Unlock()
	_, ok := hwResponses.byName[identityName]
	return ok, nil
}

// ClearHWResponse drops the cached hardware-key response for the named
// identity (and any staged-but-unconsumed response). For canceled/aborted
// flows — a locked app should hold no secrets. No-op if nothing is cached.
func (s *IcfxService) ClearHWResponse(identityName string) error {
	clearStagedHWResponse()
	hwResponses.Lock()
	defer hwResponses.Unlock()
	delete(hwResponses.byName, identityName)
	return nil
}

// GetHWChallenge returns the persisted challenge bytes for the named
// identity, read from <keysDir>/<name>.hwchallenge. Used by the Dart
// layer on mobile to compute the HMAC-SHA1 response against the right
// challenge before injecting it via InjectHWResponse.
//
// Returns an error if the identity has no challenge file (not
// HW-protected, or file is missing).
func (s *IcfxService) GetHWChallenge(identityName string) ([]byte, error) {
	if identityName == "" {
		return nil, fmt.Errorf("identity name required")
	}
	keysDir, err := config.KeysDir()
	if err != nil {
		return nil, fmt.Errorf("resolving keys directory: %w", err)
	}
	path := keysDir + "/" + identityName + ".hwchallenge"
	bytes, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading challenge file: %w", err)
	}
	if len(bytes) == 0 {
		return nil, fmt.Errorf("challenge file is empty")
	}
	return bytes, nil
}

// GenerateHWChallenge generates a fresh 32-byte random challenge for the
// named identity, caches it under that name, and returns it. Used by the
// mobile create-HW-identity flow:
//
//  1. Dart calls GenerateHWChallenge(name) → 32 random bytes
//  2. Dart shows "tap your key" sheet
//  3. Dart calls the hardware_key plugin's challengeResponse(challenge=…)
//     → 20-byte HMAC-SHA1 response
//  4. Dart calls StageHWResponse(response) then InjectHWResponse(name, …)
//  5. Dart calls CreateKeys(name, …, useHWKey=true) — Go's
//     setupHWForNewIdentityMobile consumes both cached values, writes
//     the challenge to disk via WriteChallenge, and uses the cached
//     response to derive the KEK.
//
// On desktop this method has no callers — the desktop create path
// generates and persists the challenge inline via
// HardwareKeyDecorator.EnsureChallenge. It still works on desktop, just
// unused.
func (s *IcfxService) GenerateHWChallenge(identityName string) ([]byte, error) {
	if identityName == "" {
		return nil, fmt.Errorf("identity name required")
	}
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return nil, fmt.Errorf("generating random challenge: %w", err)
	}
	hwChallenges.Lock()
	defer hwChallenges.Unlock()
	if hwChallenges.byName == nil {
		hwChallenges.byName = make(map[string][]byte)
	}
	hwChallenges.byName[identityName] = buf
	// Return a copy so caller mutations don't bleed back into the cache.
	out := make([]byte, len(buf))
	copy(out, buf)
	return out, nil
}

// setupHWForNewIdentity builds the HardwareKeyDecorator for a brand-new
// HW-protected identity. Dispatches to platform-specific impls — desktop
// drives the device via libykpers; mobile reads the Dart-prepared
// challenge + response from the per-name caches.
func setupHWForNewIdentity(name, backend string) (*keystore.HardwareKeyDecorator, error) {
	if runtime.GOOS == "android" || runtime.GOOS == "ios" {
		return setupHWForNewIdentityMobile(name, backend)
	}
	return setupHWForNewIdentityDesktop(name, backend)
}

// setupHWForNewIdentityMobile consumes the Dart-prepared challenge +
// response from the per-name caches. Dart must have called
// GenerateHWChallenge AND InjectHWResponse before reaching here. The
// challenge gets persisted to <keysDir>/<name>.hwchallenge so future
// crypto ops on this identity can recompute the KEK with a fresh tap.
//
// No IsSlot2Programmed or smoke-test step — the Dart-side tap that
// produced a non-empty response already proved the slot works.
func setupHWForNewIdentityMobile(name, backend string) (*keystore.HardwareKeyDecorator, error) {
	challenge, ok := getCachedHWChallenge(name)
	if !ok {
		return nil, fmt.Errorf("mobile HW create: no challenge generated for %q — Dart must call GenerateHWChallenge before CreateKeys", name)
	}
	hw, err := openHWForOp(name) // returns CachedHWResponse from hwResponses
	if err != nil {
		return nil, err
	}
	keysDir, err := config.KeysDir()
	if err != nil {
		return nil, fmt.Errorf("resolving keys directory: %w", err)
	}
	passFn := hwPassFnForBackend(backend, name)
	dec := keystore.NewHardwareKeyDecorator(plainInnerForBackend(backend, keysDir), hw, keysDir, passFn)
	if err := dec.WriteChallenge(name, challenge); err != nil {
		return nil, fmt.Errorf("persisting challenge: %w", err)
	}
	return dec, nil
}

// setupHWForNewIdentityDesktop is the libykpers-driven setup path —
// detect device, confirm slot 2 is programmed, generate a fresh
// challenge file, run a smoke test against the device. Body lifted from
// the previous inline block in CreateKeys; behavior unchanged.
func setupHWForNewIdentityDesktop(name, backend string) (*keystore.HardwareKeyDecorator, error) {
	hw, err := openDesktopHWChalresp()
	if err != nil {
		return nil, err
	}
	programmed, err := chalresp.IsSlot2Programmed(hw.Descriptor())
	if err != nil {
		return nil, fmt.Errorf("reading hardware key status: %w", err)
	}
	if !programmed {
		return nil, fmt.Errorf("hardware key's slot 2 is not programmed for HMAC-SHA1 challenge-response. Program it first via ykman or KeePassXC, then retry")
	}
	keysDir, err := config.KeysDir()
	if err != nil {
		return nil, fmt.Errorf("resolving keys directory: %w", err)
	}
	passFn := hwPassFnForBackend(backend, name)
	dec := keystore.NewHardwareKeyDecorator(plainInnerForBackend(backend, keysDir), hw, keysDir, passFn)
	challenge, err := dec.EnsureChallenge(name)
	if err != nil {
		return nil, fmt.Errorf("generating challenge: %w", err)
	}
	if _, err := hw.Challenge(challenge); err != nil {
		_ = dec.RemoveChallenge(name)
		return nil, fmt.Errorf("hardware key smoke test failed: %w", err)
	}
	return dec, nil
}
