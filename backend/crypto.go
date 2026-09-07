package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/hkdb/flugo/pkg/filechooser"
	"github.com/instacryptio/icfx/contacts"
	"github.com/instacryptio/icfx/decrypt"
	"github.com/instacryptio/icfx/encrypt"
	"github.com/instacryptio/icfx/format"
	"github.com/instacryptio/icfx/groups"
	"github.com/instacryptio/icfx/identity"
	"github.com/instacryptio/icfx/recipient"
	"github.com/instacryptio/icfx/validate"
)

// Encrypt encrypts a file for one or more recipients (and optionally self).
// Returns a JSON WriteResult for the Dart-side handleWriteResult().
//
// signerName resolves against name/email/nickname (first match wins) for the
// user's own identities; empty falls back to the configured default. Each
// entry in recipients may be a contact alias/email/nickname or a raw age1pq1
// public key. age encrypts one ciphertext to all recipients — any one of them
// can decrypt it. When alsoSelf is true the signer's own public key is added
// (deduped). At least one recipient or alsoSelf is required.
func (s *IcfxService) Encrypt(filePath string, recipients []string, alsoSelf bool, signerName string, force bool) (string, error) {
	idStore, err := newIdentityStore()
	if err != nil {
		return "", err
	}
	contactStore, err := newContactStore()
	if err != nil {
		return "", err
	}

	entries, err := idStore.LoadIndex()
	if err != nil {
		return "", fmt.Errorf("loading identity index: %w", err)
	}
	if len(entries) == 0 {
		return "", fmt.Errorf("no identities found; create one first")
	}

	resolvedSigner := signerName
	if resolvedSigner == "" {
		resolvedSigner = resolveDefaultIdentityName(entries)
	}
	if resolvedSigner == "" {
		return "", fmt.Errorf("no default identity configured")
	}

	// Open the signer once. We reuse this handle for both signing and the
	// "encrypt-to-self" default (so we have EncPubKey from the meta).
	unlocked, err := openIdentity(resolvedSigner)
	if err != nil {
		return "", fmt.Errorf("opening signer identity %q: %w", resolvedSigner, err)
	}
	defer unlocked.Close()
	signerInfo := unlocked.Info()

	// Expand any group references into their members' locks, so a recipient may
	// be a contact OR a group (the app's unified picker mixes both). Contacts
	// take precedence over a same-named group. Group logic lives in icfx so the
	// CLI resolves identically.
	var groupList []groups.Group
	if gs, gerr := newGroupStore(); gerr == nil {
		groupList, _ = gs.List()
	}
	contactList, _ := contactStore.Load()
	// Advisory warnings (composed in icfx) for group members that can't be
	// recipients — no active lock, or a deleted contact. Surfaced to the UI so
	// the sender knows some group members won't be able to decrypt.
	expanded, expandWarnings := recipient.ExpandGroups(recipients, groupList, contactList)

	// Resolve recipients. alsoSelf appends the signer's own lock (a raw
	// age1pq1 key, deduped by ForEncryptMany). At least one recipient or
	// alsoSelf is required (the UI enforces this too).
	refs := append([]string{}, expanded...)
	if alsoSelf {
		refs = append(refs, signerInfo.EncPubKey)
	}
	if len(refs) == 0 {
		return "", fmt.Errorf("no recipients selected")
	}
	recipientKeys, err := resolveRecipientKeys(refs, contactStore, entries)
	if err != nil {
		return "", err
	}
	for _, k := range recipientKeys {
		if err := validate.ValidateEncPubKey(k); err != nil {
			return "", fmt.Errorf("recipient key: %w", err)
		}
	}

	// v3 container: streams to disk in constant memory. Metadata always travels
	// encrypted inside the payload; the app always emits private containers (no
	// plaintext header) — automation that needs public headers uses icc's
	// --public-meta.
	meta := format.Metadata{
		SenderFingerprint: signerInfo.Fingerprint,
		Timestamp:         time.Now(),
		OriginalFilename:  filepath.Base(filePath),
		IsSigned:          true,
	}

	in, err := os.Open(filePath)
	if err != nil {
		return "", fmt.Errorf("opening input file: %w", err)
	}
	defer in.Close()

	targetPath := filePath + ".icfx"
	result, err := filechooser.WriteFileStream(targetPath, force, func(w io.Writer) error {
		return encrypt.EncryptStream(w, in, recipientKeys, unlocked, meta, format.ProfilePrivateStreaming)
	})
	if err != nil {
		return "", fmt.Errorf("writing output: %w", err)
	}

	resultJSON, err := json.Marshal(encryptResult{WriteResult: result, Warnings: expandWarnings})
	if err != nil {
		return "", fmt.Errorf("marshaling write result: %w", err)
	}
	return string(resultJSON), nil
}

// encryptResult extends WriteResult with advisory warnings (e.g. group members
// skipped for having no active lock) for the Dart-side handleWriteResult().
type encryptResult struct {
	filechooser.WriteResult
	Warnings []string `json:"warnings,omitempty"`
}

// Decrypt decrypts an encrypted file.
// decryptResult extends WriteResult with verification info for the Dart side.
type decryptResult struct {
	filechooser.WriteResult
	VerifyMsg      string `json:"verify_msg,omitempty"`
	RevokedWarning string `json:"revoked_warning,omitempty"`
}

