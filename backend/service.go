package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"github.com/awnumar/memguard"
	"github.com/hkdb/flugo/pkg/bridge"
	"github.com/instacryptio/icfx/config"
	"github.com/instacryptio/icfx/contacts"
	"github.com/instacryptio/icfx/crypto"
	"github.com/instacryptio/icfx/hardware/chalresp"
	"github.com/instacryptio/icfx/identity"
	"github.com/instacryptio/icfx/keystore"
)

// hwSession caches the opened *chalresp.Key for the current app session so
// we don't re-detect/re-open the device on every keystore operation. Mirrors
// ic-cli's pattern (`internal/cli/identity_helpers.go:23-26`). Cleared by
// `closeSessionHWKey`, which is called from `clearSessionPass` (Lock +
// auto-lock). The next operation that needs a HW key will re-detect from
// scratch.
var hwSession struct {
	sync.Mutex
	key *chalresp.Key
}

// hwResponses caches per-identity HMAC-SHA1 responses pre-fetched by
// the Dart layer on mobile platforms. Each entry is a one-shot — the
// Dart side fetches a fresh response per crypto operation (NFC is
// atomic, one tap = one response), injects it here via the
// `InjectHWResponse` bridge method, then triggers the actual op which
// reads through openSessionHWKey. The cache is wiped on auto-lock /
// Lock alongside sessionPass.
//
// On desktop this map is unused: openSessionHWKey returns the live
// chalresp.Key directly.
var hwResponses struct {
	sync.Mutex
	byName map[string]*crypto.CachedHWResponse
}

// hwChallenges caches per-identity challenge bytes generated server-side
// for SETUP operations (CreateKeys with useHWKey, future toggle/import
// flows) on mobile. The Dart layer calls GenerateHWChallenge → gets the
// 32 random bytes → drives the NFC tap with those bytes → injects the
// resulting response. CreateKeys then consumes both the cached challenge
// (persists it to <keysDir>/<name>.hwchallenge) and the cached response.
// Wiped alongside hwResponses on Lock / auto-lock.
//
// On desktop this map is unused: the desktop create path generates and
// persists the challenge inline via HardwareKeyDecorator.EnsureChallenge.
var hwChallenges struct {
	sync.Mutex
	byName map[string][]byte
}

// getCachedHWChallenge returns the previously-generated challenge bytes
// for the named identity. Used by setupHWForNewIdentityMobile to persist
// the Dart-prepared challenge to disk during CreateKeys.
func getCachedHWChallenge(identityName string) ([]byte, bool) {
	hwChallenges.Lock()
	defer hwChallenges.Unlock()
	b, ok := hwChallenges.byName[identityName]
	return b, ok
}

// sessionPass holds the user's file-keystore passphrase encrypted in memory
// for the duration of the app session. Only populated when at least one
// identity uses the file backend; keychain-backed identities never need it.
var sessionPass *memguard.Enclave

// sessionMu guards sessionPass and lastUnlockTouch. The auto-lock goroutine
// reads both; bridge methods write both. A short-lived lock per access keeps
// contention negligible.
var sessionMu sync.Mutex

// lastUnlockTouch is updated every time a bridge method opens sessionPass for
// a crypto operation. The auto-lock goroutine compares it against
// AutoLockMinutes to decide when to wipe the cache.
var lastUnlockTouch time.Time

// autoLockOnce guards startAutoLockWatcher so the goroutine spawns at most
// once per process even if init() runs in tests etc.
var autoLockOnce sync.Once

// pathsOnce ensures the path-resolver overrides are applied exactly once
// per process. On mobile (android/ios) icfx has no default data/config/key
// directories — the bridge's BaseDir (set by Flutter at startup via
// flugoPathService.SetBaseDir) is the only source. We can't apply them in
// init() because BaseDir isn't set yet at Go init time; we lazily apply on
// the first bridge call that needs paths.
var pathsOnce sync.Once

// IcfxService is the backend service exposed to Flutter via Flugo.
type IcfxService struct{}

