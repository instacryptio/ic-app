package main

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/instacryptio/icfx/cloud"
)

// planInfoJSON is the Plan dialog's payload: live server-reported limits plus
// the subscription (absent on the free tier). Nothing here is hardcoded in
// the UI — tiers and limits render exactly as the server defines them.
type planInfoJSON struct {
	Tier string `json:"tier"`
	// Vip: admin-granted Ultimate limits while Tier stays the billing tier —
	// the UI shows a VIP badge and hides the buy/change buttons.
	Vip           bool   `json:"vip"`
	MaxContacts   int    `json:"max_contacts"`
	BackupAllowed bool   `json:"backup_allowed"`
	SubStatus     string `json:"sub_status,omitempty"`
	SubProvider   string `json:"sub_provider,omitempty"`
	RenewsAt      string `json:"renews_at,omitempty"` // YYYY-MM-DD
	// SubCancelPending: the subscription is active but will not renew —
	// the dialog shows "cancels {date}" and a Resume button.
	SubCancelPending bool `json:"sub_cancel_pending,omitempty"`
}

// PlanInfo returns the account's plan limits and subscription state.
func (s *CloudService) PlanInfo() (string, error) {
	ensurePathsApplied()
	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return "", err
	}
	plan, err := c.GetPlan(ctx)
	if err != nil {
		return "", err
	}
	cachePlanLimits(plan.Tier, plan.Limits.MaxContacts)
	info := planInfoJSON{
		Tier:          plan.Tier,
		Vip:           plan.Vip,
		MaxContacts:   plan.Limits.MaxContacts,
		BackupAllowed: plan.Limits.BackupAllowed,
	}
	// Free tier has no subscription — IsNotFound is the normal case there.
	sub, serr := c.GetSubscription(ctx)
	if serr == nil {
		info.SubStatus = sub.Status
		info.SubProvider = sub.Provider
		info.SubCancelPending = sub.CancelAtPeriodEnd
		if sub.CurrentPeriodEnd != nil {
			info.RenewsAt = sub.CurrentPeriodEnd.Format("2006-01-02")
		}
	}
	if serr != nil && !cloud.IsNotFound(serr) {
		return "", serr
	}
	out, err := json.Marshal(info)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// PlanCatalog returns the server's public plan catalog (all tiers in
// upgrade order) for pricing tables. Works without a session — the welcome
// wizard shows it before signup — so it uses the plain client, honoring any
// configured server URL override.
func (s *CloudService) PlanCatalog() (string, error) {
	ensurePathsApplied()
	c, err := s.client()
	if err != nil {
		return "", err
	}
	entries, err := c.ListPlans(context.Background())
	if err != nil {
		return "", err
	}
	out, err := json.Marshal(entries)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// errAlreadySubscribed is the machine token the Dart side matches on to turn
// the checkout guard's 409 into an auto-refresh instead of an error (the
// flugo bridge only carries error strings, so this constant is the contract).
const errAlreadySubscribed = "already_subscribed"

// UpgradePlan starts a checkout for a paid tier and returns the payment URL;
// the UI opens it in the browser and the tier lands via provider webhook.
func (s *CloudService) UpgradePlan(tier string) (string, error) {
	ensurePathsApplied()
	switch tier {
	case "basic", "pro", "ultimate":
	default:
		return "", fmt.Errorf("unknown tier %q", tier)
	}
	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return "", err
	}
	url, err := c.Checkout(ctx, tier)
	if cloud.IsAlreadySubscribed(err) {
		return "", fmt.Errorf("%s", errAlreadySubscribed)
	}
	return url, err
}

// ChangePlan swaps an existing subscription to another paid tier in place —
// immediate, with the prorated difference credited or charged by the
// provider. The new tier lands via webhook; the UI refreshes to see it.
// Only valid while subscribed (the server 404s otherwise) — the UI routes
// unsubscribed accounts through UpgradePlan's checkout instead.
func (s *CloudService) ChangePlan(tier string) error {
	ensurePathsApplied()
	switch tier {
	case "basic", "pro", "ultimate":
	default:
		return fmt.Errorf("unknown tier %q", tier)
	}
	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return err
	}
	return c.ChangeSubscription(ctx, tier)
}

// CancelPlan schedules the subscription to end at the period boundary; the
// account keeps its paid tier until then and can Resume any time before.
func (s *CloudService) CancelPlan() error {
	ensurePathsApplied()
	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return err
	}
	return c.CancelSubscription(ctx)
}

// ResumePlan clears a pending at-period-end cancellation.
func (s *CloudService) ResumePlan() error {
	ensurePathsApplied()
	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return err
	}
	return c.ResumeSubscription(ctx)
}
