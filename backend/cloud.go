package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/awnumar/memguard"
	"github.com/hkdb/flugo/pkg/bridge"
	"github.com/instacryptio/icfx/cloud"
	"github.com/instacryptio/icfx/config"
	"github.com/instacryptio/icfx/contacts"
	"github.com/instacryptio/icfx/groups"
	"github.com/instacryptio/icfx/hardware/fido2"
	"github.com/instacryptio/icfx/identity"
	"github.com/instacryptio/icfx/keystore"
	"github.com/instacryptio/icfx/profile"
	"github.com/instacryptio/icfx/qr"
)

// CloudService is the Instacrypt Cloud surface exposed to Flutter via Flugo. It
// wraps icfx/cloud.Client — the shared SDK ic-cli also uses — so ic-app and
// ic-cli talk to the server identically. The client is held for the process
// lifetime so the password-derived encryption key (set during LogIn/SignUp)
// stays in memory for the initial identities push, exactly like sessionPass.
type CloudService struct{}

var (
	cloudMu      sync.Mutex
	cloudClient  *cloud.Client
	pendingEmail string // email captured during LogIn, saved after a 2FA exchange

	cloudPassMu sync.Mutex
	cloudPass   *memguard.Enclave // cloud password, set via the secure channel, consumed once by SignUp/LogIn

	securityPINMu sync.Mutex
	securityPIN   *memguard.Enclave // FIDO2 key PIN, set via the secure channel, consumed once per ceremony
)

// client returns the process-lifetime cloud client, building it on first use
// with the configured base URL, any persisted tokens, and the client-side email
// cooldown store (shared with ic-cli's behavior).
func (s *CloudService) client() (*cloud.Client, error) {
	ensurePathsApplied()
	cloudMu.Lock()
	defer cloudMu.Unlock()
	if cloudClient != nil {
		return cloudClient, nil
	}
	cfg, err := config.Load()
	if err != nil {
		return nil, fmt.Errorf("loading config: %w", err)
	}
	base := cfg.CloudBaseURL
	if base == "" {
		base = config.DefaultCloudBaseURL
	}
	c, err := cloud.New(base)
	if err != nil {
		return nil, fmt.Errorf("cloud base URL: %w", err)
	}
	c.SetDeviceLabel("Instacrypt App · " + prettyOS())
	if dir, derr := config.ConfigDir(); derr == nil {
		c.SetCooldownStore(cloud.NewFileCooldownStore(filepath.Join(dir, "cloud_cooldown.json")))
		// The library owns session + encKey persistence (keychain / Android
		// keyring / age-scrypt file). Wire the stores and note the active
		// account; tokens are loaded lazily by authedClient so a locked
		// file-backend app isn't prompted just to build the client.
		c.SetEncKeyStore(resolveEncKeyStore(cfg, dir))
		c.SetSessionStore(resolveSessionStore(cfg, dir))
		if email, ok := c.SessionStore().ActiveAccount(); ok {
			c.SetAccountEmail(email)
			pendingEmail = email
		}
	}
	cloudClient = c
	return c, nil
}

// prettyOS renders runtime.GOOS as the platform name users expect in the
// Devices list. Deliberately nothing beyond app + OS — no hostname or other
// device fingerprints leave the device.
func prettyOS() string {
	switch runtime.GOOS {
	case "android":
		return "Android"
	case "ios":
		return "iOS"
	case "darwin":
		return "macOS"
	case "windows":
		return "Windows"
	case "linux":
		return "Linux"
	default:
		return runtime.GOOS
	}
}

// authedClient returns the cloud client with a live access token, refreshing
// once when the persisted one has expired (the app equivalent of ic-cli's
// requireCloudAuth — without it, every authed call starts failing with 401
// an hour after the last login).
func (s *CloudService) authedClient(ctx context.Context) (*cloud.Client, error) {
	c, err := s.client()
	if err != nil {
		return nil, err
	}
	// Load the persisted tokens on demand (a file backend needs the cached
	// session passphrase here — acceptable, since we're about to make an
	// authenticated call).
	if c.Tokens() == nil && c.AuthEmail() != "" {
		if rerr := c.RestoreSession(c.AuthEmail()); rerr != nil && !errors.Is(rerr, cloud.ErrNoSession) {
			return nil, rerr
		}
	}
	if c.TokenValidFor(30 * time.Second) {
		return c, nil
	}
	tok := c.Tokens()
	if tok == nil || tok.RefreshToken == "" {
		return nil, fmt.Errorf("not signed in — log in from the Cloud tab")
	}
	if rerr := c.Refresh(ctx); rerr != nil {
		// Only a server-side 401 means the session is actually dead. A
		// transport failure (server down, wrong URL, no network) or a 5xx
		// must not read as a logout — the stored session is intact and works
		// again the moment the server is reachable.
		if cloud.IsUnauthorized(rerr) {
			return nil, fmt.Errorf("session expired — log in again from the Cloud tab")
		}
		return nil, fmt.Errorf("cloud server unreachable — check your network or the server URL in Settings: %w", rerr)
	}
	// Refresh rotated the tokens; the library persisted them.
	return c, nil
}

// cloudClientIfEnabled returns an authenticated cloud client when cloud is on
// and a usable session exists, or nil otherwise. It's the nil-safe seam for
// handoff/rotate re-key: a nil client skips the self-lock re-key entirely (the
// orphaned blobs recover on a later authed sync via the re-seal gate).
func cloudClientIfEnabled(ctx context.Context) *cloud.Client {
	cfg, err := config.Load()
	if err != nil || !cfg.CloudEnabled {
		return nil
	}
	c, err := (&CloudService{}).authedClient(ctx)
	if err != nil {
		return nil
	}
	return c
}

// hasSession reports the signed-in account (from the persisted active-account
// record) and whether its tokens are present in the SessionStore. It is a
// no-decrypt presence check, so the file-backend UI can render signed-in state
// without prompting for the session passphrase.
func (s *CloudService) hasSession() (string, bool) {
	c, err := s.client()
	if err != nil {
		return "", false
	}
	email := c.AuthEmail()
	store := c.SessionStore()
	if email == "" || store == nil {
		return "", false
	}
	return email, store.HasSession(email)
}