// ensurePathsApplied lazily plumbs bridge.BaseDir (mobile) and any user-
// configured path overrides (desktop or mobile) into icfx/config. Idempotent
// and cheap on subsequent calls (sync.Once). Must be called at the top of
// every IcfxService method that resolves data/config/keys paths — most do,
// either directly (config.Load) or transitively (newIdentityStore /
// newContactStore).
//
// Without this, the first launch call on mobile fails with
// "DefaultDataDir on android: config: path not set" because nobody has
// called config.SetDataPath yet (flugoPathService.SetBaseDir stores the
// path in the bridge but doesn't push it into icfx/config).
func ensurePathsApplied() {
	pathsOnce.Do(func() {
		// First pass: bridge BaseDir → fallback paths (mobile case).
		// Pass an empty Config so applyPathOverrides only runs the
		// BaseDir branch.
		applyPathOverrides(&config.Config{})
		// Second pass: now that paths are resolvable, load the real
		// config and apply any user-defined path overrides on top.
		if cfg, err := config.Load(); err == nil {
			applyPathOverrides(cfg)
		}
	})
}

// applyPathOverrides sets data/key path overrides from flugo bridge and config.
// On mobile platforms (android/ios) the icfx defaults aren't set; the bridge
// base directory becomes the source of truth. On desktop the bridge base is
// usually empty and icfx defaults apply, so a path-resolution error from
// config.ConfigDir() etc. is treated as "no default available, apply override".
func applyPathOverrides(cfg *config.Config) {
	base := bridge.BaseDir()
	if base != "" {
		if dir, err := config.ConfigDir(); err != nil || dir == "" {
			config.SetConfigDir(filepath.Join(base, "config"))
		}
		if dir, err := config.DataDir(); err != nil || dir == "" {
			config.SetDataPath(filepath.Join(base, "data"))
		}
		if dir, err := config.KeysDir(); err != nil || dir == "" {
			config.SetKeyPath(filepath.Join(base, "lk"))
		}
	}

	// Config file overrides take priority
	if cfg.DataPath != "" {
		config.SetDataPath(config.ExpandPath(cfg.DataPath))
	}
	if cfg.KeyPath != "" {
		config.SetKeyPath(config.ExpandPath(cfg.KeyPath))
	}

	// Scratch/temp dir: the app cache (bridge.TmpDir, set on every platform via
	// flugoPathService.SetTmpDir). icfx and this backend create transient files
	// through config.TempDir(); on sandboxed platforms the OS default
	// (os.TempDir → /data/local/tmp) isn't writable, so point it at the
	// app-writable cache and make sure it exists.
	if t := bridge.TmpDir(); t != "" {
		_ = os.MkdirAll(t, 0o700)
		config.SetTempPath(t)
	}
}

// sessionActive reports whether a session passphrase is cached, taking
// sessionMu so the read doesn't race the writers (cachePassphrase /
// clearPassphrase / the auto-lock watcher).
func sessionActive() bool {
	sessionMu.Lock()
	defer sessionMu.Unlock()
	return sessionPass != nil
}

// touchActivity advances the auto-lock idle clock. Called whenever a cached
// secret is created or consumed — including the HMAC hardware-key response,
// which for keychain-backed (HWKEKNone) identities is the only cached KEK
// factor (there is no session passphrase), so without this the watcher's idle
// timer would never reflect HW-key activity.
func touchActivity() {
	sessionMu.Lock()
	lastUnlockTouch = time.Now()
	sessionMu.Unlock()
}

// hasCachedHWResponses reports whether any per-identity HMAC response is cached.
func hasCachedHWResponses() bool {
	hwResponses.Lock()
	defer hwResponses.Unlock()
	return len(hwResponses.byName) > 0
}

// sessionPassphraseBytes returns a FRESH, caller-owned copy of the cached
// session passphrase, or nil when the app is locked (no cached passphrase, or
// the enclave can't be opened) — mirroring the old empty-means-locked contract.
// The caller (an icfx keystore callback) takes ownership; the consuming
// keystore wipes the bytes after use, leaving the cached enclave intact. This
// never materializes an un-wipeable Go string, unlike a string accessor would.
// Bumps lastUnlockTouch on success so the auto-lock watcher sees active use.
func sessionPassphraseBytes() []byte {
	sessionMu.Lock()
	defer sessionMu.Unlock()
	if sessionPass == nil {
		return nil
	}
	buf, err := sessionPass.Open()
	if err != nil {
		return nil
	}
	defer buf.Destroy()
	lastUnlockTouch = time.Now()
	out := make([]byte, len(buf.Bytes()))
	copy(out, buf.Bytes())
	return out
}

