package main

// The auto-sync engine: a single background goroutine that keeps this device
// converged with the cloud. Triggers are (a) an interval ticker
// (cfg.CloudAutoSyncMinutes), (b) server change events over the SSE doorbell
// (instant sync when another device pushes), and (c) a startup kick.
//
// Background rule: NEVER prompt. A sync needing the cloud password
// (ErrEncKeyMissing/Stale) or an unlocked session quietly skips that
// resource; the next MANUAL Sync surfaces the dialogs. Results land in
// lastSync state, which CloudUIState exposes for the Cloud tab.

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/instacryptio/icfx/cloud"
	"github.com/instacryptio/icfx/config"
)

var (
	autoSyncMu     sync.Mutex
	autoSyncCancel context.CancelFunc // non-nil while the engine runs

	// syncRunMu serializes sync execution: manual Sync and background runs
	// never overlap (background skips instead of queueing).
	syncRunMu sync.Mutex

	lastSyncMu sync.Mutex
	lastSync   struct {
		At      time.Time
		Summary string
		Err     string
	}

	// autoSyncTestInterval overrides the configured interval (tests only).
	autoSyncTestInterval time.Duration
)

func recordLastSync(summary, errText string) {
	lastSyncMu.Lock()
	defer lastSyncMu.Unlock()
	lastSync.At = time.Now()
	lastSync.Summary = summary
	lastSync.Err = errText
}

// EnsureAutoSync starts or stops the background engine to match the current
// config + session (idempotent). The frontend calls it once after app init;
// backend cloud-state mutations call ensureAutoSync internally.
func (s *CloudService) EnsureAutoSync() error {
	return s.ensureAutoSync()
}

// SetAutoSyncMinutes updates the interval (0 = off) and re-applies the engine
// state.
func (s *CloudService) SetAutoSyncMinutes(minutes int) error {
	ensurePathsApplied()
	if minutes < 0 {
		minutes = 0
	}
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	cfg.CloudAutoSyncMinutes = minutes
	if err := cfg.Save(); err != nil {
		return err
	}
	return s.ensureAutoSync()
}

func (s *CloudService) ensureAutoSync() error {
	ensurePathsApplied()
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	_, signedIn := s.hasSession()
	want := cfg.CloudEnabled && cfg.CloudAutoSyncMinutes > 0 && signedIn

	autoSyncMu.Lock()
	defer autoSyncMu.Unlock()
	running := autoSyncCancel != nil
	if want == running {
		return nil
	}
	if !want {
		autoSyncCancel()
		autoSyncCancel = nil
		return nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	autoSyncCancel = cancel
	interval := time.Duration(cfg.CloudAutoSyncMinutes) * time.Minute
	if autoSyncTestInterval > 0 {
		interval = autoSyncTestInterval
	}
	go s.autoSyncLoop(ctx, interval)
	return nil
}

// autoSyncLoop coalesces ticker + doorbell events into background sync runs.
func (s *CloudService) autoSyncLoop(ctx context.Context, interval time.Duration) {
	trigger := make(chan struct{}, 1)
	kick := func() {
		select {
		case trigger <- struct{}{}:
		default:
		}
	}

	// The SSE doorbell: reconnects with backoff; refreshes the token before
	// each (re)connect. Its only job is kicking the trigger.
	go func() {
		c, err := s.client()
		if err != nil {
			return
		}
		c.StreamEventsWithRetry(ctx, func(cloud.ChangeEvent) { kick() }, func(bctx context.Context) error {
			_, aerr := s.authedClient(bctx)
			return aerr
		})
	}()

	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	kick() // startup convergence

	debounce := time.NewTimer(0)
	if !debounce.Stop() {
		<-debounce.C
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			kick()
		case <-trigger:
			// Debounce event bursts (a multi-resource push fires several
			// doorbells) into one sync run.
			debounce.Reset(500 * time.Millisecond)
		case <-debounce.C:
			s.runBackgroundSync(ctx)
		}
	}
}

// runBackgroundSync executes one quiet sync pass. Skips (without queueing)
// when a manual Sync is in flight.
func (s *CloudService) runBackgroundSync(ctx context.Context) {
	if !syncRunMu.TryLock() {
		return
	}
	defer syncRunMu.Unlock()

	raw, err := s.syncLocked(ctx, cloud.SyncOptions{Background: true})
	if err != nil {
		recordLastSync("", err.Error())
		return
	}
	recordLastSync(summarizeOutcomes(raw), "")
}

// summarizeOutcomes renders the outcome JSON as the short human line the
// Cloud tab shows ("contacts: pulled (v4) · settings: up to date (v2)").
func summarizeOutcomes(outcomes []syncOutcomeJSON) string {
	parts := make([]string, 0, len(outcomes))
	for _, o := range outcomes {
		switch {
		case o.Error != "" && o.Action == "":
			parts = append(parts, o.Resource+": "+o.Error)
		case o.Action == "needs-code":
			parts = append(parts, o.Resource+": second factor required — open the Cloud tab")
		case o.Action == "needs-default-change":
			parts = append(parts, o.Resource+": default-identity change needs your approval — open the Cloud tab")
		case o.Action == "needs-reseal":
			parts = append(parts, o.Resource+": orphaned cloud copy needs your approval to re-seal — open the Cloud tab")
		case o.Action == "skipped":
			parts = append(parts, o.Resource+": skipped"+skipReason(o.Error))
		case o.Action == "synced":
			parts = append(parts, o.Resource+": synced")
		case o.CloudWasNewer:
			parts = append(parts, o.Resource+": "+o.Action+" (cloud was newer)")
		default:
			parts = append(parts, o.Resource+": "+o.Action)
		}
	}
	return strings.Join(parts, " · ")
}

// skipReason appends the concrete skip reason when the engine supplied one (e.g.
// a hardware-key/unlock marker) — replacing the old hardcoded cloud-password
// string that misreported every skip regardless of cause.
func skipReason(reason string) string {
	if reason == "" {
		return ""
	}
	return " — " + reason
}
