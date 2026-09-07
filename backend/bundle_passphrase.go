package main

import (
	"fmt"
	"sync"

	"github.com/awnumar/memguard"
	"github.com/hkdb/flugo/pkg/bridge"
)

// The bundle passphrase protects portable exports/imports (identity/key/
// profile backups) — a deliberately separate secret from the session unlock
// passphrase. It reaches Go over the secure raw-bytes channel (lone
// *bridge.Secret) and parks in a memguard enclave until the very next
// export/import/peek call consumes it, single-use. This is the same
// stage-then-consume shape as CloudService.SetPassword: the flugo secure
// channel is single-secret-only, and the consuming methods also carry
// non-secret args (paths, names, flags).
var (
	bundlePassMu sync.Mutex
	bundlePass   *memguard.Enclave
)

// StageBundlePassphrase parks the export/import passphrase for the next
// bundle operation. Call it immediately before ExportIdentity /
// PeekIdentityBundle / ImportIdentity / ExportProfile / ImportProfile /
// PeekProfileManifest; each consumes it exactly once (peek→import flows
// stage twice). Never crosses the FFI as a string.
func (s *IcfxService) StageBundlePassphrase(secret *bridge.Secret) error {
	defer secret.Destroy()
	buf, err := secret.Open()
	if err != nil {
		return fmt.Errorf("opening secret: %w", err)
	}
	bundlePassMu.Lock()
	defer bundlePassMu.Unlock()
	if bundlePass != nil {
		if old, oerr := bundlePass.Open(); oerr == nil {
			old.Destroy()
		}
	}
	bundlePass = buf.Seal() // Seal destroys buf
	return nil
}

// takeBundlePassphrase consumes the staged passphrase, returning the raw
// bytes plus a destroy func the caller MUST defer — the bytes live in a
// memguard LockedBuffer and stay wipeable (no Go string is created here;
// the single unavoidable string materializes only at icfx's age boundary).
func takeBundlePassphrase() (pass []byte, done func(), err error) {
	bundlePassMu.Lock()
	defer bundlePassMu.Unlock()
	if bundlePass == nil {
		return nil, nil, fmt.Errorf("bundle passphrase not staged — call StageBundlePassphrase first")
	}
	buf, err := bundlePass.Open()
	if err != nil {
		return nil, nil, fmt.Errorf("opening staged passphrase: %w", err)
	}
	bundlePass = nil // single-use
	return buf.Bytes(), buf.Destroy, nil
}

// clearBundlePassphrase drops a staged-but-unconsumed passphrase (canceled
// flows, app lock). A locked app holds no secrets.
func clearBundlePassphrase() {
	bundlePassMu.Lock()
	defer bundlePassMu.Unlock()
	if bundlePass == nil {
		return
	}
	if buf, err := bundlePass.Open(); err == nil {
		buf.Destroy()
	}
	bundlePass = nil
}
