//go:build integration

// Integration tests for the animated QR contact import path: frames scanned
// in any order accumulate in the shared collector, legacy 2-part paired QR
// still imports, and QR exports produce decodable animated GIFs. Pure local
// crypto — no server needed.
package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image/gif"
	"math/rand"
	"strings"
	"testing"

	"github.com/instacryptio/icfx/crypto"
	"github.com/instacryptio/icfx/qr"
)

// qrRawSigner signs with a raw ML-DSA-65 private key (test helper).
type qrRawSigner struct{ key []byte }

func (r qrRawSigner) Sign(data []byte) ([]byte, error) { return crypto.Sign(data, r.key) }

type qrPartResp struct {
	Complete bool            `json:"complete"`
	Received int             `json:"received"`
	Total    int             `json:"total"`
	Result   json.RawMessage `json:"result"`
}

func importPart(t *testing.T, s *IcfxService, payload []byte) qrPartResp {
	t.Helper()
	raw, err := s.ImportLockQRPart(string(payload), "")
	if err != nil {
		t.Fatalf("ImportLockQRPart: %v", err)
	}
	var resp qrPartResp
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatalf("parsing response %q: %v", raw, err)
	}
	return resp
}

func testLockBundle(t *testing.T, name string) qr.LockBundle {
	t.Helper()
	kp, err := crypto.GenerateKeyPair()
	if err != nil {
		t.Fatalf("keypair: %v", err)
	}
	lb := qr.LockBundle{
		ID:          "IC-" + name,
		Name:        name,
		EncPubKey:   kp.EncryptionRecipient,
		SignPubKey:  base64.StdEncoding.EncodeToString(kp.SigningPublicKey),
		Fingerprint: kp.Fingerprint,
		Email:       name + "@example.com",
		Alias:       name,
	}
	sealed, err := qr.SealLock(qrRawSigner{kp.SigningPrivateKey}, lb)
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	return sealed
}

func resetQRImportState() {
	frameCollector.Reset()
}

func TestImportLockQRPart_AnimatedShuffled(t *testing.T) {
	ic := setupLocalEnv(t)
	resetQRImportState()

	bundle := testLockBundle(t, "animfriend")
	frames, err := qr.MarshalAnimatedQR(bundle)
	if err != nil {
		t.Fatal(err)
	}
	if len(frames) < 3 {
		t.Fatalf("expected a multi-frame bundle, got %d frames", len(frames))
	}

	shuffled := make([][]byte, len(frames))
	copy(shuffled, frames)
	rng := rand.New(rand.NewSource(7))
	rng.Shuffle(len(shuffled), func(i, j int) { shuffled[i], shuffled[j] = shuffled[j], shuffled[i] })

	for i, frame := range shuffled[:len(shuffled)-1] {
		resp := importPart(t, ic, frame)
		if resp.Complete {
			t.Fatalf("frame %d: unexpectedly complete", i+1)
		}
		if resp.Received != i+1 || resp.Total != len(frames) {
			t.Fatalf("frame %d: progress %d/%d, want %d/%d", i+1, resp.Received, resp.Total, i+1, len(frames))
		}
	}

	final := importPart(t, ic, shuffled[len(shuffled)-1])
	if !final.Complete {
		t.Fatalf("final frame: not complete: %+v", final)
	}
	if final.Received != len(frames) || final.Total != len(frames) {
		t.Fatalf("final progress %d/%d, want %d/%d", final.Received, final.Total, len(frames), len(frames))
	}
	var outcome importOutcomeResp
	if err := json.Unmarshal(final.Result, &outcome); err != nil {
		t.Fatalf("parsing import outcome %q: %v", final.Result, err)
	}
	if !outcome.Applied || outcome.Action != 0 {
		t.Fatalf("new contact should be applied immediately: %+v", outcome)
	}

	list, err := ic.ListContacts()
	if err != nil || !strings.Contains(list, "animfriend") {
		t.Fatalf("imported contact missing: %s err=%v", list, err)
	}
}

func TestImportLockQRPart_RemovedPairedFormatRejected(t *testing.T) {
	ic := setupLocalEnv(t)
	resetQRImportState()

	// A part from the removed 2-part paired format has no "v" key, so it
	// routes to the raw import path and must fail loudly there — never
	// silently accumulate.
	legacyPart := `{"p":1,"n":2,"bid":"a1b2c3d4","d":{"name":"old","enc_pub_key":"age1pq1x"}}`
	if _, err := ic.ImportLockQRPart(legacyPart, ""); err == nil {
		t.Fatal("removed paired-format part must be rejected")
	}
}

func TestImportLockQRPart_RestartOnNewBundle(t *testing.T) {
	ic := setupLocalEnv(t)
	resetQRImportState()

	framesA, err := qr.MarshalAnimatedQR(testLockBundle(t, "abandoned"))
	if err != nil {
		t.Fatal(err)
	}
	framesB, err := qr.MarshalAnimatedQR(testLockBundle(t, "fresh"))
	if err != nil {
		t.Fatal(err)
	}

	// Partial scan of A, then a full scan of B — B must import cleanly.
	for _, frame := range framesA[:3] {
		importPart(t, ic, frame)
	}
	var final qrPartResp
	for _, frame := range framesB {
		final = importPart(t, ic, frame)
	}
	if !final.Complete {
		t.Fatalf("bundle B not complete after all frames: %+v", final)
	}

	list, err := ic.ListContacts()
	if err != nil || !strings.Contains(list, "fresh") {
		t.Fatalf("imported contact missing: %s err=%v", list, err)
	}
	if strings.Contains(list, "abandoned") {
		t.Fatal("partial bundle A must not have imported")
	}
}

func TestExportLockQR_AnimatedGIF(t *testing.T) {
	ic := setupLocalEnv(t)
	resetQRImportState()

	if _, err := ic.CreateKeys("gifowner", "", "gif@example.com", "", "", false); err != nil {
		t.Fatalf("create keys: %v", err)
	}

	b64, err := ic.ExportLockQR("gifowner")
	if err != nil {
		t.Fatalf("ExportLockQR: %v", err)
	}
	assertAnimatedGIF(t, b64)
}

func TestExportContactLockQR_AnimatedGIF(t *testing.T) {
	ic := setupLocalEnv(t)
	resetQRImportState()

	bundle := testLockBundle(t, "gifcontact")
	frames, err := qr.MarshalAnimatedQR(bundle)
	if err != nil {
		t.Fatal(err)
	}
	var final qrPartResp
	for _, frame := range frames {
		final = importPart(t, ic, frame)
	}
	if !final.Complete {
		t.Fatalf("contact import incomplete: %+v", final)
	}

	b64, err := ic.ExportContactLockQR("gifcontact")
	if err != nil {
		t.Fatalf("ExportContactLockQR: %v", err)
	}
	assertAnimatedGIF(t, b64)
}

func assertAnimatedGIF(t *testing.T, b64 string) {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		t.Fatalf("decoding base64: %v", err)
	}
	decoded, err := gif.DecodeAll(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("decoding GIF: %v", err)
	}
	if len(decoded.Image) < 2 {
		t.Fatalf("animated GIF must have multiple frames, got %d", len(decoded.Image))
	}
	if decoded.LoopCount != 0 {
		t.Errorf("LoopCount: got %d, want 0 (infinite)", decoded.LoopCount)
	}
}