// cachePassphrase stores the passphrase in a memguard Enclave (encrypted at
// rest, mlock'd). If a previous enclave is already cached it is opened and
// destroyed first — replacing without destroying would leak the prior copy
// in process memory until GC reclaimed it. Resets lastUnlockTouch so the
// auto-lock window starts fresh.
func cachePassphrase(passphrase []byte) {
	sessionMu.Lock()
	defer sessionMu.Unlock()
	if sessionPass != nil {
		if buf, err := sessionPass.Open(); err == nil {
			buf.Destroy()
		}
		sessionPass = nil
	}
	// Seal a COPY so the caller keeps ownership of its slice (memguard's
	// NewBufferFromBytes wipes whatever it's handed).
	cp := make([]byte, len(passphrase))
	copy(cp, passphrase)
	buf := memguard.NewBufferFromBytes(cp)
	sessionPass = buf.Seal()
	lastUnlockTouch = time.Now()
}

// clearSessionPass opens and destroys the cached enclave, then nils it.
// Also closes any cached hardware-key handle (the next HW operation will
// re-detect from scratch). Idempotent. Used by Lock(), the auto-lock
// watcher, and on validation-failure rollback in Unlock().
func clearSessionPass() {
	sessionMu.Lock()
	if sessionPass != nil {
		if buf, err := sessionPass.Open(); err == nil {
			buf.Destroy()
		}
		sessionPass = nil
	}
	sessionMu.Unlock()
	closeSessionHWKey()
}

// closeSessionHWKey drops the cached chalresp.Key handle AND any
// per-identity HW response / pending-challenge caches so the next HW
// operation re-detects the device (desktop) or re-prompts for a tap
// (mobile). Idempotent.
func closeSessionHWKey() {
	hwSession.Lock()
	hwSession.key = nil
	hwSession.Unlock()

	hwResponses.Lock()
	hwResponses.byName = nil
	hwResponses.Unlock()

	hwChallenges.Lock()
	hwChallenges.byName = nil
	hwChallenges.Unlock()
}

// openHWForOp returns the HW key implementation for the named identity,
// suitable for plumbing into keystore.NewHardwareKeyDecorator. On desktop,
// returns the cached chalresp.Key (auto-detected on first call, reused
// until closeSessionHWKey). On mobile, returns a CachedHWResponse from
// the per-identity cache populated by InjectHWResponse — the actual NFC
// tap happened on the Dart side via the flugo hardware_key plugin.
//
// The identityName argument is the cache key on mobile; on desktop, it
// is unused (the same HW device handles any identity via different
// challenge bytes).
func openHWForOp(identityName string) (crypto.HardwareKey, error) {
	if runtime.GOOS == "android" || runtime.GOOS == "ios" {
		hwResponses.Lock()
		cached := hwResponses.byName[identityName]
		hwResponses.Unlock()
		if cached == nil {
			return nil, &hwRequiredError{identity: identityName}
		}
		// Consuming a cached response is activity — keep the idle clock fresh
		// so a busy session isn't auto-locked mid-use (relevant for HWKEKNone
		// identities, which never touch the passphrase clock).
		touchActivity()
		return cached, nil
	}
	return openDesktopHWChalresp()
}

// hwRequiredError signals that a mobile crypto op needs a hardware-key tap
// staged first (the Dart pre-flight: challenge → tap → InjectHWResponse).
// Callers that surface errors to the UI must translate it — the message
// below is developer-facing and must never reach a user.
type hwRequiredError struct{ identity string }

func (e *hwRequiredError) Error() string {
	return fmt.Sprintf("no hardware key response cached for identity %q — Dart layer must call InjectHWResponse before the crypto op", e.identity)
}

