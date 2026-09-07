package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/hkdb/flugo/pkg/bridge"
	"github.com/hkdb/flugo/pkg/filechooser"

	"github.com/instacryptio/icfx/cloud"
	"github.com/instacryptio/icfx/config"
	"github.com/instacryptio/icfx/crypto"
	"github.com/instacryptio/icfx/groups"
	"github.com/instacryptio/icfx/recipient"
	"github.com/instacryptio/icfx/sharing"
)

// shareResultJSON is the IC Share result dialog's payload.
type shareResultJSON struct {
	ShareID   string `json:"share_id"`
	SizeBytes int64  `json:"size_bytes"`
	// Warnings are icfx-composed advisories (a recipient with no fingerprint, or
	// one not currently published to the directory). NOT omitempty — an omitted
	// field decodes to null in Dart and the generated cast throws.
	Warnings []string `json:"warnings"`
}

// shareItemJSON is one row of the Manage Shared Files sheet.
type shareItemJSON struct {
	ID            string `json:"id"`
	FileName      string `json:"file_name"`
	FileSize      int64  `json:"file_size"`
	Status        string `json:"status"`
	DownloadCount int32  `json:"download_count"`
	SingleUse     bool   `json:"single_use"`
	TTLExpiresAt  string `json:"ttl_expires_at"` // RFC3339, "" = never expires
	Recipient     string `json:"recipient"`      // contact alias, or grouped fingerprint
}

