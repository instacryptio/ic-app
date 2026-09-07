//go:build integration

// Tests for the two-phase import confirm flow: a new contact is applied
// immediately, but an existing contact's key rotation/revocation is cached
// under a one-time token and only applied when ConfirmContactImport echoes the
// matching token. Pure local crypto — no server needed.
package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	icBundle "github.com/instacryptio/icfx/bundle"
	"github.com/instacryptio/icfx/crypto"
	"github.com/instacryptio/icfx/qr"
)

// importOutcomeResp mirrors the backend importOutcome JSON returned by
// processImportData / ImportLockFile / ImportLockQR.
type importOutcomeResp struct {
	Action         int    `json:"action"`
	Applied        bool   `json:"applied"`
	Token          string `json:"token"`
	Name           string `json:"name"`
	Message        string `json:"message"`
	OldFingerprint string `json:"oldFingerprint"`
	NewFingerprint string `json:"newFingerprint"`
}

// sealedLock builds a self-signed lock with the given ID and returns it with the
// keypair, so a test can later sign a rotation/revocation as that identity.
func sealedLock(t *testing.T, id, name string) (qr.LockBundle, *crypto.KeyPair) {
	t.Helper()
	kp, err := crypto.GenerateKeyPair()
	if err != nil {
		t.Fatalf("keypair: %v", err)
	}
	lb := qr.LockBundle{
		ID:          id,
		Name:        name,
		EncPubKey:   kp.EncryptionRecipient,
		SignPubKey:  base64.StdEncoding.EncodeToString(kp.SigningPublicKey),
		Fingerprint: kp.Fingerprint,
		Email:       name + "@example.com",
		Alias:       name,
	}
	sealed, err := qr.SealLock(qrRawSigner{kp.SigningPrivateKey}, lb)
	if err != nil {
		t.Fatalf("seal lock: %v", err)
	}
	return sealed, kp
}

// importOutcome imports raw bundle bytes through the single-QR path and returns
// the parsed outcome.
func importRaw(t *testing.T, ic *IcfxService, data []byte) importOutcomeResp {
	t.Helper()
	raw, err := ic.ImportLockQR(string(data), "")
	if err != nil {
		t.Fatalf("ImportLockQR: %v", err)
	}
	var o importOutcomeResp
	if err := json.Unmarshal([]byte(raw), &o); err != nil {
		t.Fatalf("parsing outcome %q: %v", raw, err)
	}
	return o
}

// importLock imports a lock bundle and returns the outcome.
func importLock(t *testing.T, ic *IcfxService, lock qr.LockBundle) importOutcomeResp {
	t.Helper()
	data, err := qr.MarshalLockBundle(lock)
	if err != nil {
		t.Fatalf("marshaling lock: %v", err)
	}
	return importRaw(t, ic, data)
}

// rotationFor builds a continuity-signed rotation moving contact `id` from
// `old` to a freshly-generated new key, returning the armored bytes and the new
// lock.
func rotationFor(t *testing.T, id, name string, old *crypto.KeyPair) ([]byte, qr.LockBundle) {
	t.Helper()
	newLock, _ := sealedLock(t, id, name)
	rev := icBundle.NewRevocation(id, old.Fingerprint)
	rot := icBundle.RotationBundle{Revocation: rev, NewLock: newLock}
	sealed, err := icBundle.SealRotation(qrRawSigner{old.SigningPrivateKey}, rot)
	if err != nil {
		t.Fatalf("seal rotation: %v", err)
	}
	data, err := icBundle.MarshalRotation(sealed)
	if err != nil {
		t.Fatalf("marshal rotation: %v", err)
	}
	return data, newLock
}

func TestImportOutcome_NewContactAppliedImmediately(t *testing.T) {
	ic := setupLocalEnv(t)
	resetQRImportState()

	lock, _ := sealedLock(t, "IC-newpal", "newpal")
	o := importLock(t, ic, lock)

	if !o.Applied || o.Action != 0 {
		t.Fatalf("new contact must be applied immediately: %+v", o)
	}
	if o.Token != "" {
		t.Fatalf("add must not carry a confirm token: %+v", o)
	}
	list, err := ic.ListContacts()
	if err != nil || !strings.Contains(list, "newpal") {
		t.Fatalf("contact not added: %s err=%v", list, err)
	}
}

