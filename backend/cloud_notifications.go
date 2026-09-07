package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/hkdb/flugo/pkg/bridge"
	"github.com/hkdb/flugo/pkg/filechooser"

	"github.com/instacryptio/icfx/cloud"
	"github.com/instacryptio/icfx/config"
	"github.com/instacryptio/icfx/contacts"
	"github.com/instacryptio/icfx/decrypt"
	"github.com/instacryptio/icfx/format"
	"github.com/instacryptio/icfx/identity"
	"github.com/instacryptio/icfx/sharing"
)

// The notification ENGINE — the store, its CRDT merge, zero-knowledge
// cross-device sync, and reconciliation against the share/pending inboxes —
// lives in icfx/cloud (cloud.NotificationStore), shared by every client. This
// file is only the flugo bridge: it drives the store at the right cadence and
// renders its records for the Dart drawer.

var (
	notifStoreMu   sync.Mutex
	notifStoreInst *cloud.NotificationStore
)

// notifStore returns the process-wide notification store (one instance so its
// internal lock actually serializes file access). Built lazily on the config
// dir; reset by tests that swap HOME.
func notifStore() *cloud.NotificationStore {
	notifStoreMu.Lock()
	defer notifStoreMu.Unlock()
	if notifStoreInst != nil {
		return notifStoreInst
	}
	dir, err := config.ConfigDir()
	if err != nil {
		return cloud.NewNotificationStore("") // degraded: ops fail soft
	}
	notifStoreInst = cloud.DefaultNotificationStore(dir)
	return notifStoreInst
}

type cloudNoticesJSON struct {
	Enabled bool `json:"enabled"`
	// SignedIn reports a persisted session (tokens on disk — no network
	// check). Gates the home-screen bell + sync icons.
	SignedIn      bool                 `json:"signed_in"`
	UnseenCount   int                  `json:"unseen_count"`
	Invites       int                  `json:"invites"`
	Notifications []cloud.Notification `json:"notifications"`
}