// shareEncryptedFile uploads an already-encrypted .icfx file (the output of a
// local encrypt) as a cloud share, addressed to the SAME recipient set the file
// was encrypted to. recipients holds contact aliases and/or group names (a group
// expands to its members, mirroring the encrypt picker); alsoSelf additionally
// shares to the account's own devices (no fingerprint leaves the device, no email
// exists). An empty recipients with alsoSelf is a pure self-share.
// ttlSeconds 0 = the share never expires; noNotify suppresses the recipient
// e-mail (they still see it in their notification drawer). onProgress (nil ok)
// reports upload progress (0..1).
func (s *CloudService) shareEncryptedFile(filePath string, recipients []string, alsoSelf bool, ttlSeconds int64, singleUse, noNotify bool, onProgress func(pct float64)) (string, error) {
	ensurePathsApplied()
	c, err := s.authedClient(context.Background())
	if err != nil {
		return "", err
	}
	// Resolve contacts + groups to {lock, fingerprint, alias} triples via icfx —
	// the same entry point the CLI uses, so resolution is identical everywhere.
	// A pure self-share (no named recipients) has no contact targets, so skip the
	// resolve (ForShareMany errors on an empty reachable set by design).
	var recs []sharing.Recipient
	var resolveWarnings []string
	if len(recipients) > 0 {
		store, err := newContactStore()
		if err != nil {
			return "", err
		}
		list, err := store.Load()
		if err != nil {
			return "", fmt.Errorf("loading contacts: %w", err)
		}
		var groupList []groups.Group
		if gs, gerr := newGroupStore(); gerr == nil {
			groupList, _ = gs.List()
		}
		targets, warnings, err := recipient.ForShareMany(list, groupList, recipients)
		if err != nil {
			return "", err
		}
		resolveWarnings = warnings
		recs = make([]sharing.Recipient, len(targets))
		for i, t := range targets {
			recs[i] = sharing.Recipient{Lock: t.Lock, Fingerprint: t.Fingerprint, Alias: t.Alias}
		}
	}

	var up func(sent, total int64)
	if onProgress != nil {
		up = func(sent, total int64) {
			if total > 0 {
				onProgress(float64(sent) / float64(total))
			}
		}
	}
	res, err := sharing.SendEncryptedProgress(context.Background(), c, recs, filePath, sharing.SendOptions{
		TTL:       time.Duration(ttlSeconds) * time.Second,
		SingleUse: singleUse,
		NoNotify:  noNotify,
		ToSelf:    alsoSelf,
	}, up)
	if err != nil {
		return "", shareErrMessage(err)
	}
	if alsoSelf {
		// Don't badge the sender for its own upload; other devices do get
		// the live notice. The sender's row stays decryptable like theirs.
		var expires time.Time
		if ttlSeconds > 0 {
			expires = time.Now().UTC().Add(time.Duration(ttlSeconds) * time.Second)
		}
		_ = notifStore().SeedSelfShare(res.ShareID, filepath.Base(filePath), res.CiphertextBytes, expires, singleUse)
	}
	// Advisories composed in icfx (recipient with no fingerprint at resolve time,
	// plus recipients the server reports as not currently published) — the app
	// only renders them.
	warnings := append(append([]string{}, resolveWarnings...), res.Warnings...)
	out, err := json.Marshal(shareResultJSON{
		ShareID:   res.ShareID,
		SizeBytes: res.CiphertextBytes,
		Warnings:  warnings,
	})
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// ShareEncryptedFile is the one-shot send (no progress); the Dart side shows a
// spinner and consumes the shareResultJSON.
func (s *CloudService) ShareEncryptedFile(filePath string, recipients []string, alsoSelf bool, ttlSeconds int64, singleUse, noNotify bool) (string, error) {
	return s.shareEncryptedFile(filePath, recipients, alsoSelf, ttlSeconds, singleUse, noNotify, nil)
}

// SendProgress is one event on the streaming send: a determinate upload fraction
// (known from byte 0) or the terminal event carrying the shareResultJSON.
type SendProgress struct {
	Phase string  `json:"phase"` // "upload" | "done"
	Pct   float64 `json:"pct"`   // 0..1 during upload
	// Result is the shareResultJSON on "done" ("" otherwise). NOT omitempty — an
	// omitted field decodes to null in Dart and the generated `as String` throws.
	Result string `json:"result"`
}

// ShareEncryptedFileStream is the streaming send: it emits a determinate upload
// fill (0→1), then a terminal event with the shareResultJSON. The Dart side
// (generated Stream<SendProgress>) drives the progress circle. Throttled to ~1%.
func (s *CloudService) ShareEncryptedFileStream(filePath string, recipients []string, alsoSelf bool, ttlSeconds int64, singleUse, noNotify bool) *bridge.Emitter[SendProgress] {
	em := bridge.NewEmitter[SendProgress]()
	go func() {
		defer em.Close()
		lastPct := -1.0
		onProgress := func(pct float64) {
			if pct > 1 {
				pct = 1
			}
			if pct < 1 && pct-lastPct < 0.01 {
				return
			}
			lastPct = pct
			_ = em.Send(SendProgress{Phase: "upload", Pct: pct})
		}
		result, err := s.shareEncryptedFile(filePath, recipients, alsoSelf, ttlSeconds, singleUse, noNotify, onProgress)
		if err != nil {
			em.Fail(err)
			return
		}
		_ = em.Send(SendProgress{Phase: "done", Pct: 1, Result: result})
	}()
	return em
}

// downloadRawShare fetches the RAW encrypted .icfx blob of a share the caller
// SENT (sender-only, server-authorized) and writes it — undecrypted — to the
// user's chosen location. Mirrors receiveShare's download→WriteFileStream flow
// but skips decrypt: the file stays a sealed .icfx that only the recipient's key
// can open. destDir "" routes through the temp path so the mobile SAF dialog
// picks the location; on desktop the UI supplies the directory. onProgress
// (nil ok) reports the download fraction (0..1).
func (s *CloudService) downloadRawShare(shareID, destDir string, force bool, onProgress func(pct float64)) (string, error) {
	ensurePathsApplied()
	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return "", err
	}

	// Stream the ciphertext to a temp file (constant memory), then move it to the
	// chosen location. It only ever holds encrypted bytes and is removed after.
	encTmp, err := os.CreateTemp(config.TempDir(), "ic-raw-*")
	if err != nil {
		return "", fmt.Errorf("temp file: %w", err)
	}
	encPath := encTmp.Name()
	defer os.Remove(encPath)

	var dlProgress func(done, total int64)
	if onProgress != nil {
		dlProgress = func(done, total int64) {
			if total > 0 {
				onProgress(float64(done) / float64(total))
			}
		}
	}
	dl, err := sharing.DownloadRawProgress(ctx, c, shareID, encTmp, dlProgress)
	encTmp.Close()
	if err != nil {
		return "", shareErrMessage(err)
	}

	enc, err := os.Open(encPath)
	if err != nil {
		return "", fmt.Errorf("reopening download: %w", err)
	}
	defer enc.Close()

	name := rawReceiveName(dl.FileName, shareID)
	target := name
	if destDir != "" {
		target = filepath.Join(destDir, name)
	}
	wr, err := filechooser.WriteFileStream(target, force, func(w io.Writer) error {
		_, cErr := io.Copy(w, enc)
		return cErr
	})
	if err != nil {
		return "", err
	}
	out, err := json.Marshal(wr)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// DownloadRawShareStream is the streaming raw download: it emits the download
// fill (0→1), then a terminal event carrying the WriteResult JSON the Dart side
// finalizes with handleWriteResult. Reuses ReceiveProgress. Throttled to ~1%.
func (s *CloudService) DownloadRawShareStream(shareID, destDir string, force bool) *bridge.Emitter[ReceiveProgress] {
	em := bridge.NewEmitter[ReceiveProgress]()
	go func() {
		defer em.Close()
		lastPct := -1.0
		onProgress := func(pct float64) {
			if pct > 1 {
				pct = 1
			}
			if pct < 1 && pct-lastPct < 0.01 {
				return
			}
			lastPct = pct
			_ = em.Send(ReceiveProgress{Phase: "download", Pct: pct})
		}
		result, err := s.downloadRawShare(shareID, destDir, force, onProgress)
		if err != nil {
			em.Fail(err)
			return
		}
		_ = em.Send(ReceiveProgress{Phase: "done", Pct: 1, Result: result})
	}()
	return em
}

// rawReceiveName derives a safe local file name for a raw share download,
// KEEPING the .icfx extension (the file stays encrypted). Path components are
// stripped so a hostile share name can't traverse out of the destination.
func rawReceiveName(declared, shareID string) string {
	name := filepath.Base(strings.TrimSpace(declared))
	switch name {
	case "", ".", "..", string(filepath.Separator):
		return "share-" + shareID + ".icfx"
	}
	if !strings.HasSuffix(strings.ToLower(name), ".icfx") {
		name += ".icfx"
	}
	return name
}

// ListMyShares returns the account's shares for the Manage Shared Files
// sheet, with recipients resolved to local contact aliases when possible.
func (s *CloudService) ListMyShares() (string, error) {
	ensurePathsApplied()
	c, err := s.authedClient(context.Background())
	if err != nil {
		return "", err
	}
	items, err := c.ListShares(context.Background(), 0)
	if err != nil {
		return "", err
	}

	aliasByFp := contactAliasesByFingerprint()
	out := make([]shareItemJSON, len(items))
	for i, it := range items {
		expires := ""
		if !it.TTLExpiresAt.IsZero() {
			expires = it.TTLExpiresAt.Format(time.RFC3339)
		}
		names := make([]string, 0, len(it.RecipientFingerprints)+1)
		for _, fp := range it.RecipientFingerprints {
			names = append(names, recipientDisplay(aliasByFp, fp))
		}
		if it.ToSelf {
			names = append(names, "My devices")
		}
		out[i] = shareItemJSON{
			ID:            it.ID,
			FileName:      it.FileName,
			FileSize:      it.FileSize,
			Status:        it.Status,
			DownloadCount: int32(it.DownloadedCount), // recipients who have received it
			SingleUse:     it.SingleUse,
			TTLExpiresAt:  expires,
			Recipient:     strings.Join(names, ", "),
		}
	}
	data, err := json.Marshal(out)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// CancelCloudShare deletes a share, freeing its slot and storage.
func (s *CloudService) CancelCloudShare(shareID string) error {
	ensurePathsApplied()
	c, err := s.authedClient(context.Background())
	if err != nil {
		return err
	}
	return c.CancelShare(context.Background(), shareID)
}

func contactAliasesByFingerprint() map[string]string {
	byFp := map[string]string{}
	store, err := newContactStore()
	if err != nil {
		return byFp
	}
	list, err := store.Load()
	if err != nil {
		return byFp
	}
	for _, ct := range list {
		if ct.Fingerprint != "" {
			byFp[strings.ToLower(ct.Fingerprint)] = ct.Alias
		}
	}
	return byFp
}

func recipientDisplay(aliasByFp map[string]string, fingerprint string) string {
	if alias, ok := aliasByFp[strings.ToLower(fingerprint)]; ok {
		return alias
	}
	grouped := crypto.FormatGrouped(fingerprint)
	if len(grouped) > 19 {
		return grouped[:19] + "…"
	}
	return grouped
}

// shareErrMessage translates SDK share errors into user-facing text.
func shareErrMessage(err error) error {
	if cloud.IsPaymentRequired(err) {
		return fmt.Errorf("active share limit reached — delete a share in Settings → Cloud → Manage Shared Files, or upgrade your plan")
	}
	if strings.Contains(err.Error(), "not available on this plan") {
		return fmt.Errorf("file sharing requires a paid plan — see Settings → Cloud → Plan")
	}
	return err
}