func TestImportOutcome_RotationNeedsConfirm_TokenApplies(t *testing.T) {
	ic := setupLocalEnv(t)
	resetQRImportState()

	lock, kp := sealedLock(t, "IC-rotor", "rotor")
	importLock(t, ic, lock)

	data, newLock := rotationFor(t, "IC-rotor", "rotor", kp)
	o := importRaw(t, ic, data)

	if o.Applied || o.Action != 1 || o.Token == "" {
		t.Fatalf("rotation must prompt for confirmation with a token: %+v", o)
	}
	if o.OldFingerprint != crypto.FormatGrouped(kp.Fingerprint) {
		t.Fatalf("old fingerprint: got %q want %q", o.OldFingerprint, crypto.FormatGrouped(kp.Fingerprint))
	}
	if o.NewFingerprint != crypto.FormatGrouped(newLock.Fingerprint) {
		t.Fatalf("new fingerprint: got %q want %q", o.NewFingerprint, crypto.FormatGrouped(newLock.Fingerprint))
	}

	// A wrong token must not apply the cached update.
	if _, err := ic.ConfirmContactImport("deadbeef"); err == nil {
		t.Fatal("confirm with wrong token must fail")
	}
	// The failed confirm consumes the cache — the correct token now finds
	// nothing. Re-import to get a fresh token, then confirm for real.
	o = importRaw(t, ic, data)
	if o.Token == "" {
		t.Fatalf("re-import should yield a fresh token: %+v", o)
	}
	msg, err := ic.ConfirmContactImport(o.Token)
	if err != nil {
		t.Fatalf("confirm with correct token: %v", err)
	}
	if !strings.Contains(msg, "updated") {
		t.Fatalf("unexpected confirm message: %q", msg)
	}

	list, err := ic.ListContacts()
	if err != nil || !strings.Contains(list, newLock.Fingerprint) {
		t.Fatalf("contact keys not updated to new fingerprint: %s err=%v", list, err)
	}
}

func TestImportOutcome_RevocationNeedsConfirm(t *testing.T) {
	ic := setupLocalEnv(t)
	resetQRImportState()

	lock, kp := sealedLock(t, "IC-revme", "revme")
	importLock(t, ic, lock)

	rev := icBundle.NewRevocation("IC-revme", kp.Fingerprint)
	sealed, err := icBundle.SealRevocation(qrRawSigner{kp.SigningPrivateKey}, rev)
	if err != nil {
		t.Fatalf("seal revocation: %v", err)
	}
	data, err := icBundle.MarshalRevocation(sealed)
	if err != nil {
		t.Fatalf("marshal revocation: %v", err)
	}

	o := importRaw(t, ic, data)
	if o.Applied || o.Action != 2 || o.Token == "" {
		t.Fatalf("revocation of a known contact must prompt with a token: %+v", o)
	}
	if o.NewFingerprint != "" {
		t.Fatalf("revocation must have no new fingerprint: %+v", o)
	}

	if _, err := ic.ConfirmContactImport(o.Token); err != nil {
		t.Fatalf("confirm revocation: %v", err)
	}
	// The active keys are cleared (the revoked fingerprint is archived into
	// previous_keys, so a substring check on the whole list would false-match).
	list, err := ic.ListContacts()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	var contacts []struct {
		Alias       string `json:"alias"`
		EncPubKey   string `json:"enc_pub_key"`
		Fingerprint string `json:"fingerprint"`
	}
	if err := json.Unmarshal([]byte(list), &contacts); err != nil {
		t.Fatalf("parsing contact list: %v", err)
	}
	var found bool
	for _, c := range contacts {
		if c.Alias != "revme" {
			continue
		}
		found = true
		if c.Fingerprint != "" || c.EncPubKey != "" {
			t.Fatalf("revoked contact must have cleared active keys: %+v", c)
		}
	}
	if !found {
		t.Fatalf("revoked contact missing from list: %s", list)
	}
}

func TestImportOutcome_SecondImportClobbersStaleToken(t *testing.T) {
	ic := setupLocalEnv(t)
	resetQRImportState()

	lockA, kpA := sealedLock(t, "IC-alpha", "alpha")
	lockB, kpB := sealedLock(t, "IC-bravo", "bravo")
	importLock(t, ic, lockA)
	importLock(t, ic, lockB)

	dataA, _ := rotationFor(t, "IC-alpha", "alpha", kpA)
	first := importRaw(t, ic, dataA)
	dataB, newB := rotationFor(t, "IC-bravo", "bravo", kpB)
	second := importRaw(t, ic, dataB)
	if second.Token == "" || second.Token == first.Token {
		t.Fatalf("second import must issue a distinct token: first=%q second=%q", first.Token, second.Token)
	}

	// The second pending import supersedes the first — the first token is stale.
	if _, err := ic.ConfirmContactImport(first.Token); err == nil {
		t.Fatal("stale token from a superseded import must be rejected")
	}
	// A fresh token for bravo still applies (re-import since the failed confirm
	// above cleared the cache).
	third := importRaw(t, ic, dataB)
	if _, err := ic.ConfirmContactImport(third.Token); err != nil {
		t.Fatalf("confirm superseding import: %v", err)
	}
	list, err := ic.ListContacts()
	if err != nil || !strings.Contains(list, newB.Fingerprint) {
		t.Fatalf("bravo not updated: %s err=%v", list, err)
	}
}

func TestConfirmContactImport_NoPendingRejected(t *testing.T) {
	ic := setupLocalEnv(t)
	resetQRImportState()

	if _, err := ic.ConfirmContactImport("anything"); err == nil {
		t.Fatal("confirm with no pending import must fail")
	}
	if _, err := ic.ConfirmContactImport(""); err == nil {
		t.Fatal("confirm with empty token must fail")
	}
}