// openDesktopHWChalresp returns the cached *chalresp.Key for desktop
// setup paths (toggleHWKeyOn/Off, CreateKeys with useHWKey, ImportIdentity
// with preserveHW, profileHWRestoreFactory) that need go-hid-specific
// APIs like IsSlot2Programmed / Descriptor. On mobile, returns a clear
// error — setup of HW-protected identities requires desktop today.
func openDesktopHWChalresp() (*chalresp.Key, error) {
	if runtime.GOOS == "android" || runtime.GOOS == "ios" {
		return nil, fmt.Errorf("creating or modifying hardware-key-protected identities is not yet supported on mobile — please use the desktop app for this operation")
	}
	hwSession.Lock()
	defer hwSession.Unlock()
	if hwSession.key != nil {
		return hwSession.key, nil
	}
	devices, err := chalresp.List()
	if err != nil {
		return nil, fmt.Errorf("listing hardware keys: %w", err)
	}
	if len(devices) == 0 {
		return nil, fmt.Errorf("no compatible hardware key plugged in (Yubikey/NitroKey/OnlyKey)")
	}
	key, err := chalresp.Open(devices[0])
	if err != nil {
		return nil, fmt.Errorf("opening hardware key: %w", err)
	}
	hwSession.key = key
	return key, nil
}

// plainInnerForBackend returns a plaintext (non-encrypting) keystore for the
// given identity backend, suitable for wrapping with HardwareKeyDecorator.
// The decorator provides the encryption; the inner just stores ciphertext.
// Mirror of ic-cli's `internal/cli/identity_helpers.go:171-176`.
func plainInnerForBackend(backend, keysDir string) keystore.Keystore {
	if backend == identity.BackendKeychain {
		if keystore.KeychainAvailable() {
			return keystore.NewKeychainStore()
		}
		if s := androidKeyringStore(); s != nil {
			return s
		}
	}
	return keystore.NewFileStoreWithDir(keysDir)
}

// hwPassFnForBackend returns the passphrase callback for the HW-decorator's
// KEK derivation. The HW key is always the 2nd factor; the 1st factor depends
// on the identity's backend:
//
//   - backend=keychain (1st factor: OS keychain or Android keyring) + HW
//     (2nd factor): no user passphrase. KEK = HKDF("", hwResponse).
//   - backend=file (1st factor: passphrase) + HW (2nd factor):
//     KEK = HKDF(passphrase, hwResponse). Returns "passphrase required"
//     if there's no cached session passphrase — the Flutter UI uses that
//     keyword to trigger a re-prompt.
//
// The keychain branch must check BOTH keystore.KeychainAvailable() (OS
// keychain on desktop) AND the Android keyring — on Android, the former
// returns false but the latter provides equivalent at-rest protection,
// so a keychain-backed identity legitimately needs no user passphrase.
// Mirrors the dispatch logic in plainInnerForBackend.
func hwPassFnForBackend(backend, _ string) keystore.PassphraseFunc {
	if backend == identity.BackendKeychain && keychainBackendAvailable() {
		return hwPassFnForKEK(identity.HWKEKNone)
	}
	return hwPassFnForKEK(identity.HWKEKPassphrase)
}

// hwPassFnForKEK returns the passphrase half of the hardware KEK per the
// identity's recorded convention (identity.HWKEKNone / HWKEKPassphrase).
// The convention follows the CIPHERTEXT — it roams with the key material —
// not the local storage backend: a keychain-origin HW key imported onto a
// file-backed device still decrypts with the empty-passphrase KEK.
func hwPassFnForKEK(convention string) keystore.PassphraseFunc {
	if convention == identity.HWKEKNone {
		// Fresh empty (non-nil) slice each call: the decorator wipes what it
		// receives, and DeriveHardwareKEKBytes accepts an empty passphrase
		// (keychain-origin HW keys derive the KEK from the device alone).
		return func() ([]byte, error) { return []byte{}, nil }
	}
	return func() ([]byte, error) {
		pass := sessionPassphraseBytes()
		if len(pass) == 0 {
			return nil, fmt.Errorf("passphrase required")
		}
		return pass, nil
	}
}

// keychainBackendAvailable reports whether some form of OS-level key
// storage is reachable on this platform — desktop OS keychain
// (libsecret / Keychain.app / Credential Manager) or, on Android, the
// flugo keyring abstraction (Android Keystore via JNI). Used by
// hwPassFnForBackend so HW+keychain identities on mobile correctly use
// the empty-passphrase branch.
func keychainBackendAvailable() bool {
	return keystore.KeychainAvailable() || androidKeyringStore() != nil
}