// authEmail returns the signed-in account email for an authed client. A live
// token implies an account, so "" is a belt-and-suspenders guard that should
// not normally trigger. Shared by the authed CloudService methods.
func authEmail(c *cloud.Client) (string, error) {
	email := c.AuthEmail()
	if email == "" {
		return "", fmt.Errorf("not signed in")
	}
	return email, nil
}

// --- account + session -----------------------------------------------------

// SetPassword caches the cloud password for the immediately-following SignUp or
// LogIn. It is the ONLY parameter and is a *bridge.Secret, so flugo dispatches it
// over the raw-bytes secure channel (FlugoCallSecure) rather than JSON — the
// password never crosses the FFI as a serialized string. It's held in a memguard
// enclave and consumed (and wiped) once. Mirrors how the file passphrase
// (sessionPass) is handled.
func (s *CloudService) SetPassword(pw *bridge.Secret) error {
	defer pw.Destroy()
	buf, err := pw.Open()
	if err != nil {
		return fmt.Errorf("opening secret: %w", err)
	}
	cloudPassMu.Lock()
	defer cloudPassMu.Unlock()
	if cloudPass != nil {
		if old, oerr := cloudPass.Open(); oerr == nil {
			old.Destroy()
		}
	}
	cloudPass = buf.Seal() // Seal destroys buf
	return nil
}

// takeCloudPassword returns the cached cloud password once and wipes the enclave.
func takeCloudPassword() (string, error) {
	cloudPassMu.Lock()
	defer cloudPassMu.Unlock()
	if cloudPass == nil {
		return "", fmt.Errorf("no cloud password set — call SetPassword first")
	}
	buf, err := cloudPass.Open()
	if err != nil {
		return "", fmt.Errorf("opening cloud password: %w", err)
	}
	defer buf.Destroy()
	cloudPass = nil
	return string(buf.Bytes()), nil
}

// SignUp begins account creation (consuming the password set via SetPassword)
// under the pending-signup model: the server emails a 6-digit code and NO
// account exists until ConfirmSignUp succeeds. The SDK keeps the derived
// encryption key in memory across the confirm step, so no password re-entry
// is needed.
func (s *CloudService) SignUp(email string, acceptedTerms bool) error {
	password, err := takeCloudPassword()
	if err != nil {
		return err
	}
	c, err := s.client()
	if err != nil {
		return err
	}
	if _, err := c.SignUp(context.Background(), email, password, acceptedTerms); err != nil {
		return err
	}
	pendingEmail = email
	return nil
}

// ConfirmSignUp completes signup with the emailed 6-digit code. The account is
// created born-verified and the returned session is persisted — the user lands
// signed in with the encryption key already established.
func (s *CloudService) ConfirmSignUp(code string) error {
	c, err := s.client()
	if err != nil {
		return err
	}
	if pendingEmail == "" {
		return fmt.Errorf("no signup in progress — call SignUp first")
	}
	if _, err := c.ConfirmSignUp(context.Background(), pendingEmail, code); err != nil {
		return err
	}
	// Tokens (and the active-account record) are auto-persisted through the
	// SessionStore by the SDK on every auth completion — no manual save here.
	_ = s.ensureAutoSync()
	return nil
}

// LogIn authenticates with the password set via SetPassword. Returns a
// login-challenge JSON (temp_token + factor [+ webauthn options]) when a second
// factor is required, or "" when the session is fully established.
func (s *CloudService) LogIn(email string) (string, error) {
	password, err := takeCloudPassword()
	if err != nil {
		return "", err
	}
	c, err := s.client()
	if err != nil {
		return "", err
	}
	return s.completeLogin(context.Background(), c, email, password)
}

func (s *CloudService) completeLogin(ctx context.Context, c *cloud.Client, email, password string) (string, error) {
	pendingEmail = email
	ch, err := c.LogIn(ctx, email, password)
	if ch != nil {
		// Second factor required — surface the challenge; the token exchange
		// happens in LogInTOTP / LogInEmail.
		out, merr := json.Marshal(loginChallenge{TempToken: ch.TempToken, Factor: ch.Factor, WebAuthn: ch.WebAuthnOptions})
		if merr != nil {
			return "", merr
		}
		return string(out), nil
	}
	if err != nil {
		return "", err
	}
	// Tokens + active account auto-persist through the SessionStore on login.
	_ = s.ensureAutoSync()
	return "", nil
}

// LogInTOTP completes a TOTP-gated login with the authenticator (or recovery) code.
func (s *CloudService) LogInTOTP(tempToken, code string) error {
	c, err := s.client()
	if err != nil {
		return err
	}
	if err := c.LogInTOTP(context.Background(), tempToken, code); err != nil {
		return err
	}
	// Tokens (and the active-account record) are auto-persisted through the
	// SessionStore by the SDK on every auth completion — no manual save here.
	_ = s.ensureAutoSync()
	return nil
}

// LogInEmail completes an email-gated login with the emailed one-time code.
func (s *CloudService) LogInEmail(tempToken, code string) error {
	c, err := s.client()
	if err != nil {
		return err
	}
	if err := c.LogInEmail(context.Background(), tempToken, code); err != nil {
		return err
	}
	// Tokens (and the active-account record) are auto-persisted through the
	// SessionStore by the SDK on every auth completion — no manual save here.
	_ = s.ensureAutoSync()
	return nil
}

// --- hardware security keys (FIDO2/WebAuthn) ---------------------------------

// SetSecurityKeyPIN caches the FIDO2 key's PIN for the immediately-following
// ceremony (add key / webauthn login). Lone *bridge.Secret param → flugo's
// raw-bytes secure channel; held in a memguard enclave, consumed once.
func (s *CloudService) SetSecurityKeyPIN(pin *bridge.Secret) error {
	defer pin.Destroy()
	buf, err := pin.Open()
	if err != nil {
		return fmt.Errorf("opening secret: %w", err)
	}
	securityPINMu.Lock()
	defer securityPINMu.Unlock()
	if securityPIN != nil {
		if old, oerr := securityPIN.Open(); oerr == nil {
			old.Destroy()
		}
	}
	securityPIN = buf.Seal() // Seal destroys buf
	return nil
}