// CloudNotices is the main screen's poll target: reconciles the drawer against
// the live server inboxes (incoming shares + pending invites) and returns the
// full state. Signed-out or cloud-off states return the zero payload, never an
// error — the poll must be safe to fire blindly. (The cross-device blob sync is
// separate: it rides RunSync, which holds the default identity open.)
func (s *CloudService) CloudNotices() (string, error) {
	ensurePathsApplied()
	empty, _ := json.Marshal(cloudNoticesJSON{Notifications: []cloud.Notification{}})

	cfg, err := config.Load()
	if err != nil || !cfg.CloudEnabled {
		return string(empty), nil
	}

	store := notifStore()

	// Signed-out still returns the stored history (the drawer remains
	// browsable); reconcile happens only with a live session.
	invites := 0
	ctx := context.Background()
	if c, cerr := s.authedClient(ctx); cerr == nil {
		if inbox, ierr := c.ShareInbox(ctx, 0); ierr == nil {
			_ = store.ReconcileShares(inbox)
		}
		if pending, perr := c.ListPending(ctx); perr == nil {
			invites, _ = store.ReconcilePending(pending)
		}
		refreshPlanCacheIfStale(ctx, c) // keeps the contact-cap gate current
	}

	_, signedIn := s.hasSession()
	items := store.List()
	res := cloudNoticesJSON{
		Enabled:       true,
		SignedIn:      signedIn,
		Invites:       invites,
		UnseenCount:   store.UnseenCount(),
		Notifications: items,
	}
	if res.Notifications == nil {
		res.Notifications = []cloud.Notification{}
	}
	out, err := json.Marshal(res)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// MarkNotificationsSeen clears the badges (drawer opened).
func (s *CloudService) MarkNotificationsSeen() error {
	ensurePathsApplied()
	return notifStore().MarkAllSeen()
}

// DeleteNotification dismisses a drawer row; the tombstone syncs so it stays
// gone on every device.
func (s *CloudService) DeleteNotification(id string) error {
	ensurePathsApplied()
	return notifStore().Dismiss(id)
}

// receiveResult mirrors decryptResult so the Dart side reuses the same
// handleWriteResult + success-dialog handling as a local decrypt.
type receiveResult struct {
	filechooser.WriteResult
	VerifyMsg string `json:"verify_msg,omitempty"`
	FileName  string `json:"file_name"`
	Sender    string `json:"sender,omitempty"`
}

// receiveShare downloads a share, decrypts it with the identity matching the
// share's recipient fingerprint (falling back to the default identity), and
// writes the plaintext. destDir "" writes through the temp path so the mobile
// SAF dialog chooses the location; on desktop the UI supplies the directory from
// the portal picker. onDownload (nil ok) reports download progress; onDecrypt
// (nil ok) fires once the download completes and decryption begins.
func (s *CloudService) receiveShare(shareID, destDir string, force bool, onProgress func(phase string, pct float64)) (string, error) {
	ensurePathsApplied()
	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return "", err
	}

	store := notifStore()
	fp := store.RecipientFor(shareID)
	sender := ""
	var notifSize int64 // the share's byte size from the notification — a reliable
	// progress total that doesn't depend on the server download response.
	for _, n := range store.List() {
		if n.Kind == cloud.NotifShare && n.ShareID == shareID {
			sender = n.Sender
			notifSize = n.FileSize
		}
	}

	// Download the ciphertext to a temp file (constant memory; the streaming
	// decryptor needs to seek). It only ever holds encrypted bytes, and is
	// removed after decrypt.
	encTmp, err := os.CreateTemp(config.TempDir(), "ic-recv-enc-*")
	if err != nil {
		return "", fmt.Errorf("temp file: %w", err)
	}
	encPath := encTmp.Name()
	defer os.Remove(encPath)

	// Progress is one continuous 0→1 fill: download is the first half, decrypt the
	// second (both process ~the ciphertext byte count). Total comes from the
	// notification (reliable), not the server download response. Callback gets the
	// OVERALL fraction; the caller throttles. No initial 0 emit — the UI stays
	// indeterminate until a real value arrives.
	var dlProgress func(done, total int64)
	if onProgress != nil && notifSize > 0 {
		dlProgress = func(done, _ int64) {
			onProgress("download", 0.5*float64(done)/float64(notifSize))
		}
	}
	dl, err := sharing.DownloadCiphertextProgress(ctx, c, shareID, encTmp, dlProgress)
	encTmp.Close()
	if err != nil {
		return "", err
	}

	enc, err := os.Open(encPath)
	if err != nil {
		return "", fmt.Errorf("reopening download: %w", err)
	}
	defer enc.Close()

	opened := map[string]*identity.Unlocked{}
	defer closeOpened(opened)
	unlocked, err := s.unlockedByFingerprint(fp, opened)
	if err != nil {
		return "", shareUnlockErr(err)
	}

	name := sharing.ReceiveName(dl.FileName, shareID)
	target := name
	if destDir != "" {
		target = filepath.Join(destDir, name)
	}

	// Decrypt straight into the output writer. Shares carry the icfx container
	// (signature verified against contacts, like a local decrypt); bare age is
	// the legacy fallback. A failed attempt writes nothing before erroring, so
	// the self-share fallback can retry other identities on the same writer.
	var verifyMsg string
	wr, err := filechooser.WriteFileStream(target, force, func(w io.Writer) error {
		// Decrypt progress = plaintext bytes written / ciphertext size (plaintext ≈
		// ciphertext), mapped onto the second half of the bar. notifSize is the
		// reliable total (server download FileSize may be absent).
		out := w
		if onProgress != nil && notifSize > 0 {
			out = &countingWriter{w: w, cb: func(written int64) {
				p := float64(written) / float64(notifSize)
				if p > 1 {
					p = 1
				}
				onProgress("decrypt", 0.5+0.5*p)
			}}
		}
		vm, derr := s.decryptShareStream(enc, out, unlocked)
		if derr != nil && fp == "" {
			// Self-shares carry no identity hint (nothing left the device) — the
			// file may be encrypted to a non-default identity, so try the rest.
			vm, derr = s.decryptStreamWithAnyIdentity(enc, out, opened)
		}
		if derr != nil {
			return derr
		}
		verifyMsg = vm
		return nil
	})
	if err != nil {
		return "", shareUnlockErr(err)
	}

	// Exists (native desktop, force=false): nothing was decrypted/received —
	// the UI re-invokes with force. Don't consume the share or mark handled.
	if wr.Exists {
		out, merr := json.Marshal(receiveResult{WriteResult: wr, FileName: name, Sender: sender})
		if merr != nil {
			return "", merr
		}
		return string(out), nil
	}

	// Consume the (single-use) share only after a successful receive. Best-effort
	// and non-fatal: the file is saved; if this fails the share may re-appear in
	// the inbox until it expires, and a later receive will complete it.
	_ = c.CompleteShare(ctx, shareID)

	// Mark the drawer row downloaded-here (per-device; the row stays as history).
	_ = store.MarkHandled("share:" + shareID)

	out, err := json.Marshal(receiveResult{
		WriteResult: wr,
		VerifyMsg:   verifyMsg,
		FileName:    name,
		Sender:      sender,
	})
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// ReceiveShare is the one-shot receive (no progress) used where a spinner is
// enough; the Dart side reuses handleWriteResult on the returned JSON.
func (s *CloudService) ReceiveShare(shareID, destDir string, force bool) (string, error) {
	return s.receiveShare(shareID, destDir, force, nil)
}

// ReceiveProgress is one event on the streaming receive: an OVERALL progress
// fraction (download fills the first half, decrypt the second) or the terminal
// event carrying the receiveResult JSON (the same payload ReceiveShare returns).
type ReceiveProgress struct {
	Phase string  `json:"phase"` // "download" | "decrypt" | "done"
	Pct   float64 `json:"pct"`   // overall 0..1 (continuous through both phases)
	// Result is the receiveResult JSON on "done" ("" otherwise). NOT omitempty:
	// an omitted field decodes to null on the Dart side and the generated
	// `as String` cast throws — the empty string must be present on the wire.
	Result string `json:"result"`
}

// ReceiveShareStream is the streaming receive: it emits one continuous 0→1
// progress fill (download then decrypt), then a terminal event with the result.
// The Dart side (generated Stream<ReceiveProgress>) drives the determinate
// progress circle and finishes with handleWriteResult on the "done" payload.
// Progress is throttled to ~1% steps so the UI isn't flooded.
func (s *CloudService) ReceiveShareStream(shareID, destDir string, force bool) *bridge.Emitter[ReceiveProgress] {
	em := bridge.NewEmitter[ReceiveProgress]()
	go func() {
		defer em.Close()
		lastPct := -1.0
		onProgress := func(phase string, pct float64) {
			if pct > 1 {
				pct = 1
			}
			if pct < 1 && pct-lastPct < 0.01 {
				return
			}
			lastPct = pct
			_ = em.Send(ReceiveProgress{Phase: phase, Pct: pct})
		}

		result, err := s.receiveShare(shareID, destDir, force, onProgress)
		if err != nil {
			em.Fail(err)
			return
		}
		_ = em.Send(ReceiveProgress{Phase: "done", Pct: 1, Result: result})
	}()
	return em
}

// countingWriter reports cumulative bytes written to a callback — used to turn a
// streaming decrypt into determinate progress.
type countingWriter struct {
	w  io.Writer
	n  int64
	cb func(written int64)
}

func (c *countingWriter) Write(b []byte) (int, error) {
	n, err := c.w.Write(b)
	if n > 0 {
		c.n += int64(n)
		c.cb(c.n)
	}
	return n, err
}

// shareUnlockErr mirrors unlockErrText for the share-receive path: unlock
// preconditions become the machine-checkable markers the Dart layer acts on
// (tap flow / unlock prompt) instead of raw internal errors. The HW marker
// is returned UNWRAPPED — the Dart extractor takes everything after the
// marker as the identity name, so nothing may follow it.
func shareUnlockErr(err error) error {
	var hw *hwRequiredError
	if errors.As(err, &hw) {
		return errors.New(errHWRequiredPrefix + hw.identity)
	}
	if strings.Contains(err.Error(), "passphrase required") {
		return errors.New("app is locked — unlock and try again")
	}
	return fmt.Errorf("decrypting share: %w", err)
}

// decryptShareStream decrypts one downloaded share (from a seekable ciphertext
// temp file) with one identity, streaming the plaintext to dst. icfx containers
// run the full parse + signature-verify path; bare age is the legacy fallback.
// Returns the verify message (empty for bare age). On failure (e.g. wrong
// recipient) it fails BEFORE writing any plaintext to dst, so a caller may retry
// with another identity on the same dst.
func (s *CloudService) decryptShareStream(src io.ReadSeeker, dst io.Writer, unlocked *identity.Unlocked) (string, error) {
	if _, err := src.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	head := make([]byte, 64)
	n, _ := io.ReadFull(src, head)
	if _, err := src.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	switch format.Detect(head[:n]) {
	case format.FormatICFX:
		var contactList []contacts.Contact
		if cstore, cerr := newContactStore(); cerr == nil {
			contactList, _ = cstore.Load()
		}
		res, err := decrypt.DecryptAndVerifyStream(src, dst, unlocked, contactList)
		if err != nil {
			return "", err
		}
		return verifyMsgFor(res), nil
	default:
		r, err := unlocked.DecryptStream(src)
		if err != nil {
			return "", err
		}
		if _, err := io.Copy(dst, r); err != nil {
			return "", err
		}
		return "", nil
	}
}

// decryptStreamWithAnyIdentity tries every local identity in turn — used for
// self-shares, which deliberately carry no identity hint. It re-seeks src for
// each attempt; a failed attempt writes nothing before erroring, so retrying on
// the same dst is safe.
func (s *CloudService) decryptStreamWithAnyIdentity(src io.ReadSeeker, dst io.Writer, opened map[string]*identity.Unlocked) (string, error) {
	store, err := newIdentityStore()
	if err != nil {
		return "", err
	}
	entries, err := store.LoadIndex()
	if err != nil {
		return "", fmt.Errorf("loading identity index: %w", err)
	}
	var lastErr error
	for _, idx := range entries {
		u, ok := opened[idx.Name]
		if !ok {
			u, err = openIdentityByIndex(idx, store)
			if err != nil {
				lastErr = fmt.Errorf("unlocking %q: %w", idx.Name, err)
				continue
			}
			opened[idx.Name] = u
		}
		vm, derr := s.decryptShareStream(src, dst, u)
		if derr == nil {
			return vm, nil
		}
		lastErr = derr
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("no identities available")
	}
	return "", lastErr
}