// startAutoLockWatcher launches a background goroutine that periodically
// checks whether the session has been idle longer than the configured
// auto_lock_minutes and clears sessionPass if so. Polls every 30s.
//
// Idempotent across calls; the goroutine is launched at most once per
// process via autoLockOnce. Cheap when nothing is unlocked (the inner
// check returns immediately when sessionPass is nil).
//
// The auto_lock_minutes config is re-read on every tick, so settings
// changes take effect within ~30s without needing a restart. A value of
// 0 disables auto-lock.
func startAutoLockWatcher() {
	autoLockOnce.Do(func() {
		go func() {
			tick := time.NewTicker(30 * time.Second)
			defer tick.Stop()
			for range tick.C {
				cfg, err := config.Load()
				if err != nil {
					continue
				}
				if autoLockExpired(time.Now(), cfg.AutoLockMinutes) {
					clearSessionPass()
				}
			}
		}()
	})
}

// autoLockExpired reports whether the idle window has elapsed for whatever
// secrets are currently cached. autoLockMinutes <= 0 disables auto-lock. It
// returns false when nothing is cached (nothing to wipe) — critically, this
// now considers the HMAC hardware-key response cache too, not just the session
// passphrase, so keychain-backed (HWKEKNone) identities are wiped on idle
// instead of living until app exit. Reads sessionMu then the hwResponses lock
// without nesting them.
func autoLockExpired(now time.Time, autoLockMinutes int) bool {
	if autoLockMinutes <= 0 {
		return false
	}
	sessionMu.Lock()
	hasPass := sessionPass != nil
	idle := now.Sub(lastUnlockTouch)
	sessionMu.Unlock()
	if !hasPass && !hasCachedHWResponses() {
		return false
	}
	return idle >= time.Duration(autoLockMinutes)*time.Minute
}

// Unlock validates the given secret against the user's first file-backed
// identity and, on success, seals it into sessionPass for the rest of the
// session. After Unlock succeeds, all subsequent crypto operations consume
// the cached enclave directly — the Dart UI never has to send the passphrase
// across the bridge again until Lock() is called or auto-lock fires.
//
// The *bridge.Secret parameter is the secure-channel intake: bytes arrived
// from Dart via FlugoCallSecure (raw bytes, no JSON), got sealed into a
// memguard enclave on the way in, and never materialized as a Go string.
// This Unlock method opens the enclave for the briefest possible scope
// — long enough to feed the bytes to the keystore validation callback and
// the session cache — and destroys the temporary buffer immediately. The
// passphrase never becomes a Go string: it flows as wipeable []byte from the
// secure-channel buffer, through the icfx []byte keystore callback, into the
// memguard-sealed session enclave.
//
// If the user has no file-backed identities (keychain-only setup, or fresh
// install), Unlock caches optimistically without validation: the cache will
// be available the first time a file-backed identity is created or imported.
//
// Returns an error containing "wrong passphrase" / "invalid passphrase" on
// validation failure; the Dart UI matches on those keywords today.
func (s *IcfxService) Unlock(secret *bridge.Secret) error {
	defer secret.Destroy()

	buf, err := secret.Open()
	if err != nil {
		return fmt.Errorf("opening secret: %w", err)
	}
	defer buf.Destroy()

	// Keep the passphrase as wipeable bytes borrowed from the secure-channel
	// buffer (destroyed by the defer above). Never copy it into a Go string;
	// the long-lived copy lives only in the memguard-sealed sessionPass enclave.
	passphrase := buf.Bytes()

	idStore, err := newIdentityStore()
	if err != nil {
		return err
	}
	entries, err := idStore.LoadIndex()
	if err != nil {
		return fmt.Errorf("loading identity index: %w", err)
	}

	// Pick a non-HW file-backed identity to validate the passphrase against.
	// HW-flagged file identities can't be validated here because their bytes
	// are encrypted with HKDF(passphrase, hwResponse) — needing a touch — and
	// this call path is "check the passphrase, no device interaction yet".
	// If only HW+file identities exist, cache optimistically; the first HW
	// crypto op will validate the passphrase as a side effect of the touch.
	var fileBacked *identity.IdentityIndex
	for i := range entries {
		if entries[i].Backend == identity.BackendFile && !entries[i].HWKey {
			fileBacked = &entries[i]
			break
		}
	}

	if fileBacked == nil {
		cachePassphrase(passphrase)
		return nil
	}

	keysDir, err := config.KeysDir()
	if err != nil {
		return fmt.Errorf("resolving keys directory: %w", err)
	}
	tryStore := keystore.NewEncryptedFileStoreWithDir(keysDir, func() ([]byte, error) {
		// The keystore wipes what it receives; hand it a copy so the borrowed
		// secure-channel bytes stay intact for cachePassphrase below.
		cp := make([]byte, len(passphrase))
		copy(cp, passphrase)
		return cp, nil
	})
	if _, err := tryStore.LoadEncryptionIdentity(fileBacked.Name); err != nil {
		return fmt.Errorf("invalid passphrase: %w", err)
	}

	cachePassphrase(passphrase)
	return nil
}

