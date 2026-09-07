//go:build integration

// Integration tests for SetServerURL + the session-boundary shadow clear.
// Run against the isolated dev-mode server:
//
//	CLOUD_TEST_URL=http://localhost:8093 go test -tags integration ./...
package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/instacryptio/icfx/config"
)

// setupCloudEnv isolates HOME, points the app at the test server, and signs
// up a fresh account. Returns the signed-in service.
func setupCloudEnv(t *testing.T) *CloudService {
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

	s := &CloudService{}
	ctx := context.Background()
	c, err := s.client()
	if err != nil {
		t.Fatal(err)
	}
	email := "switch-" + time.Now().Format("150405.000000") + "@example.com"
	pending, err := c.SignUp(ctx, email, "correcthorsebatterystaple", true)
	if err != nil {
		t.Fatalf("signup: %v", err)
	}
	if _, err := c.ConfirmSignUp(ctx, email, pending.DevCode); err != nil {
		t.Fatalf("confirm: %v", err)
	}
	// ConfirmSignUp auto-persisted the session through the SessionStore; the
	// signed-in state is checked with s.hasSession() rather than a raw path.
	return s
}

// shadowPath fabricates the contacts shadow file (what a prior sync would
// leave behind) and returns its path.
func shadowPath(t *testing.T) string {
	t.Helper()
	contactsPath, err := config.ContactsFilePath()
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(filepath.Dir(contactsPath), "contacts_shadow.json")
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(`[]`), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestSetServerURLSwitchSemantics(t *testing.T) {
	s := setupCloudEnv(t)
	shadow := shadowPath(t)

	// Invalid URLs are rejected up front.
	for _, bad := range []string{"not a url", "ftp://x.com", "http://"} {
		if err := s.SetServerURL(bad); err == nil {
			t.Fatalf("want rejection for %q", bad)
		}
	}

	// Re-saving the SAME server is a no-op: session survives.
	if err := s.SetServerURL(testBaseURL()); err != nil {
		t.Fatalf("same-url save: %v", err)
	}
	if _, ok := s.hasSession(); !ok {
		t.Fatal("same-url save must keep the session")
	}
	if _, err := os.Stat(shadow); err != nil {
		t.Fatalf("same-url save must keep the shadow: %v", err)
	}

	// An actual switch signs out locally: session + shadow gone, config set.
	if err := s.SetServerURL("https://other.example.com"); err != nil {
		t.Fatalf("switch: %v", err)
	}
	if _, ok := s.hasSession(); ok {
		t.Fatal("switch must clear the session")
	}
	if _, err := os.Stat(shadow); !os.IsNotExist(err) {
		t.Fatalf("switch must clear the contacts shadow, stat err=%v", err)
	}
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.CloudBaseURL != "https://other.example.com" {
		t.Fatalf("config not updated: %q", cfg.CloudBaseURL)
	}

	// Reset to default (empty) — another switch, and the config records "".
	if err := s.SetServerURL(""); err != nil {
		t.Fatalf("reset: %v", err)
	}
	cfg, err = config.Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.CloudBaseURL != "" {
		t.Fatalf("reset must store empty (default), got %q", cfg.CloudBaseURL)
	}

	// Trailing slashes normalize away.
	if err := s.SetServerURL("https://third.example.com/"); err != nil {
		t.Fatalf("trailing slash: %v", err)
	}
	cfg, _ = config.Load()
	if cfg.CloudBaseURL != "https://third.example.com" {
		t.Fatalf("trailing slash not normalized: %q", cfg.CloudBaseURL)
	}
}

func TestLogoutClearsContactsShadow(t *testing.T) {
	s := setupCloudEnv(t)
	shadow := shadowPath(t)

	if err := s.Logout(); err != nil {
		t.Fatalf("logout: %v", err)
	}
	if _, ok := s.hasSession(); ok {
		t.Fatal("logout must clear the session")
	}
	if _, err := os.Stat(shadow); !os.IsNotExist(err) {
		t.Fatalf("logout must clear the contacts shadow, stat err=%v", err)
	}
}

func TestPlanInfoFreeTier(t *testing.T) {
	s := setupCloudEnv(t)

	raw, err := s.PlanInfo()
	if err != nil {
		t.Fatalf("plan info: %v", err)
	}
	if !strings.Contains(raw, `"tier":"free"`) || !strings.Contains(raw, `"max_contacts":2`) {
		t.Fatalf("unexpected free-tier plan info: %s", raw)
	}
	if strings.Contains(raw, `"sub_status"`) {
		t.Fatalf("free tier must have no subscription fields: %s", raw)
	}

	// Tier validation happens before any network call.
	if _, err := s.UpgradePlan("mega"); err == nil {
		t.Fatal("want rejection for unknown tier")
	}
}