// takeSecurityKeyPIN returns the cached PIN once and wipes the enclave.
func takeSecurityKeyPIN() (string, error) {
	securityPINMu.Lock()
	defer securityPINMu.Unlock()
	if securityPIN == nil {
		return "", fmt.Errorf("no security-key PIN set — call SetSecurityKeyPIN first")
	}
	buf, err := securityPIN.Open()
	if err != nil {
		return "", fmt.Errorf("opening security-key PIN: %w", err)
	}
	defer buf.Destroy()
	securityPIN = nil
	return string(buf.Bytes()), nil
}

// appAuthenticator builds the shared icfx FIDO2 authenticator with the app's
// prompts: the PIN comes from the staged enclave (the UI collects it before
// starting the ceremony and shows its own "touch your key" state).
func (s *CloudService) appAuthenticator() (cloud.Authenticator, error) {
	ensurePathsApplied()
	origin := config.DefaultCloudBaseURL
	if cfg, err := config.Load(); err == nil && cfg.CloudBaseURL != "" {
		origin = cfg.CloudBaseURL
	}
	return fido2.NewAuthenticator(origin, fido2.Prompts{PIN: takeSecurityKeyPIN})
}

// WebAuthnSupported reports whether this build can drive hardware security
// keys (desktop yes; mobile builds get the icfx stub and return false).
func (s *CloudService) WebAuthnSupported() (bool, error) {
	return fido2.Supported(), nil
}

// WebAuthnOrigin returns the WebAuthn origin the MOBILE CTAP2 plugin must stamp
// into clientDataJSON. The mobile plugin talks to the key directly and
// self-asserts the origin exactly like the desktop libfido2 authenticator, so
// this is the account's cloud base URL (which the server's WebAuthnOrigins
// allows) — the same value appAuthenticator uses.
func (s *CloudService) WebAuthnOrigin() (string, error) {
	ensurePathsApplied()
	origin := config.DefaultCloudBaseURL
	if cfg, err := config.Load(); err == nil && cfg.CloudBaseURL != "" {
		origin = cfg.CloudBaseURL
	}
	return origin, nil
}

// WebAuthnAddKey enrolls a hardware security key (PIN staged via
// SetSecurityKeyPIN; the key must be plugged in — the call blocks until touch).
func (s *CloudService) WebAuthnAddKey(label string) error {
	authn, err := s.appAuthenticator()
	if err != nil {
		return err
	}
	c, err := s.authedClient(context.Background())
	if err != nil {
		return err
	}
	return c.RegisterWebAuthn(context.Background(), label, authn)
}