// RequiresHardwareKey reports whether the configured default identity (or
// first identity if no default) is hardware-key-protected. Lets the Dart
// UI run the "is your key plugged in?" pre-flight before invoking Unlock.
//
// Returns false on empty index (no identities = no HW needed).
// DefaultIdentityName returns the default identity's name ("" when no
// identities exist). The Dart sync pre-flight uses it to target the
// hardware-key tap at the identity the sync legs will unlock.
func (s *IcfxService) DefaultIdentityName() (string, error) {
	ensurePathsApplied()
	idStore, err := newIdentityStore()
	if err != nil {
		return "", err
	}
	entries, err := idStore.LoadIndex()
	if err != nil {
		return "", fmt.Errorf("loading identity index: %w", err)
	}
	return resolveDefaultIdentityName(entries), nil
}

func (s *IcfxService) RequiresHardwareKey() (bool, error) {
	idStore, err := newIdentityStore()
	if err != nil {
		return false, err
	}
	entries, err := idStore.LoadIndex()
	if err != nil {
		return false, fmt.Errorf("loading identity index: %w", err)
	}
	name := resolveDefaultIdentityName(entries)
	if name == "" {
		return false, nil
	}
	for _, e := range entries {
		if e.Name == name {
			return e.HWKey, nil
		}
	}
	return false, nil
}

// HasAnyHardwareKey reports whether at least one compatible hardware key is
// currently plugged in. Backed by chalresp.List(); does not issue any
// challenge or trigger a touch. Returns false (without error) if the go-hid
// init itself fails — treating "init unavailable" the same as "no key
// detected" is the most useful UX from the Dart side.
//
// The error return is required by the flugo bridge contract (Dart expects
// Future<bool> that throws on failure) but never fires today; List errors
// fold into "no key detected".
func (s *IcfxService) HasAnyHardwareKey() (bool, error) { //nolint:unparam // bridge contract
	devices, err := chalresp.List()
	if err != nil {
		// Intentional: treat enumeration failure as "no device" so the
		// Dart UI can show a clean "plug in your key" prompt instead of
		// a raw go-hid error.
		return false, nil //nolint:nilerr
	}
	return len(devices) > 0, nil
}

// RequiresPassphrase reports whether the configured default identity needs
// a passphrase to unlock. File-backed identities always do; keychain-backed
// identities don't (whether HW or not). Used by Dart to decide whether to
// show the passphrase dialog before calling Unlock.
//
// HW+keychain identities are unlocked seamlessly on first crypto op (the
// device touch happens inside keystoreForIdentity → HardwareKeyDecorator
// load), so the Dart side neither prompts nor calls Unlock for them —
// IsUnlocked already returns true.
func (s *IcfxService) RequiresPassphrase() (bool, error) {
	idStore, err := newIdentityStore()
	if err != nil {
		return false, err
	}
	entries, err := idStore.LoadIndex()
	if err != nil {
		return false, fmt.Errorf("loading identity index: %w", err)
	}
	name := resolveDefaultIdentityName(entries)
	if name == "" {
		return false, nil
	}
	for _, e := range entries {
		if e.Name == name {
			return e.Backend == identity.BackendFile, nil
		}
	}
	return false, nil
}

// Lock destroys the cached session passphrase enclave. After Lock the user
// must Unlock again before any operation that touches a file-backed
// identity — keychain-backed identities still work since they don't consult
// sessionPass. Idempotent.
//
// The error return is required by the flugo bridge contract (Dart side
// expects a Future<void> that throws on failure) but never actually fires
// today since clearSessionPass is fail-safe.
func (s *IcfxService) Lock() error { //nolint:unparam // bridge contract
	clearSessionPass()
	// A locked app holds no secrets: drop any staged-but-unconsumed bundle
	// passphrase too (canceled export/import flows).
	clearBundlePassphrase()
	return nil
}