// Decrypt decrypts an encrypted file.
// Returns a JSON decryptResult (extends WriteResult) for the Dart-side handleWriteResult().
//
// identityName resolves against name/email/nickname for the user's own
// identities; empty falls back to the configured default.
func (s *IcfxService) Decrypt(filePath, identityName string, force bool) (string, error) {
	idStore, err := newIdentityStore()
	if err != nil {
		return "", err
	}
	entries, err := idStore.LoadIndex()
	if err != nil {
		return "", fmt.Errorf("loading identity index: %w", err)
	}
	if len(entries) == 0 {
		return "", fmt.Errorf("no identities found; create one first")
	}

	// Pick which identity to decrypt with. Default = configured default; flag
	// overrides. ic-app's UI passes a name from the identity picker.
	targetName := identityName
	if targetName == "" {
		targetName = resolveDefaultIdentityName(entries)
	}
	if targetName == "" {
		return "", fmt.Errorf("no default identity configured")
	}
	if _, err := findIdentityIndex(entries, targetName); err != nil {
		return "", fmt.Errorf("identity %q not found", targetName)
	}

	unlocked, err := openIdentity(targetName)
	if err != nil {
		return "", fmt.Errorf("opening identity %q: %w", targetName, err)
	}
	defer unlocked.Close()
	target := unlocked.Info()

	// Verification is advisory: load contacts best-effort.
	var contactList []contacts.Contact
	if store, cerr := newContactStore(); cerr == nil {
		contactList, _ = store.Load()
	}

	// Open the input and sniff the format from a small head. The binary paths
	// stream to the output in constant memory; armored input (small/pasteable)
	// is buffered.
	in, err := os.Open(filePath)
	if err != nil {
		return "", fmt.Errorf("opening input file: %w", err)
	}
	defer in.Close()
	head := make([]byte, 64)
	n, _ := io.ReadFull(in, head)
	if _, serr := in.Seek(0, io.SeekStart); serr != nil {
		return "", serr
	}
	detected := format.Detect(head[:n])

	outputName := filepath.Base(filePath) + ".decrypted"
	if strings.HasSuffix(filePath, ".icfx") {
		outputName = strings.TrimSuffix(filepath.Base(filePath), ".icfx")
	}
	targetPath := filepath.Join(filepath.Dir(filePath), outputName)

	var verifyResult decrypt.VerifyResult
	produce := func(w io.Writer) error {
		switch detected {
		case format.FormatArmored:
			data, rerr := io.ReadAll(in)
			if rerr != nil {
				return rerr
			}
			payload, label, aerr := format.ArmorDecode(data)
			if aerr != nil {
				return fmt.Errorf("decoding armored input: %w", aerr)
			}
			if label != format.ArmorICFXLabel {
				return fmt.Errorf("unsupported armor label: %s", label)
			}
			res, derr := decrypt.DecryptAndVerifyStream(bytes.NewReader(payload), w, unlocked, contactList)
			verifyResult = res
			return derr
		case format.FormatICFX:
			res, derr := decrypt.DecryptAndVerifyStream(in, w, unlocked, contactList)
			verifyResult = res
			return derr
		default:
			r, derr := unlocked.DecryptStream(in)
			if derr != nil {
				return derr
			}
			_, cerr := io.Copy(w, r)
			return cerr
		}
	}

	wr, err := filechooser.WriteFileStream(targetPath, force, produce)
	if err != nil {
		return "", err
	}

	revokedWarning := ""
	if target.Status == identity.StatusRevoked {
		revokedWarning = fmt.Sprintf("WARNING: Decrypted using revoked identity '%s'", target.Name)
	}

	result := decryptResult{
		WriteResult:    wr,
		VerifyMsg:      verifyMsgFor(verifyResult),
		RevokedWarning: revokedWarning,
	}

	resultJSON, err := json.Marshal(result)
	if err != nil {
		return "", fmt.Errorf("marshaling result: %w", err)
	}
	return string(resultJSON), nil
}

// verifyMsgFor renders an icfx/decrypt VerifyResult as the app's verify_msg
// string (the Dart layer shows it verbatim). Empty for an unsigned file.
func verifyMsgFor(v decrypt.VerifyResult) string {
	switch v.Status {
	case decrypt.VerifyOK:
		switch {
		case v.SignerIdentity != "":
			return fmt.Sprintf("Signature verified (identity: %s)", v.SignerIdentity)
		case v.UsedRevokedKey:
			return fmt.Sprintf("Signature verified (contact: %s, using revoked key from %s)", v.SignerAlias, v.RevokedAt.Format("2006-01-02"))
		default:
			return fmt.Sprintf("Signature verified (contact: %s)", v.SignerAlias)
		}
	case decrypt.VerifyNoMetadata:
		return "WARNING: Signature could not be verified! Private pre-v2 container carries no sender metadata"
	case decrypt.VerifyUnverifiable:
		return "WARNING: Signature could not be verified! Sender: " + v.SignerFP
	default: // VerifyUnsigned
		return ""
	}
}

// resolveRecipientKeys resolves one or more recipient references (name, alias,
// email, nickname, or raw age1pq1 hybrid public key) to their public keys,
// deduped, for multi-recipient encryption.
//
// Lookup order per ref: raw age1pq1 → contacts (alias/email/nickname, all
// plaintext) → own identities by name (unlocking when needed — email/nickname
// against own identities would require unlocking each, which is expensive).
func resolveRecipientKeys(tos []string, contactStore *contacts.Store, entries []identity.IdentityIndex) ([]string, error) {
	contactList, _ := contactStore.Load() // resolution tolerates a missing store
	return recipient.ForEncryptMany(tos, contactList, entries, func(idx identity.IdentityIndex) (string, error) {
		u, err := openIdentityByIndex(idx, nil)
		if err != nil {
			return "", err
		}
		info := u.Info()
		u.Close()
		return info.EncPubKey, nil
	})
}