// WebAuthnListKeys returns the enrolled hardware keys as JSON.
func (s *CloudService) WebAuthnListKeys() (string, error) {
	c, err := s.authedClient(context.Background())
	if err != nil {
		return "", err
	}
	keys, err := c.ListWebAuthnKeys(context.Background())
	if err != nil {
		return "", err
	}
	out, err := json.Marshal(keys)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// WebAuthnRemoveKey deletes an enrolled hardware key. Requires the cloud
// password, staged via SetPassword (secure channel).
func (s *CloudService) WebAuthnRemoveKey(keyID string) error {
	password, err := takeCloudPassword()
	if err != nil {
		return err
	}
	c, err := s.authedClient(context.Background())
	if err != nil {
		return err
	}
	email, err := authEmail(c)
	if err != nil {
		return err
	}
	return c.DeleteWebAuthnKey(context.Background(), email, password, keyID)
}

// RequestAccountDeletion schedules the cloud account for deletion after a
// 30-day grace window and signs every device out. It is NOT an immediate
// wipe: logging back in on any device before the deadline cancels it.
// Requires the cloud password, staged via SetPassword (secure channel), so a
// stolen session alone can't schedule deletion. On success the local session
// is cleared to match the server-side sign-out.
func (s *CloudService) RequestAccountDeletion() error {
	password, err := takeCloudPassword()
	if err != nil {
		return err
	}
	c, err := s.authedClient(context.Background())
	if err != nil {
		return err
	}
	email, err := authEmail(c)
	if err != nil {
		return err
	}
	if err := c.RequestAccountDeletion(context.Background(), email, password, false); err != nil {
		return err
	}
	// The server revoked every session; the SDK's RequestAccountDeletion already
	// cleared the SessionStore + EncKeyStore. Tear down the now-dead in-memory
	// client, the same way Logout does.
	cloudMu.Lock()
	cloudClient = nil
	pendingEmail = ""
	cloudMu.Unlock()
	_ = cloud.RemoveContactsShadow()
	markSyncChoicePending()
	_ = s.ensureAutoSync()
	return nil
}

// LogInWebAuthn completes a webauthn-gated login: the UI passes back the
// assertion options it received in the challenge, the staged PIN unlocks the
// ceremony, and the session is persisted on success.
func (s *CloudService) LogInWebAuthn(tempToken, optionsJSON string) error {
	authn, err := s.appAuthenticator()
	if err != nil {
		return err
	}
	c, err := s.client()
	if err != nil {
		return err
	}
	if err := c.LogInWebAuthn(context.Background(), tempToken, []byte(optionsJSON), authn); err != nil {
		return err
	}
	// Tokens (and the active-account record) are auto-persisted through the
	// SessionStore by the SDK on every auth completion — no manual save here.
	_ = s.ensureAutoSync()
	return nil
}

// LogInWebAuthnNative completes a webauthn-gated login on MOBILE: the native
// plugin already ran the OS assertion ceremony (tap + UV), so the UI passes the
// assertion response JSON directly and the session is persisted on success.
// No PIN/authenticator plumbing — the OS handled user verification.
func (s *CloudService) LogInWebAuthnNative(tempToken, responseJSON string) error {
	c, err := s.client()
	if err != nil {
		return err
	}
	if err := c.LogInWebAuthnResponse(context.Background(), tempToken, []byte(responseJSON)); err != nil {
		return err
	}
	_ = s.ensureAutoSync()
	return nil
}

// WebAuthnRegisterBeginNative starts MOBILE hardware-key enrollment: returns the
// creation options + server handle as JSON {"options":...,"handle":"..."} for the
// native plugin to run the OS attestation ceremony over. Complete with
// WebAuthnRegisterFinishNative.
func (s *CloudService) WebAuthnRegisterBeginNative(label string) (string, error) {
	c, err := s.authedClient(context.Background())
	if err != nil {
		return "", err
	}
	options, handle, err := c.RegisterWebAuthnBegin(context.Background(), label)
	if err != nil {
		return "", err
	}
	out, err := json.Marshal(struct {
		Options json.RawMessage `json:"options"`
		Handle  string          `json:"handle"`
	}{Options: json.RawMessage(options), Handle: handle})
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// WebAuthnRegisterFinishNative submits the native attestation response to
// complete enrollment for the handle returned by WebAuthnRegisterBeginNative.
func (s *CloudService) WebAuthnRegisterFinishNative(handle, responseJSON string) error {
	c, err := s.authedClient(context.Background())
	if err != nil {
		return err
	}
	return c.RegisterWebAuthnFinish(context.Background(), handle, []byte(responseJSON))
}

// --- two-factor management ---------------------------------------------------

// TotpSetup begins authenticator-app enrollment: returns the otpauth URL plus
// a PNG QR of it (base64) for native display. Not active until TotpConfirm.
func (s *CloudService) TotpSetup() (string, error) {
	c, err := s.authedClient(context.Background())
	if err != nil {
		return "", err
	}
	setup, err := c.SetupTOTP(context.Background())
	if err != nil {
		return "", err
	}
	png, err := qr.GenerateQRPNG(setup.OTPAuthURL, 512)
	if err != nil {
		return "", fmt.Errorf("rendering enrollment QR: %w", err)
	}
	out, err := json.Marshal(map[string]string{
		"otpauth_url": setup.OTPAuthURL,
		"qr_png_b64":  base64.StdEncoding.EncodeToString(png),
	})
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// TotpConfirm activates the authenticator with a live code and returns the
// one-time recovery codes as JSON. Show them ONCE and tell the user to save
// them — they are not retrievable later.
func (s *CloudService) TotpConfirm(code string) (string, error) {
	c, err := s.authedClient(context.Background())
	if err != nil {
		return "", err
	}
	conf, err := c.ConfirmTOTP(context.Background(), code)
	if err != nil {
		return "", err
	}
	out, err := json.Marshal(conf.RecoveryCodes)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// TotpDisable turns the authenticator factor off. Requires the cloud password
// (staged via SetPassword — secure channel) plus a live TOTP or recovery code.
func (s *CloudService) TotpDisable(code string) error {
	password, err := takeCloudPassword()
	if err != nil {
		return err
	}
	c, err := s.authedClient(context.Background())
	if err != nil {
		return err
	}
	email, err := authEmail(c)
	if err != nil {
		return err
	}
	return c.DisableTOTP(context.Background(), email, password, code)
}

// SetEmailTwoFactor turns the email-code second factor on or off. Enabling needs
// no further proof (the address was proven at signup). DISABLING requires the
// cloud password: stage it first via SetPassword (the secure *bridge.Secret
// channel) — this consumes it — so a stolen session can't downgrade 2FA.
func (s *CloudService) SetEmailTwoFactor(enable bool) error {
	c, err := s.authedClient(context.Background())
	if err != nil {
		return err
	}
	if !enable {
		password, perr := takeCloudPassword()
		if perr != nil {
			return perr
		}
		return c.SetEmailTwoFactor(context.Background(), false, c.AuthEmail(), password)
	}
	return c.SetEmailTwoFactor(context.Background(), true, "", "")
}

// ResendSignupCode re-sends the 6-digit signup code for the in-progress
// signup. The client-side cooldown may short-circuit it (returns a
// *cloud.CooldownError the UI renders).
func (s *CloudService) ResendSignupCode() error {
	c, err := s.client()
	if err != nil {
		return err
	}
	if pendingEmail == "" {
		return fmt.Errorf("no signup in progress — call SignUp first")
	}
	return c.ResendSignupCode(context.Background(), pendingEmail)
}

// Logout clears the local session (tokens + in-memory key).
func (s *CloudService) Logout() error {
	// Best-effort server-side logout — it also clears the persisted encKey
	// through the SDK's EncKeyStore hook.
	if c, err := s.client(); err == nil {
		_ = c.LogOut(context.Background())
	}
	cloudMu.Lock()
	cloudClient = nil
	pendingEmail = ""
	cloudMu.Unlock()
	// c.LogOut already cleared the SessionStore (tokens + active account) and the
	// EncKeyStore through the SDK.
	// The shadow means "what the current server already has" — stale across a
	// session boundary (next login may be another account or server), where it
	// would silently suppress uploading everything it lists.
	_ = cloud.RemoveContactsShadow()
	markSyncChoicePending()
	_ = s.ensureAutoSync() // stops the engine (signed out)
	return nil
}

// markSyncChoicePending records that the next login must re-confirm the sync-tier
// choice before anything auto-syncs. Best-effort; tier VALUES are left intact so
// the choice screen pre-fills from them.
func markSyncChoicePending() {
	if cfg, err := config.Load(); err == nil {
		cfg.CloudSyncChoicePending = true
		_ = cfg.Save()
	}
}

// SetServerURL points the app at a different ic-cloud server (empty = the
// default, config.DefaultCloudBaseURL). Sessions, tokens, sync positions, and
// the contacts shadow are all per-server, so an actual change signs this
// device out locally and resets the sync state; local data stays and syncs
// fresh against the new server after the next login.
func (s *CloudService) SetServerURL(rawURL string) error {
	ensurePathsApplied()
	trimmed := strings.TrimSpace(rawURL)
	if trimmed != "" {
		u, err := url.Parse(trimmed)
		if err != nil || u.Host == "" {
			return fmt.Errorf("invalid server URL — use http(s)://host[:port]")
		}
		// Enforces scheme + plaintext-http-only-to-loopback (shared with icfx/ic-cli).
		if err := config.ValidateCloudBaseURL(trimmed); err != nil {
			return err
		}
		trimmed = strings.TrimRight(trimmed, "/")
	}
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	current := cfg.CloudBaseURL
	if current == "" {
		current = config.DefaultCloudBaseURL
	}
	next := trimmed
	if next == "" {
		next = config.DefaultCloudBaseURL
	}
	if current == next {
		// Same server (incl. explicit-vs-default spelling) — record the
		// normalized value, keep the session.
		cfg.CloudBaseURL = trimmed
		return cfg.Save()
	}

	// Best-effort sign-out against the OLD server (also clears the persisted
	// encKey via the SDK's EncKeyStore hook).
	if c, cerr := s.client(); cerr == nil {
		_ = c.LogOut(context.Background())
	}
	cloudMu.Lock()
	cloudClient = nil
	pendingEmail = ""
	cloudMu.Unlock()
	// The old-server LogOut above cleared that server's SessionStore entry; the
	// positions file is per-account and simply goes stale (a fresh login against
	// the new server rebuilds it).
	_ = cloud.RemoveContactsShadow()

	cfg.CloudBaseURL = trimmed
	cfg.CloudSyncChoicePending = true // switched servers = a fresh login; re-confirm what to sync
	if err := cfg.Save(); err != nil {
		return fmt.Errorf("saving config: %w", err)
	}
	return s.ensureAutoSync() // stops (signed out) / restarts against the new URL
}

// Status returns connection + sync state as JSON for the UI.
func (s *CloudService) Status() (string, error) {
	ensurePathsApplied()
	cfg, err := config.Load()
	if err != nil {
		return "", fmt.Errorf("loading config: %w", err)
	}
	c, err := s.client()
	if err != nil {
		return "", err
	}
	out, err := json.Marshal(cloudStatus{
		Connected:      c.IsAuthenticated(),
		Email:          pendingEmail,
		CloudEnabled:   cfg.CloudEnabled,
		SyncContacts:   cfg.CloudSyncContacts,
		SyncSettings:   cfg.CloudSyncSettings,
		SyncIdentities: cfg.CloudSyncIdentities,
	})
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// cloudUIState is the single gating object every cloud UI surface reads:
// master switch, session, and sync flags — plus best-effort account details.
type cloudUIState struct {
	Enabled  bool   `json:"enabled"`
	SignedIn bool   `json:"signed_in"`
	Email    string `json:"email"`
	Tier     string `json:"tier"`
	// Vip is admin-granted (Ultimate limits; Tier stays the real billing tier).
	// The UI shows it as "free (VIP)".
	Vip            bool   `json:"vip"`
	TwoFactor      string `json:"two_factor"` // "", "none", "email", "totp", "webauthn"
	SyncContacts   bool   `json:"sync_contacts"`
	SyncSettings   bool   `json:"sync_settings"`
	SyncIdentities bool   `json:"sync_identities"`
	// SyncChoicePending: a sign-out happened; the UI must re-present the sync-tier
	// choice (pre-filled from the flags above) before syncing resumes.
	SyncChoicePending bool `json:"sync_choice_pending"`

	AutoSyncMinutes int    `json:"auto_sync_minutes"`
	LastSyncAt      string `json:"last_sync_at,omitempty"` // RFC3339; empty = never
	LastSyncSummary string `json:"last_sync_summary,omitempty"`
	LastSyncError   string `json:"last_sync_error,omitempty"`
}

// CloudUIState reports the app-wide cloud gating state. signed_in comes from
// the persisted session (works offline); tier/two_factor are fetched
// best-effort and left empty when the server is unreachable.
func (s *CloudService) CloudUIState() (string, error) {
	ensurePathsApplied()
	cfg, err := config.Load()
	if err != nil {
		return "", fmt.Errorf("loading config: %w", err)
	}
	st := cloudUIState{
		Enabled:           cfg.CloudEnabled,
		SyncContacts:      cfg.CloudSyncContacts,
		SyncSettings:      cfg.CloudSyncSettings,
		SyncIdentities:    cfg.CloudSyncIdentities,
		SyncChoicePending: cfg.CloudSyncChoicePending,
		AutoSyncMinutes:   cfg.CloudAutoSyncMinutes,
	}
	lastSyncMu.Lock()
	if !lastSync.At.IsZero() {
		st.LastSyncAt = lastSync.At.Format(time.RFC3339)
	}
	st.LastSyncSummary = lastSync.Summary
	st.LastSyncError = lastSync.Err
	lastSyncMu.Unlock()
	if email, ok := s.hasSession(); ok {
		st.SignedIn = true
		st.Email = email
	}
	if st.Enabled && st.SignedIn {
		if c, cerr := s.authedClient(context.Background()); cerr == nil {
			if info, ierr := c.AccountInfo(context.Background()); ierr == nil {
				st.Tier = info.Tier
				st.Vip = info.Vip
				st.TwoFactor = info.ActiveFactor
			}
		}
	}
	out, err := json.Marshal(st)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// SetCloudEnabled flips the app-wide master switch (the same cloud_enabled
// flag `icc cloud on|off` uses). Off hides all cloud UI but deletes nothing —
// session, tokens, and sync flags survive an off/on round-trip.
func (s *CloudService) SetCloudEnabled(on bool) error {
	ensurePathsApplied()
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	cfg.CloudEnabled = on
	if err := cfg.Save(); err != nil {
		return fmt.Errorf("saving config: %w", err)
	}
	return s.ensureAutoSync()
}

// --- sync setup ------------------------------------------------------------

// SetSyncTiers records which resources sync to the cloud (contacts always sync
// once cloud is on; settings and identities are opt-in). Enables cloud sync.
func (s *CloudService) SetSyncTiers(contacts, settings, identities bool) error {
	ensurePathsApplied()
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	cfg.CloudEnabled = true
	cfg.CloudSyncContacts = contacts
	cfg.CloudSyncSettings = settings
	cfg.CloudSyncIdentities = identities
	cfg.CloudSyncChoicePending = false // the user just made the choice
	if err := cfg.Save(); err != nil {
		return fmt.Errorf("saving config: %w", err)
	}
	return s.ensureAutoSync()
}

// syncOutcomeJSON is one entry of Sync's result: an engine outcome or a
// per-resource error, never both.
type syncOutcomeJSON struct {
	Resource      string `json:"resource"`
	Action        string `json:"action,omitempty"` // pushed-new | pushed | pulled | up-to-date | needs-code
	CloudWasNewer bool   `json:"cloud_was_newer,omitempty"`
	Error         string `json:"error,omitempty"`
}

// Sync runs the shared bidirectional engine (icfx/cloud) over the enabled
// resources and returns per-resource outcomes as JSON. Identities roam under
// the account encKey: if the client doesn't hold one this session, the cloud
// password staged via SetPassword is consumed for a re-login; a resulting 2FA
// challenge is surfaced as action "needs-code" (the UI completes it with
// LogInTOTP/LogInEmail — which retains the encKey — then calls Sync again).
// Contacts/settings are self-lock under the default identity (cached session
// passphrase) and need no cloud password.

// errHWRequiredPrefix is the canonical marker the Dart UI matches
// (frontend hw_flow.dart `hwRequiredIdentityFrom`) to trigger the hardware-key
// tap pre-flight + retry. Every backend emitter AND the Dart matcher must use
// this EXACT text — keep them in sync.
const errHWRequiredPrefix = "hardware key required for identity "

// unlockErrText converts identity-unlock failures into user-facing sync
// outcome text. The "hardware key required for identity <name>" marker is
// machine-checked by the Dart side, which runs the tap pre-flight and
// retries; the raw InjectHWResponse text never reaches the UI.
func unlockErrText(name string, err error) string {
	var hw *hwRequiredError
	if errors.As(err, &hw) {
		return errHWRequiredPrefix + hw.identity
	}
	if strings.Contains(err.Error(), "passphrase required") {
		return "app is locked — unlock and sync again"
	}
	return fmt.Sprintf("could not unlock identity %s: %v", name, err)
}

// Sync is the MANUAL bridge entrypoint: interactive semantics (may return a
// needs-code outcome or a password-required error for the UI to resolve).
// Serialized against background runs via syncRunMu.
func (s *CloudService) Sync() (string, error) {
	syncRunMu.Lock()
	defer syncRunMu.Unlock()
	out, err := s.syncLocked(context.Background(), cloud.SyncOptions{})
	if err != nil {
		return "", err
	}
	recordLastSync(summarizeOutcomes(out), "")
	raw, err := json.Marshal(out)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

// syncApproval is the Dart-facing approval payload for SyncWithApproval: the
// user's decision on a pending a prior Sync surfaced.
type syncApproval struct {
	DefaultChange *struct {
		Kind     string `json:"kind"`
		Incoming string `json:"incoming"`
	} `json:"default_change,omitempty"`
	Reseal []string `json:"reseal,omitempty"`
}

// SyncWithApproval re-runs a sync carrying the user's approval for a pending the
// previous run surfaced — a default-identity change (needs-default-change) and/or
// a re-seal of orphaned cloud resources (needs-reseal). jsonApproval is
// {"default_change":{"kind":...,"incoming":...},"reseal":["contacts",...]}.
// Serialized against background runs via syncRunMu.
func (s *CloudService) SyncWithApproval(jsonApproval string) (string, error) {
	var appr syncApproval
	if err := json.Unmarshal([]byte(jsonApproval), &appr); err != nil {
		return "", fmt.Errorf("parsing sync approval: %w", err)
	}
	opts := cloud.SyncOptions{}
	if appr.DefaultChange != nil {
		opts.ApproveDefaultChange = &cloud.DefaultChangeApproval{Kind: appr.DefaultChange.Kind, Incoming: appr.DefaultChange.Incoming}
	}
	if len(appr.Reseal) > 0 {
		opts.ApproveReseal = map[string]bool{}
		for _, r := range appr.Reseal {
			opts.ApproveReseal[r] = true
		}
	}

	syncRunMu.Lock()
	defer syncRunMu.Unlock()
	out, err := s.syncLocked(context.Background(), opts)
	if err != nil {
		return "", err
	}
	recordLastSync(summarizeOutcomes(out), "")
	raw, err := json.Marshal(out)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

// syncLocked runs one sync pass with the given engine options (Background for
// quiet auto-sync semantics; ApproveDefaultChange/ApproveReseal to carry the
// user's approval of a prior run's pending). Callers hold syncRunMu.
func (s *CloudService) syncLocked(ctx context.Context, opts cloud.SyncOptions) ([]syncOutcomeJSON, error) {
	ensurePathsApplied()
	cfg, err := config.Load()
	if err != nil {
		return nil, fmt.Errorf("loading config: %w", err)
	}
	if !cfg.CloudEnabled {
		return nil, fmt.Errorf("cloud is off")
	}
	// A sign-out set this; the next login must re-confirm the sync-tier choice
	// (SetSyncTiers clears it) before anything auto-syncs. Quiet no-op until then
	// so a re-login never resumes stale tiers before the user chooses.
	if cfg.CloudSyncChoicePending {
		return nil, nil
	}
	c, err := s.authedClient(ctx)
	if err != nil {
		return nil, err
	}

	// The sync SEQUENCE lives in icfx/cloud (Client.RunSync); this backend only
	// supplies the platform/UI seam (appSyncHost) and renders the result.
	host := &appSyncHost{s: s, c: c, cfg: cfg, opened: map[string]*identity.Unlocked{}}
	defer host.close()

	res, rerr := c.RunSync(ctx, host, opts)
	if rerr != nil {
		var pending *cloud.ChallengePending
		if errors.As(rerr, &pending) {
			// 2FA is required to re-derive the account encKey. The UI completes
			// the exchange (LogInTOTP/LogInEmail — which retains the key) and
			// calls Sync again; already-persisted tokens make the retry idempotent.
			pendingEmail = c.AuthEmail()
			raw, merr := json.Marshal(loginChallenge{TempToken: pending.TempToken, Factor: pending.Factor, WebAuthn: pending.WebAuthn})
			if merr != nil {
				return nil, merr
			}
			return []syncOutcomeJSON{{Resource: "identities", Action: "needs-code", Error: string(raw)}}, nil
		}
		// A default-identity change (pointer moved / default's keys rotated) or an
		// orphaned-resource re-seal is never applied silently — surface it as a
		// pending the UI approves out-of-band, then re-runs via SyncWithApproval.
		var dcp *cloud.DefaultChangePending
		if errors.As(rerr, &dcp) {
			raw, merr := json.Marshal(dcp)
			if merr != nil {
				return nil, merr
			}
			return []syncOutcomeJSON{{Resource: "identities", Action: "needs-default-change", Error: string(raw)}}, nil
		}
		var rp *cloud.ResealPending
		if errors.As(rerr, &rp) {
			raw, merr := json.Marshal(rp)
			if merr != nil {
				return nil, merr
			}
			return []syncOutcomeJSON{{Resource: "self-lock", Action: "needs-reseal", Error: string(raw)}}, nil
		}
		return nil, rerr
	}

	// The pending-inbox drain drives the notification drawer (accepted requests,
	// rotated/revoked keys); friend requests surface via CloudNotices.
	queueNotices(res.Pending)

	out := make([]syncOutcomeJSON, 0, len(res.Outcomes)+1)
	for _, o := range res.Outcomes {
		out = append(out, outcomeFromResult(o))
	}
	if applied := len(res.Pending.Accepted) + len(res.Pending.Rotated) + len(res.Pending.Revoked); applied > 0 {
		out = append(out, syncOutcomeJSON{Resource: "pending", Action: fmt.Sprintf("%d update(s) applied", applied)})
	}
	return out, nil
}

// outcomeFromResult maps a library SyncOutcome to the bridge JSON shape. A
// skipped outcome carries its reason in Error — which for a self-lock unlock
// failure holds the "hardware key required for identity <name>" marker the Dart
// layer runs the tap pre-flight on and retries.
func outcomeFromResult(o cloud.SyncOutcome) syncOutcomeJSON {
	if o.Action == cloud.SyncSkipped {
		return syncOutcomeJSON{Resource: o.Resource, Action: "skipped", Error: o.Skipped}
	}
	return syncOutcomeJSON{Resource: o.Resource, Action: o.Action, CloudWasNewer: o.CloudWasNewer}
}

// appSyncHost is ic-app's thin SyncHost: the secure-channel cloud password,
// async 2FA (as *cloud.ChallengePending), hardware-key markers, and identity
// unlocking. The sync sequence itself lives in icfx/cloud.RunSync. It holds the
// identities it opens and closes them once the run finishes.
type appSyncHost struct {
	s      *CloudService
	c      *cloud.Client
	cfg    *config.Config
	opened map[string]*identity.Unlocked
}

func (h *appSyncHost) close() { closeOpened(h.opened) }

func (h *appSyncHost) Resources() cloud.ResourceSelection {
	return cloud.ResourceSelection{
		Contacts:      h.cfg.CloudSyncContacts,
		Settings:      h.cfg.CloudSyncSettings,
		Identities:    h.cfg.CloudSyncIdentities,
		Notifications: true,                    // the drawer always syncs cross-device when cloud is on
		Groups:        h.cfg.CloudSyncContacts, // groups are contact data — sync with contacts
	}
}

func (h *appSyncHost) RoamingExport() profile.IdentityExportFn {
	keysDir, _ := config.KeysDir()
	return profile.RoamingExportFn(keysDir, androidKeyringStore())
}

func (h *appSyncHost) RoamingImport() profile.IdentityImportFn {
	keysDir, _ := config.KeysDir()
	return h.s.roamingImportFn(keysDir)
}

func (h *appSyncHost) OnOldFormat()                                {} // silent replace, as before
func (h *appSyncHost) ResourceIO() cloud.ResourceIO                { return cloud.ConfigResourceIO(h.cfg) }
func (h *appSyncHost) ContactStore() (*contacts.Store, error)      { return newContactStore() }
func (h *appSyncHost) GroupStore() (*groups.Store, error)          { return newGroupStore() }
func (h *appSyncHost) NotificationStore() *cloud.NotificationStore { return notifStore() }

// EstablishEncKey re-derives the account encKey with the staged cloud password
// (the login re-persists the key through the EncKeyStore). It returns a typed
// *cloud.ChallengePending when the server wants a second factor — the UI
// resolves it out-of-band and re-syncs.
func (h *appSyncHost) EstablishEncKey(ctx context.Context) error {
	email := h.c.AuthEmail()
	password, perr := takeCloudPassword()
	if perr != nil {
		return fmt.Errorf("cloud password required — set it and retry")
	}
	challenge, lerr := h.c.LogIn(ctx, email, password)
	if challenge != nil {
		return &cloud.ChallengePending{Factor: challenge.Factor, TempToken: challenge.TempToken, WebAuthn: challenge.WebAuthnOptions}
	}
	return lerr
}

// OpenDefaultIdentity unlocks the default identity for the self-lock resources,
// caching the handle so close() can release it after the run.
func (h *appSyncHost) OpenDefaultIdentity(_ context.Context) (cloud.SelfCrypter, error) {
	name, derr := h.s.defaultIdentityName()
	if derr != nil {
		return nil, cloud.ErrNoDefaultIdentity
	}
	if u, ok := h.opened[name]; ok {
		return u, nil
	}
	u, uerr := openIdentity(name)
	if uerr != nil {
		// Preserve the "hardware key required for identity <name>" marker so the
		// Dart layer can prompt the tap and retry.
		return nil, errors.New(unlockErrText(name, uerr))
	}
	h.opened[name] = u
	return u, nil
}

// OpenByFingerprint resolves + caches the local identity for a pending item.
func (h *appSyncHost) OpenByFingerprint(_ context.Context, fp string) (cloud.SelfCrypter, error) {
	return h.s.unlockedByFingerprint(fp, h.opened)
}

// AdoptDefaultIdentity persists name as this device's default (converging on a
// hand-off/rotation successor after the user approved the change) and drops any
// cached open so the next OpenDefaultIdentity opens the new default THIS run.
func (h *appSyncHost) AdoptDefaultIdentity(_ context.Context, name string) error {
	h.cfg.DefaultIdentity = name
	if err := h.cfg.Save(); err != nil {
		return err
	}
	if u, ok := h.opened[name]; ok {
		u.Close()
		delete(h.opened, name)
	}
	return nil
}

// OpenIdentity unlocks (and caches) an identity for handoff re-key — the seam
// handoff.Host needs. HW identities surface the "hardware key required" marker
// via unlockErrText so the Dart layer can run the tap and retry.
func (h *appSyncHost) OpenIdentity(name string) (cloud.SelfCrypter, error) {
	if u, ok := h.opened[name]; ok {
		return u, nil
	}
	u, err := openIdentity(name)
	if err != nil {
		return nil, errors.New(unlockErrText(name, err))
	}
	h.opened[name] = u
	return u, nil
}

// ClearKeys wipes an identity's key material from its backend (HW-aware via the
// index entry) — the delete primitive handoff.HandoffAndDelete calls.
// ClearKeys wipes an identity's key material from its backend (HW-aware via the
// passed index entry) — the delete primitive handoff.HandoffAndDelete calls. It
// takes the already-resolved entry and does NOT re-read the index: handoff
// removes the entry before calling this, so a lookup by name would miss it.
func (h *appSyncHost) ClearKeys(idx identity.IdentityIndex) error {
	ks, err := keystoreForIdentity(idx)
	if err != nil {
		return err
	}
	return ks.Clear(idx.Name)
}

// newHandoffHost builds an appSyncHost usable as a handoff.Host (OpenIdentity/
// ClearKeys/GroupStore/NotificationStore/ResourceIO). The CloudService/client
// seams (EstablishEncKey/OpenByFingerprint) aren't exercised by handoff, so s
// may be nil.
func newHandoffHost(cfg *config.Config) *appSyncHost {
	return &appSyncHost{cfg: cfg, opened: map[string]*identity.Unlocked{}}
}

func (s *CloudService) defaultIdentityName() (string, error) {
	store, err := newIdentityStore()
	if err != nil {
		return "", err
	}
	entries, err := store.LoadIndex()
	if err != nil {
		return "", fmt.Errorf("loading identity index: %w", err)
	}
	name := resolveDefaultIdentityName(entries)
	if name == "" {
		return "", fmt.Errorf("no identity to sync — create one first")
	}
	return name, nil
}

// --- helpers ---------------------------------------------------------------

type loginChallenge struct {
	TempToken string          `json:"temp_token"`
	Factor    string          `json:"factor"`
	WebAuthn  json.RawMessage `json:"webauthn,omitempty"`
}

type cloudStatus struct {
	Connected      bool   `json:"connected"`
	Email          string `json:"email"`
	CloudEnabled   bool   `json:"cloud_enabled"`
	SyncContacts   bool   `json:"sync_contacts"`
	SyncSettings   bool   `json:"sync_settings"`
	SyncIdentities bool   `json:"sync_identities"`
}

// resolveEncKeyStore picks the encKey persistence backend with the same
// policy as identity keys: OS keychain when configured + available, else an
// age-scrypt file protected by the cached session passphrase (an empty
// session means the app is locked — the sync path surfaces that clearly).
func resolveEncKeyStore(cfg *config.Config, configDir string) cloud.EncKeyStore {
	if cfg.Keystore != "file" {
		if keystore.KeychainAvailable() {
			return cloud.NewKeychainEncKeyStore()
		}
		// Android: the platform Keystore via the flugo keyring — same
		// hardware-backed store the identity keys use.
		if s := keyringEncKeyStoreIfAvailable(); s != nil {
			return s
		}
	}
	return cloud.NewFileEncKeyStore(configDir, appKeystorePassphrase)
}

// resolveSessionStore picks the session (tokens + positions) backend under the
// SAME policy as the encKey / identity keys: OS keychain, else the Android
// Keystore keyring, else an age-scrypt file protected by the cached session
// passphrase. The library owns the split; the client only injects the platform
// backend + passphrase source.
func resolveSessionStore(cfg *config.Config, configDir string) cloud.SessionStore {
	useKeychain := cfg.Keystore != "file" && keystore.KeychainAvailable()
	return cloud.DefaultSessionStore(configDir, useKeychain, appKeystorePassphrase, keyringTokenBackendIfAvailable())
}

// appKeystorePassphrase supplies the keystore passphrase for file-backed cloud
// stores: the cached session passphrase, or a clear "locked" error (an empty
// session means the app is locked — the caller surfaces it).
func appKeystorePassphrase() ([]byte, error) {
	pp := sessionPassphraseBytes()
	if len(pp) == 0 {
		return nil, fmt.Errorf("app session is locked — unlock Instacrypt first")
	}
	return pp, nil
}

// roamingImportFn stores identities pulled by the sync engine. Passphrase
// prompts can't cross the bridge synchronously, so both prompt hooks resolve
// to the cached session passphrase: a raw (keychain-origin) key landing on a
// file device is protected with it, and a passphrase key moving into this
// device's keychain is opened with it. An identity whose origin passphrase
// differs errors out of the sync with a clear message (import it via the
// profile import flow instead) — the other identities still converge.
func (s *CloudService) roamingImportFn(keysDir string) profile.IdentityImportFn {
	sessionPass := func(name string) ([]byte, error) {
		pp := sessionPassphraseBytes()
		if len(pp) == 0 {
			return nil, fmt.Errorf("identity %q needs a passphrase — unlock the app session first", name)
		}
		return pp, nil
	}
	// Same availability rule as the identity paths: desktop OS keychain OR
	// the Android Keystore via the flugo keyring. Anything less forces
	// roamed identities into passphrase files (and prompts) needlessly.
	dest := identity.BackendKeychain
	cfg, err := config.Load()
	if err != nil || cfg.Keystore == "file" || !keychainBackendAvailable() {
		dest = identity.BackendFile
	}
	return profile.RoamingImportFn(profile.RoamingImportOptions{
		KeysDir:        keysDir,
		DestBackend:    dest,
		PromptExisting: sessionPass,
		PromptNew:      sessionPass,
		Keychain:       androidKeyringStore(),
	})
}