// IsUnlocked reports whether the backend can currently service operations on
// file-backed identities without needing a passphrase prompt. Returns true if
// either (a) sessionPass is populated, or (b) the user has no file-backed
// identities (so no passphrase is ever needed). The Dart UI uses this to
// decide whether to prompt before invoking crypto methods.
func (s *IcfxService) IsUnlocked() (bool, error) {
	if sessionActive() {
		return true, nil
	}
	idStore, err := newIdentityStore()
	if err != nil {
		return false, err
	}
	entries, err := idStore.LoadIndex()
	if err != nil {
		return false, fmt.Errorf("loading identity index: %w", err)
	}
	for _, e := range entries {
		if e.Backend == identity.BackendFile {
			return false, nil
		}
	}
	return true, nil
}

// defaultBackend returns the backend to use for NEW identities, based on
// the global keystore configuration and platform availability. Existing
// identities ignore this — each one carries its own Backend in the index.
func defaultBackend() string {
	cfg, err := config.Load()
	if err == nil && cfg.Keystore == "file" {
		return identity.BackendFile
	}
	if keychainBackendAvailable() {
		return identity.BackendKeychain
	}
	return identity.BackendFile
}

// keystoreForIdentity returns the keystore to use for accessing one specific
// identity's keys, based on that identity's recorded Backend (NOT the
// currently-configured `keystore` setting). HW-decorated if the identity
// has HWKey set; mobile platforms use the per-identity cached HW response
// pre-fetched by the Dart layer (see InjectHWResponse).
func keystoreForIdentity(idx identity.IdentityIndex) (keystore.Keystore, error) {
	if !idx.HWKey {
		return nonHWStoreForBackend(idx.Backend)
	}
	hw, err := openHWForOp(idx.Name)
	if err != nil {
		return nil, err
	}
	dir, err := config.KeysDir()
	if err != nil {
		return nil, fmt.Errorf("resolving keys directory: %w", err)
	}
	return keystore.NewHardwareKeyDecorator(
		plainInnerForBackend(idx.Backend, dir),
		hw, dir, hwPassFnForKEK(idx.HWKEKConvention()),
	), nil
}

// nonHWStoreForBackend constructs a non-HW keystore for the given backend:
//   - "keychain": OS keychain, with Android keyring as a mobile-only fallback.
//     Hard-fails if the identity's recorded backend says keychain but no
//     keychain is reachable on this platform — silently falling through to
//     the file backend would prompt for a passphrase the user never set.
//   - "file": EncryptedFileStore using the cached session passphrase. Returns
//     "passphrase required" when there's no cached passphrase yet; the
//     Flutter UI uses that as a prompt-trigger signal.
//   - "" (empty): treat as the configured default backend (legacy identities
//     created before the Backend field existed).
func nonHWStoreForBackend(backend string) (keystore.Keystore, error) {
	if backend == "" {
		backend = defaultBackend()
	}
	if backend == identity.BackendKeychain {
		if keystore.KeychainAvailable() {
			return keystore.NewKeychainStore(), nil
		}
		if s := androidKeyringStore(); s != nil {
			return s, nil
		}
		return nil, fmt.Errorf("identity uses keychain backend but keychain is unavailable on this platform")
	}
	if !sessionActive() {
		return nil, fmt.Errorf("passphrase required")
	}
	// The callback re-reads a fresh copy of the cached passphrase per call (the
	// keystore wipes what it receives), so nothing is captured or lingers here.
	return keystore.NewEncryptedFileStore(func() ([]byte, error) {
		pass := sessionPassphraseBytes()
		if len(pass) == 0 {
			return nil, fmt.Errorf("passphrase required")
		}
		return pass, nil
	})
}

// keystoreForCreation builds the keystore to use when CREATING a new identity
// under the given backend. Same shape as nonHWStoreForBackend, but with
// no fallback for keychain — if the chosen backend isn't actually available,
// the caller should have picked a different backend.
func keystoreForCreation(backend string) (keystore.Keystore, error) {
	return nonHWStoreForBackend(backend)
}

