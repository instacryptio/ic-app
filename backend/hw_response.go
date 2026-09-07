package main

import (
	"fmt"
	"sync"

	"github.com/awnumar/memguard"
	"github.com/hkdb/flugo/pkg/bridge"
)

// The mobile HMAC hardware-key response is the identity keystore's KEK factor
// — for keychain-backed (HWKEKNone) identities it is the ENTIRE KEK secret.
// It reaches Go over the secure raw-bytes channel (lone *bridge.Secret) and
// parks in a memguard enclave until the next InjectHWResponse consumes it into
// the per-identity cache. Same stage-then-consume shape as
// StageBundlePassphrase / SetPassword: the flugo secure channel is
// single-secret-only, and InjectHWResponse also carries non-secret args
// (identity name, device serial/family). Never crosses the FFI as a string.
var (
	stagedHWMu  sync.Mutex
	stagedHWKey *memguard.Enclave
)

// StageHWResponse parks the tapped 20-byte HMAC-SHA1 response for the very next
// InjectHWResponse call. Call it immediately before InjectHWResponse.
func (s *IcfxService) StageHWResponse(secret *bridge.Secret) error {
	defer secret.Destroy()
	buf, err := secret.Open()
	if err != nil {
		return fmt.Errorf("opening secret: %w", err)
	}
	stagedHWMu.Lock()
	defer stagedHWMu.Unlock()
	if stagedHWKey != nil {
		if old, oerr := stagedHWKey.Open(); oerr == nil {
			old.Destroy()
		}
	}
	stagedHWKey = buf.Seal() // Seal destroys buf
	return nil
}

// takeStagedHWResponse consumes the staged response, returning the raw bytes
// plus a destroy func the caller MUST defer — the bytes live in a memguard
// LockedBuffer and stay wipeable.
func takeStagedHWResponse() (resp []byte, done func(), err error) {
	stagedHWMu.Lock()
	defer stagedHWMu.Unlock()
	if stagedHWKey == nil {
		return nil, nil, fmt.Errorf("hardware-key response not staged — call StageHWResponse first")
	}
	buf, err := stagedHWKey.Open()
	if err != nil {
		return nil, nil, fmt.Errorf("opening staged hw response: %w", err)
	}
	stagedHWKey = nil // single-use
	return buf.Bytes(), buf.Destroy, nil
}

// clearStagedHWResponse drops a staged-but-unconsumed response (canceled
// flows, app lock). A locked app holds no secrets.
func clearStagedHWResponse() {
	stagedHWMu.Lock()
	defer stagedHWMu.Unlock()
	if stagedHWKey == nil {
		return
	}
	if buf, err := stagedHWKey.Open(); err == nil {
		buf.Destroy()
	}
	stagedHWKey = nil
}
