//go:build integration

// Tests for the staged hardware-key HMAC response path (M5): the 20-byte KEK
// factor rides the secure channel, is cached for the auto-lock window, is
// wiped on idle even for keychain (HWKEKNone) identities, and can be cleared
// explicitly. Pure in-memory — no server, no device.
package main

import (
	"testing"
	"time"

	"github.com/hkdb/flugo/pkg/bridge"
)

func stageHW(t *testing.T, s *IcfxService, resp []byte) {
	t.Helper()
	secret, err := bridge.NewSecret(resp) // wipes its input
	if err != nil {
		t.Fatalf("new secret: %v", err)
	}
	if err := s.StageHWResponse(secret); err != nil {
		t.Fatalf("stage: %v", err)
	}
}

func resetHWState() {
	clearStagedHWResponse()
	hwResponses.Lock()
	hwResponses.byName = nil
	hwResponses.Unlock()
	sessionMu.Lock()
	if sessionPass != nil {
		if b, err := sessionPass.Open(); err == nil {
			b.Destroy()
		}
		sessionPass = nil
	}
	sessionMu.Unlock()
}

func TestInjectHWRequiresStaged(t *testing.T) {
	resetHWState()
	ic := &IcfxService{}
	if err := ic.InjectHWResponse("id-a", "", ""); err == nil {
		t.Fatal("InjectHWResponse without a staged secret must error")
	}
	if hasCachedHWResponses() {
		t.Fatal("failed inject must not cache anything")
	}
}

func TestStageInjectCacheAndClear(t *testing.T) {
	resetHWState()
	ic := &IcfxService{}

	stageHW(t, ic, make([]byte, 20))
	if err := ic.InjectHWResponse("id-a", "serial-1", "yubikey"); err != nil {
		t.Fatalf("inject: %v", err)
	}
	if !hasCachedHWResponses() {
		t.Fatal("response should be cached after inject")
	}
	if has, _ := ic.HasHWResponse("id-a"); !has {
		t.Fatal("HasHWResponse should report the cached entry")
	}

	// The staged secret is single-use — a second inject must re-stage.
	if err := ic.InjectHWResponse("id-a", "", ""); err == nil {
		t.Fatal("staged hw response must be single-use")
	}

	// Explicit clear drops it (canceled flow).
	if err := ic.ClearHWResponse("id-a"); err != nil {
		t.Fatalf("clear: %v", err)
	}
	if hasCachedHWResponses() {
		t.Fatal("ClearHWResponse must drop the cached entry")
	}
}

func TestAutoLockWipesHWResponseWithoutPassphrase(t *testing.T) {
	resetHWState()
	ic := &IcfxService{}

	// Keychain-backed (HWKEKNone) identity: HW response cached, NO sessionPass.
	stageHW(t, ic, make([]byte, 20))
	if err := ic.InjectHWResponse("id-a", "", ""); err != nil {
		t.Fatalf("inject: %v", err)
	}

	now := time.Now()
	// Within the window: not expired.
	sessionMu.Lock()
	lastUnlockTouch = now
	sessionMu.Unlock()
	if autoLockExpired(now.Add(2*time.Minute), 10) {
		t.Fatal("must not expire within the auto-lock window")
	}
	// Disabled auto-lock: never expires.
	if autoLockExpired(now.Add(48*time.Hour), 0) {
		t.Fatal("auto-lock disabled (0) must never expire")
	}
	// Past the window with only a HW response cached: MUST expire (the M5 gap).
	if !autoLockExpired(now.Add(11*time.Minute), 10) {
		t.Fatal("HW response must expire on idle even without a session passphrase")
	}

	// And the watcher's wipe (clearSessionPass) actually clears it.
	clearSessionPass()
	if hasCachedHWResponses() {
		t.Fatal("auto-lock wipe must clear the HW response cache")
	}

	// Nothing cached → never expired.
	if autoLockExpired(now.Add(11*time.Minute), 10) {
		t.Fatal("nothing cached must not report expired")
	}
}
