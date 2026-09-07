package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/instacryptio/icfx/cloud"
	"github.com/instacryptio/icfx/config"
)

// Contact-cap gate. The server can never count contacts (they're ciphertext
// — the zero-knowledge promise), so the plan's contact limit is enforced
// client-side at the cloud boundary: adds are refused once the cached plan
// limit is reached, and the sync contacts leg (icfx SyncContactsOps)
// hard-blocks as the backstop for anything that slips past (offline adds,
// modified clients syncing through honest ones).

// planCache is the offline snapshot of the account's plan contact limit. It is
// a plain, non-secret sidecar (the SessionStore owns tokens + sync positions;
// this stays out of it).
type planCache struct {
	Tier        string    `json:"tier"`
	MaxContacts int       `json:"max_contacts"`
	CheckedAt   time.Time `json:"checked_at"`
}

func planCachePath() (string, error) {
	dir, err := config.ConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "cloud_plan_cache.json"), nil
}

func loadPlanCache() planCache {
	path, err := planCachePath()
	if err != nil {
		return planCache{}
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return planCache{}
	}
	var pc planCache
	_ = json.Unmarshal(raw, &pc)
	return pc
}

func savePlanCache(pc planCache) {
	path, err := planCachePath()
	if err != nil {
		return
	}
	raw, err := json.Marshal(pc)
	if err != nil {
		return
	}
	_ = os.WriteFile(path, raw, 0600)
}

// cachePlanLimits persists the plan's contact limit for the offline gate.
func cachePlanLimits(tier string, maxContacts int) {
	savePlanCache(planCache{Tier: tier, MaxContacts: maxContacts, CheckedAt: time.Now().UTC()})
}

// refreshPlanCacheIfStale piggybacks on an already-authed call (the notices
// poll) to keep the cached limit fresh without a dedicated poll.
func refreshPlanCacheIfStale(ctx context.Context, c *cloud.Client) {
	if pc := loadPlanCache(); time.Since(pc.CheckedAt) < time.Hour {
		return
	}
	plan, err := c.GetPlan(ctx)
	if err != nil {
		return // best-effort; the sync gate backstops
	}
	cachePlanLimits(plan.Tier, plan.Limits.MaxContacts)
}

// contactCapError returns a user-facing error when adding `adding` more
// contact(s) would exceed the cached plan limit. Nil when cloud contact
// sync is off, nothing is cached yet (offline-first — the sync gate
// backstops), or capacity remains. Local-only setups are never gated.
func contactCapError(adding int) error {
	cfg, err := config.Load()
	if err != nil || !cfg.CloudEnabled || !cfg.CloudSyncContacts {
		return nil
	}
	pc := loadPlanCache()
	if pc.MaxContacts <= 0 {
		return nil
	}
	store, err := newContactStore()
	if err != nil {
		return nil
	}
	list, err := store.Load()
	if err != nil {
		return nil
	}
	if len(list)+adding > pc.MaxContacts {
		return fmt.Errorf("your %s plan syncs up to %d contacts (you have %d) — upgrade your plan or remove a contact first",
			pc.Tier, pc.MaxContacts, len(list))
	}
	return nil
}
