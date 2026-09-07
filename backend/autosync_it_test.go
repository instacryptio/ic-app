//go:build integration

package main

// Proves the auto-sync engine end-to-end against a live dev-mode server:
// another device pushes → the SSE doorbell rings → the engine syncs within
// seconds, silently (persisted encKey, no prompts) — and stops on logout.
//
//	IC_CLOUD_HTTP_ADDR=:8093 IC_CLOUD_DEV=true ... ic-cloud
//	CLOUD_TEST_URL=http://localhost:8093 go test -tags integration ./...

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	icfxcloud "github.com/instacryptio/icfx/cloud"
	"github.com/instacryptio/icfx/config"
	"github.com/instacryptio/icfx/identity"
	"github.com/instacryptio/icfx/profile"
)

func TestAutoSyncEngineReactsToDoorbell(t *testing.T) {
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
	cfg.CloudAutoSyncMinutes = 60 // ticker irrelevant; the doorbell drives this test
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	cachePassphrase([]byte("app-session-pass"))

	s := &CloudService{}
	email := fmt.Sprintf("autosync-%d@example.com", time.Now().UnixNano())
	const pw = "correcthorsebatterystaple"

	ctx := context.Background()
	c, err := s.client()
	if err != nil {
		t.Fatal(err)
	}
	pending, err := c.SignUp(ctx, email, pw, true)
	if err != nil {
		t.Fatalf("signup: %v", err)
	}
	if _, err := c.ConfirmSignUp(ctx, email, pending.DevCode); err != nil {
		t.Fatalf("confirm: %v", err)
	}
	// ConfirmSignUp auto-persisted the session through the SessionStore.

	// Start the engine (long ticker — only the doorbell can trigger syncs
	// after the startup kick settles).
	if err := s.EnsureAutoSync(); err != nil {
		t.Fatalf("ensure autosync: %v", err)
	}
	t.Cleanup(func() {
		autoSyncMu.Lock()
		if autoSyncCancel != nil {
			autoSyncCancel()
			autoSyncCancel = nil
		}
		autoSyncMu.Unlock()
	})

	// Wait for the startup sync to record a baseline.
	baseline := waitLastSync(t, time.Time{}, 15*time.Second)

	// "Another device": a fresh SDK login pushes a new identities blob.
	other := cloudNewClientForTest(t, email, pw)
	if err := other.PushIdentities(ctx, func(idx identity.IdentityIndex) (profile.RoamingEntry, error) {
		return profile.RoamingEntry{}, fmt.Errorf("no identities on pusher")
	}); err != nil {
		t.Fatalf("other device push: %v", err)
	}

	// The doorbell must trigger a background sync within seconds.
	after := waitLastSync(t, baseline, 15*time.Second)
	lastSyncMu.Lock()
	summary, errText := lastSync.Summary, lastSync.Err
	lastSyncMu.Unlock()
	if errText != "" {
		t.Fatalf("background sync error: %s", errText)
	}
	// The stateful engine reports the honest action: remote moved, local
	// unchanged → a pull, never a push-back.
	if !strings.Contains(summary, "identities: pulled") {
		t.Fatalf("unexpected summary after doorbell: %q (at %v)", summary, after)
	}

	// Loop-death: the pull above must NOT ring our own doorbell (origin
	// suppression) nor push back (stateful identities). lastSync must hold
	// still for a while — the old engine re-synced every ~2s forever here.
	settle := after
	time.Sleep(6 * time.Second)
	lastSyncMu.Lock()
	still := lastSync.At
	lastSyncMu.Unlock()
	if still.After(settle) {
		t.Fatalf("engine re-triggered itself: baseline %v, then %v — feedback loop lives", settle, still)
	}

	// Logout stops the engine.
	if err := s.Logout(); err != nil {
		t.Fatalf("logout: %v", err)
	}
	autoSyncMu.Lock()
	running := autoSyncCancel != nil
	autoSyncMu.Unlock()
	if running {
		t.Fatal("engine must stop after logout")
	}
}

// waitLastSync blocks until lastSync.At moves past prev, returning the new
// timestamp.
func waitLastSync(t *testing.T, prev time.Time, timeout time.Duration) time.Time {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		lastSyncMu.Lock()
		at := lastSync.At
		lastSyncMu.Unlock()
		if at.After(prev) {
			return at
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatalf("no sync recorded after %v (prev %v)", timeout, prev)
	return time.Time{}
}

// cloudNewClientForTest logs a second SDK client into the account (the
// "other device" pushing changes).
func cloudNewClientForTest(t *testing.T, email, pw string) *icfxcloud.Client {
	t.Helper()
	c, err := icfxcloud.New(testBaseURL())
	if err != nil {
		t.Fatalf("new cloud client: %v", err)
	}
	// A distinct origin tag: same process, but this client PLAYS another
	// device — without it, echo suppression would (correctly) swallow the
	// doorbell its pushes are supposed to ring.
	c.SetInstanceID("test-other-device")
	if _, err := c.LogIn(context.Background(), email, pw); err != nil {
		t.Fatalf("other device login: %v", err)
	}
	return c
}