// openIdentity opens the named identity into an *identity.Unlocked handle
// with its rich metadata loaded into Info(). Caller MUST Close() when done.
//
// Flow: load index → find entry by name → build keystore for that entry's
// recorded backend → unlock private keys into memguard enclaves → decrypt
// per-identity meta file and overlay onto u.info.
func openIdentity(name string) (*identity.Unlocked, error) {
	store, err := newIdentityStore()
	if err != nil {
		return nil, err
	}
	entries, err := store.LoadIndex()
	if err != nil {
		return nil, fmt.Errorf("loading identity index: %w", err)
	}
	idx, err := findIdentityIndex(entries, name)
	if err != nil {
		return nil, fmt.Errorf("identity %q not found", name)
	}
	return openIdentityByIndex(*idx, store)
}

// openIdentityByIndex is the lower-level entry point for callers that already
// have the index entry loaded (e.g. iterating the index). Pass a non-nil
// store to share it across iterations.
func openIdentityByIndex(idx identity.IdentityIndex, store *identity.Store) (*identity.Unlocked, error) {
	if store == nil {
		var err error
		store, err = newIdentityStore()
		if err != nil {
			return nil, err
		}
	}
	ks, err := keystoreForIdentity(idx)
	if err != nil {
		return nil, err
	}
	stub := identity.Identity{Name: idx.Name, Backend: idx.Backend, HWKey: idx.HWKey}
	unlocked, err := identity.Unlock(ks, stub)
	if err != nil {
		return nil, err
	}
	if err := unlocked.LoadMeta(store, idx); err != nil {
		unlocked.Close()
		return nil, fmt.Errorf("loading identity meta: %w", err)
	}
	return unlocked, nil
}

// findIdentityIndex looks up an entry by name in a loaded index.
// findIdentityIndex resolves an index entry by name OR alias via the icfx
// resolver (single source of truth), so every backend method that selects an
// identity by its `name` argument also accepts the alias.
func findIdentityIndex(entries []identity.IdentityIndex, name string) (*identity.IdentityIndex, error) {
	return identity.FindIndexByNameOrAlias(entries, name)
}

// resolveIdentity opens the identity store, loads the index, and resolves a
// name-OR-alias reference to its entry in one step, returning the store, the
// entries, and the resolved entry. Callers that took a user-supplied ref set
// name = idx.Name to canonicalize (keystore/meta/handoff key by the real name).
func resolveIdentity(name string) (*identity.Store, []identity.IdentityIndex, *identity.IdentityIndex, error) {
	store, err := newIdentityStore()
	if err != nil {
		return nil, nil, nil, err
	}
	entries, err := store.LoadIndex()
	if err != nil {
		return nil, nil, nil, fmt.Errorf("loading identity index: %w", err)
	}
	idx, err := findIdentityIndex(entries, name)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("identity %q not found", name)
	}
	return store, entries, idx, nil
}

// resolveDefaultIdentityName returns the user's default identity name from
// config (config.DefaultIdentity). Falls back to the first index entry if
// no default is configured. Returns "" if there are no identities at all.
func resolveDefaultIdentityName(entries []identity.IdentityIndex) string {
	cfg, err := config.Load()
	if err == nil && cfg.DefaultIdentity != "" {
		for _, e := range entries {
			if e.Name == cfg.DefaultIdentity {
				return cfg.DefaultIdentity
			}
		}
	}
	if len(entries) > 0 {
		return entries[0].Name
	}
	return ""
}

// newStore applies path overrides (needed on mobile, where icfx has no built-in
// data-dir defaults), constructs an icfx store, and wraps the constructor error
// consistently. Backs newIdentityStore/newContactStore/newGroupStore so the
// path-init guard + error-wrap pattern lives in one place.
func newStore[T any](construct func() (T, error), kind string) (T, error) {
	ensurePathsApplied()
	s, err := construct()
	if err != nil {
		var zero T
		return zero, fmt.Errorf("creating %s store: %w", kind, err)
	}
	return s, nil
}

func newIdentityStore() (*identity.Store, error) {
	return newStore(identity.NewStore, "identity")
}

func newContactStore() (*contacts.Store, error) {
	return newStore(contacts.NewStore, "contact")
}
