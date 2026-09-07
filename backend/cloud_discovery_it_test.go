//go:build integration

// Integration tests for the app's discovery bridge: publish, search/add,
// requests round-trip, and the notices poll (badge + once-only invite flag).
//
//	CLOUD_TEST_URL=http://localhost:8093 go test -tags integration ./...
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/instacryptio/icfx/cloud"
	"github.com/instacryptio/icfx/config"
	"github.com/instacryptio/icfx/crypto"
	"github.com/instacryptio/icfx/format"
	"github.com/instacryptio/icfx/qr"
)

// setupDiscoveryEnv isolates HOME, signs up an app account, and creates a
// real local identity (file keystore, cached session passphrase).
func setupDiscoveryEnv(t *testing.T) *CloudService {
	t.Helper()
	resetCloudState(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", home+"/.config")
	t.Setenv("XDG_DATA_HOME", home+"/.local/share")

	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	cfg.CloudBaseURL = testBaseURL()
	cfg.Keystore = "file"
	cfg.CloudEnabled = true
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	cachePassphrase([]byte("app-session-pass"))

	ic := &IcfxService{}
	email := "disc-" + time.Now().Format("150405.000000") + "@example.com"
	if _, err := ic.CreateKeys("appuser", "appnick", email, "", "", false); err != nil {
		t.Fatalf("create keys: %v", err)
	}

	s := &CloudService{}
	ctx := context.Background()
	c, err := s.client()
	if err != nil {
		t.Fatal(err)
	}
	pending, err := c.SignUp(ctx, email, "correcthorsebatterystaple", true)
	if err != nil {
		t.Fatalf("signup: %v", err)
	}
	if _, err := c.ConfirmSignUp(ctx, email, pending.DevCode); err != nil {
		t.Fatalf("confirm: %v", err)
	}
	// ConfirmSignUp auto-persisted the session through the SessionStore.
	return s
}

// otherUser is a raw-SDK second account that publishes an identity and can
// send friend requests at the app account.
type otherUser struct {
	c  *cloud.Client
	kp *crypto.KeyPair
	lb qr.LockBundle
}

func newOtherUser(t *testing.T, name string) otherUser {
	t.Helper()
	c, err := cloud.New(testBaseURL())
	if err != nil {
		t.Fatalf("new cloud client: %v", err)
	}
	c.SetInstanceID("other-" + name)
	email := name + "-" + time.Now().Format("150405.000000") + "@example.com"
	pending, err := c.SignUp(context.Background(), email, "correcthorsebatterystaple", true)
	if err != nil {
		t.Fatalf("other signup: %v", err)
	}
	if _, err := c.ConfirmSignUp(context.Background(), email, pending.DevCode); err != nil {
		t.Fatalf("other confirm: %v", err)
	}
	kp, err := crypto.GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	lb := qr.LockBundle{
		ID:          "ic-" + name,
		Name:        name,
		EncPubKey:   kp.EncryptionRecipient,
		SignPubKey:  base64.StdEncoding.EncodeToString(kp.SigningPublicKey),
		Fingerprint: kp.Fingerprint,
		Email:       email,
	}
	lb, err = qr.SealLock(qrRawSigner{kp.SigningPrivateKey}, lb)
	if err != nil {
		t.Fatalf("seal other lock: %v", err)
	}
	raw, err := qr.MarshalLockBundle(lb)
	if err != nil {
		t.Fatal(err)
	}
	err = c.PublishDirectory(context.Background(), cloud.DirectoryPublishInput{
		DisplayName: name,
		Email:       email,
		Fingerprint: lb.Fingerprint,
		LockArmored: string(format.ArmorEncode(raw, format.ArmorLockLabel)),
	})
	if err != nil {
		t.Fatalf("other publish: %v", err)
	}
	return otherUser{c: c, kp: kp, lb: lb}
}

func TestDiscoveryBridgeFlow(t *testing.T) {
	s := setupDiscoveryEnv(t)
	name := "walter-" + time.Now().Format("150405")
	other := newOtherUser(t, name)

	// Publish the app identity, verify state, then search + add the other user.
	if err := s.PublishIdentity("appuser"); err != nil {
		t.Fatalf("publish: %v", err)
	}
	fpsRaw, err := s.PublishedDirectory()
	if err != nil {
		t.Fatalf("published directory: %v", err)
	}
	var fps []map[string]string
	_ = json.Unmarshal([]byte(fpsRaw), &fps)
	if len(fps) != 1 || fps[0]["fingerprint"] == "" {
		t.Fatalf("want 1 published row, got %s", fpsRaw)
	}

	// Search finds the other user (never ourselves).
	hitsRaw, err := s.DirectorySearch(name)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	var hits []map[string]any
	_ = json.Unmarshal([]byte(hitsRaw), &hits)
	if len(hits) != 1 {
		t.Fatalf("want 1 hit, got %s", hitsRaw)
	}
	entryJSON, _ := json.Marshal(hits[0])

	// Add as friend: contact saved + encrypted request queued for the other side.
	resRaw, err := s.AddContactFromDirectory(string(entryJSON), true)
	if err != nil {
		t.Fatalf("add from directory: %v", err)
	}
	if !strings.Contains(resRaw, `"friend_request_sent":true`) {
		t.Fatalf("friend request not sent: %s", resRaw)
	}
	if items, _ := other.c.ListPending(context.Background()); len(items) != 1 || items[0].Kind != cloud.KindContactRequest {
		t.Fatalf("other side inbox: %+v", items)
	}

	// Tampered entry (listing fingerprint != embedded lock) is rejected.
	tampered := map[string]any{}
	for k, v := range hits[0] {
		tampered[k] = v
	}
	tampered["fingerprint"] = "00000000000000000000000000000000"
	tamperedJSON, _ := json.Marshal(tampered)
	if _, err := s.AddContactFromDirectory(string(tamperedJSON), false); err == nil {
		t.Fatal("tampered directory entry must be rejected")
	}

	// Unpublish round-trip.
	if err := s.UnpublishIdentity("appuser"); err != nil {
		t.Fatalf("unpublish: %v", err)
	}
	fpsRaw, _ = s.PublishedDirectory()
	if fpsRaw != "[]" && fpsRaw != "null" {
		t.Fatalf("want no published rows, got %s", fpsRaw)
	}
}

func TestContactRequestsAndNotices(t *testing.T) {
	s := setupDiscoveryEnv(t)
	name := "norah-" + time.Now().Format("150405")
	other := newOtherUser(t, name)

	// The app publishes so the other user can send a request AT its identity.
	if err := s.PublishIdentity("appuser"); err != nil {
		t.Fatalf("publish: %v", err)
	}
	mineRaw, _ := s.PublishedDirectory()
	var mine []map[string]string
	_ = json.Unmarshal([]byte(mineRaw), &mine)
	if len(mine) != 1 {
		t.Fatalf("publish state: %s", mineRaw)
	}
	appFP := mine[0]["fingerprint"]

	// Other user sends a friend request to the app identity's fingerprint.
	info, err := other.c.AccountInfo(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	payload, err := cloud.MarshalContactRequest(info.AccountID, other.lb)
	if err != nil {
		t.Fatal(err)
	}
	// The request is encrypted to the APP identity's enc lock — fetch it from
	// the directory row the app just published.
	hits, err := other.c.SearchDirectory(context.Background(), appFP, 0)
	if err != nil || len(hits) != 1 {
		t.Fatalf("locate app identity: %+v err=%v", hits, err)
	}
	appLock, err := cloud.ParseDirectoryLock(hits[0])
	if err != nil {
		t.Fatal(err)
	}
	if _, err := other.c.SendToFingerprint(context.Background(), appFP, appLock.EncPubKey, cloud.KindContactRequest, payload); err != nil {
		t.Fatalf("send request: %v", err)
	}

	// Notices poll: 1 invite, new_invites fires ONCE, then stays quiet.
	res1raw, err := s.CloudNotices()
	if err != nil {
		t.Fatal(err)
	}
	var res1 map[string]any
	_ = json.Unmarshal([]byte(res1raw), &res1)
	if res1["invites"] != float64(1) || res1["new_invites"] != true {
		t.Fatalf("first poll: %s", res1raw)
	}
	res2raw, _ := s.CloudNotices()
	var res2 map[string]any
	_ = json.Unmarshal([]byte(res2raw), &res2)
	if res2["invites"] != float64(1) || res2["new_invites"] == true {
		t.Fatalf("second poll must not re-flag: %s", res2raw)
	}

	// The inbox lists the decrypted request; accept adds the contact and
	// notifies the requester (accept-back lands in THEIR inbox).
	reqRaw, err := s.ContactRequests()
	if err != nil {
		t.Fatalf("contact requests: %v", err)
	}
	var reqs []map[string]any
	_ = json.Unmarshal([]byte(reqRaw), &reqs)
	if len(reqs) != 1 || reqs[0]["name"] != name {
		t.Fatalf("requests: %s", reqRaw)
	}
	respRaw, err := s.RespondContactRequest(reqs[0]["id"].(string), true)
	if err != nil {
		t.Fatalf("accept: %v", err)
	}
	if !strings.Contains(respRaw, `"notified":true`) {
		t.Fatalf("accept must notify: %s", respRaw)
	}
	if items, _ := other.c.ListPending(context.Background()); len(items) != 1 || items[0].Kind != cloud.KindContactAccept {
		t.Fatalf("requester inbox after accept: %+v", items)
	}

	// Inbox now empty; notices drop to zero invites.
	reqRaw, _ = s.ContactRequests()
	if reqRaw != "[]" {
		t.Fatalf("inbox after accept: %s", reqRaw)
	}
}
