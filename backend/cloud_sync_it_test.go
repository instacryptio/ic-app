//go:build integration

package main

// Reproduces the field-reported bug: sync once (password), "restart" the app,
// sync again → must NOT 401. Requires an isolated dev-mode server with a very
// short session TTL, e.g.:
//
//	IC_CLOUD_HTTP_ADDR=:8093 IC_CLOUD_DEV=true IC_CLOUD_SESSION_TTL=2s ... ic-cloud
//	CLOUD_TEST_URL=http://localhost:8093 go test -tags integration ./...
//
// Covers both halves of the fix:
//  1. authedClient refreshes an expired access token instead of 401ing.
//  2. Sync's final SyncVersions save must not clobber tokens persisted
//     mid-sync (refresh or fallback login) with the stale ones it loaded.

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/instacryptio/icfx/config"
)

func testBaseURL() string {
	if v := os.Getenv("CLOUD_TEST_URL"); v != "" {
		return v
	}
	return "http://localhost:8093"
}

// resetCloudState drops the process-global cloud client (and pending email) so
// a test starting under a fresh HOME rebuilds the client against its own config
// dir. The SessionStore binds to a dir at build time, so a client cached by a
// prior test would otherwise read/write that test's directory. Production has a
// single HOME and never needs this; it exists only because the suite runs many
// isolated HOMEs in one process.
func resetCloudState(t *testing.T) {
	t.Helper()
	cloudMu.Lock()
	cloudClient = nil
	pendingEmail = ""
	cloudMu.Unlock()
	notifStoreMu.Lock()
	notifStoreInst = nil // rebound to the fresh HOME's config dir on next use
	notifStoreMu.Unlock()
}

func TestSyncSurvivesRestartAndTokenExpiry(t *testing.T) {
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
	cfg.CloudSyncContacts = false
	cfg.CloudSyncSettings = false
	cfg.CloudSyncIdentities = true
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}

	// The file EncKeyStore is protected by the app session passphrase.
	cachePassphrase([]byte("app-session-pass"))

	ctx := context.Background()
	s := &CloudService{}
	email := "restart-" + time.Now().Format("150405.000000") + "@example.com"
	const pw = "correcthorsebatterystaple"

	// Account setup through the app's own client (dev-mode code echo).
	c, err := s.client()
	if err != nil {
		t.Fatal(err)
	}
	pending, err := c.SignUp(ctx, email, pw, true)
	if err != nil {
		t.Fatalf("signup: %v", err)
	}
	if pending.DevCode == "" {
		t.Fatal("no dev_code — run the test server with IC_CLOUD_DEV=true")
	}
	if _, err := c.ConfirmSignUp(ctx, email, pending.DevCode); err != nil {
		t.Fatalf("confirm: %v", err)
	}
	// This test simulates token expiry with a short sleep, so it only makes
	// sense against a server running IC_CLOUD_SESSION_TTL≈2s.
	if ttl := time.Until(c.Tokens().ExpiresAt); ttl > 30*time.Second {
		t.Skipf("requires a short-TTL server (IC_CLOUD_SESSION_TTL=2s); server issued %v tokens", ttl.Round(time.Second))
	}
	// ConfirmSignUp already auto-persisted the tokens through the SessionStore.

	// Sync #1: encKey is in memory (fresh signup) → synced; key persisted.
	raw, err := s.Sync()
	if err != nil {
		t.Fatalf("sync 1: %v", err)
	}
	requireSynced(t, raw)
	tok1 := currentSavedToken(t)

	// "Quit and relaunch": drop the process-lifetime client, and wait out the
	// short server-side access-token TTL so the persisted token is expired —
	// exactly the field scenario.
	cloudMu.Lock()
	cloudClient = nil
	cloudMu.Unlock()
	time.Sleep(3 * time.Second)

	// Sync #2 must auto-refresh (no 401, no password) and the refreshed
	// tokens must survive Sync's final state save.
	raw, err = s.Sync()
	if err != nil {
		t.Fatalf("sync 2 after restart+expiry: %v", err)
	}
	requireSynced(t, raw)
	tok2 := currentSavedToken(t)
	if tok1 == tok2 {
		t.Fatal("expected refreshed tokens to be persisted (stale save clobbered them?)")
	}

	// Sync #3 immediately: still fine with the persisted fresh tokens.
	cloudMu.Lock()
	cloudClient = nil
	cloudMu.Unlock()
	raw, err = s.Sync()
	if err != nil {
		t.Fatalf("sync 3: %v", err)
	}
	requireSynced(t, raw)
}

func currentSavedToken(t *testing.T) string {
	t.Helper()
	s := &CloudService{}
	c, err := s.client()
	if err != nil {
		t.Fatalf("client: %v", err)
	}
	tok, err := c.SessionStore().LoadTokens(c.AuthEmail())
	if err != nil || tok == nil {
		t.Fatalf("session tokens unreadable: err=%v", err)
	}
	return tok.AccessToken
}

func requireSynced(t *testing.T, raw string) {
	t.Helper()
	var out []map[string]any
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatalf("parse %q: %v", raw, err)
	}
	for _, o := range out {
		if errStr, _ := o["error"].(string); errStr != "" {
			t.Fatalf("sync outcome error: %v", o)
		}
	}
}
