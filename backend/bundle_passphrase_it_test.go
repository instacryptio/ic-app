//go:build integration

// Integration tests for the staged bundle-passphrase path: export/import/
// peek consume a single-use memguard-staged secret instead of taking a
// plaintext string over the bridge. Pure local crypto — no server needed.
package main

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hkdb/flugo/pkg/bridge"
	"github.com/instacryptio/icfx/config"
)

func stagePass(t *testing.T, s *IcfxService, pass string) {
	t.Helper()
	// bridge.NewSecret wipes its input; hand it a throwaway copy.
	secret, err := bridge.NewSecret([]byte(pass))
	if err != nil {
		t.Fatalf("new secret: %v", err)
	}
	if err := s.StageBundlePassphrase(secret); err != nil {
		t.Fatalf("stage: %v", err)
	}
}

func setupLocalEnv(t *testing.T) *IcfxService {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", home+"/.config")
	t.Setenv("XDG_DATA_HOME", home+"/.local/share")

	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	cfg.Keystore = "file"
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	cachePassphrase([]byte("session-pass-for-tests"))
	return &IcfxService{}
}

func TestStagedIdentityExportImportRoundTrip(t *testing.T) {
	ic := setupLocalEnv(t)
	if _, err := ic.CreateKeys("roundtrip", "", "rt@example.com", "", "", false); err != nil {
		t.Fatalf("create keys: %v", err)
	}

	// Consuming without staging errors clearly.
	if _, err := ic.ExportIdentity("roundtrip"); err == nil || !strings.Contains(err.Error(), "StageBundlePassphrase") {
		t.Fatalf("unstaged export must error with guidance, got %v", err)
	}

	// Export with a staged passphrase.
	stagePass(t, ic, "bundle-pass-123")
	armored, err := ic.ExportIdentity("roundtrip")
	if err != nil {
		t.Fatalf("export: %v", err)
	}
	bundlePath := filepath.Join(t.TempDir(), "roundtrip.icid")
	if err := os.WriteFile(bundlePath, []byte(armored), 0o600); err != nil {
		t.Fatal(err)
	}

	// The staged secret was consumed — a second export must re-stage.
	if _, err := ic.ExportIdentity("roundtrip"); err == nil {
		t.Fatal("staged passphrase must be single-use")
	}

	// Fresh device: peek then import, staging before each consuming call.
	ic2 := setupLocalEnv(t)
	stagePass(t, ic2, "bundle-pass-123")
	peekJSON, err := ic2.PeekIdentityBundle(bundlePath)
	if err != nil {
		t.Fatalf("peek: %v", err)
	}
	if !strings.Contains(peekJSON, `"name":"roundtrip"`) {
		t.Fatalf("peek result: %s", peekJSON)
	}

	// Wrong passphrase surfaces the re-promptable error.
	stagePass(t, ic2, "wrong-pass")
	if _, err := ic2.PeekIdentityBundle(bundlePath); err == nil || !strings.Contains(err.Error(), "wrong passphrase") {
		t.Fatalf("wrong passphrase must be recognizable, got %v", err)
	}

	stagePass(t, ic2, "bundle-pass-123")
	msg, err := ic2.ImportIdentity(bundlePath, false, "")
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	if !strings.Contains(msg, "roundtrip") {
		t.Fatalf("import message: %s", msg)
	}
	list, err := ic2.ListIdentities()
	if err != nil || !strings.Contains(list, "roundtrip") {
		t.Fatalf("imported identity missing: %s err=%v", list, err)
	}
}

func TestStagedProfileExportImportRoundTrip(t *testing.T) {
	ic := setupLocalEnv(t)
	if _, err := ic.CreateKeys("profowner", "", "po@example.com", "", "", false); err != nil {
		t.Fatalf("create keys: %v", err)
	}

	stagePass(t, ic, "profile-pass-456")
	b64, err := ic.ExportProfile()
	if err != nil {
		t.Fatalf("export profile: %v", err)
	}
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		t.Fatal(err)
	}
	profPath := filepath.Join(t.TempDir(), "profile.tar.icfx")
	if err := os.WriteFile(profPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	ic2 := setupLocalEnv(t)
	stagePass(t, ic2, "profile-pass-456")
	manifest, err := ic2.PeekProfileManifest(profPath)
	if err != nil {
		t.Fatalf("peek manifest: %v", err)
	}
	if !strings.Contains(manifest, "profowner") {
		t.Fatalf("manifest: %s", manifest)
	}
	stagePass(t, ic2, "profile-pass-456")
	if _, err := ic2.ImportProfile(profPath, false, false, false); err != nil {
		t.Fatalf("import profile: %v", err)
	}
	list, err := ic2.ListIdentities()
	if err != nil || !strings.Contains(list, "profowner") {
		t.Fatalf("imported profile identity missing: %s err=%v", list, err)
	}
}

func TestLockClearsStagedBundlePassphrase(t *testing.T) {
	ic := setupLocalEnv(t)
	if _, err := ic.CreateKeys("locker", "", "lk@example.com", "", "", false); err != nil {
		t.Fatal(err)
	}
	stagePass(t, ic, "some-pass")
	if err := ic.Lock(); err != nil {
		t.Fatal(err)
	}
	// Re-unlock the session, then confirm the staged secret is gone.
	cachePassphrase([]byte("session-pass-for-tests"))
	if _, err := ic.ExportIdentity("locker"); err == nil || !strings.Contains(err.Error(), "StageBundlePassphrase") {
		t.Fatalf("Lock must clear the staged passphrase, got %v", err)
	}
}
