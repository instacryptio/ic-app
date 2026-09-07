package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/instacryptio/icfx/cloud"
	"github.com/instacryptio/icfx/contacts"
	"github.com/instacryptio/icfx/identity"
	"github.com/instacryptio/icfx/qr"
	"github.com/instacryptio/icfx/validate"
)

// Cloud contact discovery for the app: directory search/publish, friend
// requests, and the notices feed behind the main screen's badge + dialogs.
// All flow logic and trust checks live in icfx (ParseDirectoryLock,
// SaveFromLock, SendFriendRequest, AcceptContactRequest, DrainPending) —
// these bridge methods only adapt them to the UI.

// --- notices state -----------------------------------------------------------

// queueNotices persists contact drain events (accepted/rotated/revoked) into
// the notification store (the bell drawer's history). The store + its sync live
// in icfx/cloud.
func queueNotices(rep cloud.DrainReport) {
	_ = notifStore().ApplyDrainReport(rep)
}

// --- identity helpers --------------------------------------------------------

// unlockedByFingerprint opens the local identity matching a pending item's
// routing hint, caching opens in opened (several items may target the same
// identity). Empty hint = the default identity. Uses the cached session
// passphrase — a locked app fails here, which background callers treat as
// "skip quietly".
func (s *CloudService) unlockedByFingerprint(fingerprint string, opened map[string]*identity.Unlocked) (*identity.Unlocked, error) {
	if fingerprint == "" {
		name, err := s.defaultIdentityName()
		if err != nil {
			return nil, err
		}
		if u, ok := opened[name]; ok {
			return u, nil
		}
		u, err := openIdentity(name)
		if err != nil {
			return nil, err
		}
		opened[name] = u
		return u, nil
	}

	for _, u := range opened {
		if u.Info().Fingerprint == fingerprint {
			return u, nil
		}
	}
	store, err := newIdentityStore()
	if err != nil {
		return nil, err
	}
	entries, err := store.LoadIndex()
	if err != nil {
		return nil, fmt.Errorf("loading identity index: %w", err)
	}
	for _, idx := range entries {
		if _, ok := opened[idx.Name]; ok {
			continue
		}
		u, err := openIdentityByIndex(idx, store)
		if err != nil {
			return nil, fmt.Errorf("unlocking %q: %w", idx.Name, err)
		}
		opened[idx.Name] = u
		if u.Info().Fingerprint == fingerprint {
			return u, nil
		}
	}
	return nil, fmt.Errorf("no local identity matches the addressed lock")
}

func closeOpened(opened map[string]*identity.Unlocked) {
	for _, u := range opened {
		u.Close()
	}
}

// --- search + add ------------------------------------------------------------

// DirectorySearch searches published identities by name, alias, or email.
// Returns the raw entries; the UI passes the chosen one back verbatim to
// AddContactFromDirectory (which re-validates it — tamper-safe round trip).
func (s *CloudService) DirectorySearch(query string) (string, error) {
	ensurePathsApplied()
	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return "", err
	}
	// Annotate hits already in the local contact list so the UI can disable
	// "add" for them (contacts are zero-knowledge — the server can't filter).
	var contactList []contacts.Contact
	if store, serr := newContactStore(); serr == nil {
		contactList, _ = store.Load()
	}
	results, err := cloud.SearchDirectoryForContacts(ctx, c, query, 25, contactList)
	if err != nil {
		return "", err
	}
	out, err := json.Marshal(results)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

type addFromDirectoryResult struct {
	Alias             string `json:"alias"`
	Updated           bool   `json:"updated"`
	FriendRequestSent bool   `json:"friend_request_sent"`
	AlreadyContact    bool   `json:"already_contact,omitempty"`
}

// AddContactFromDirectory saves a search hit as a contact. The armored lock
// is re-parsed, validated, and fingerprint-cross-checked against the row
// (cloud.ParseDirectoryLock) — the UI round trip cannot smuggle a different
// key. asFriend additionally sends the encrypted contact request as the
// default identity, so the other side can add you back after accepting.
func (s *CloudService) AddContactFromDirectory(entryJSON string, asFriend bool) (string, error) {
	ensurePathsApplied()
	var entry cloud.DirectoryEntry
	if err := json.Unmarshal([]byte(entryJSON), &entry); err != nil {
		return "", fmt.Errorf("parsing directory entry: %w", err)
	}
	lb, err := cloud.ParseDirectoryLock(entry)
	if err != nil {
		return "", err
	}

	// Hard guard behind the disabled UI: never re-add someone already in the
	// contact list (matched by fingerprint, incl. rotated-away previous keys).
	if store, serr := newContactStore(); serr == nil {
		if list, lerr := store.Load(); lerr == nil {
			if existing, ok := contacts.FindByFingerprint(list, entry.Fingerprint); ok {
				out, merr := json.Marshal(addFromDirectoryResult{Alias: existing.Alias, AlreadyContact: true})
				if merr != nil {
					return "", merr
				}
				return string(out), nil
			}
		}
	}

	res := addFromDirectoryResult{}
	if asFriend {
		ctx := context.Background()
		c, cerr := s.authedClient(ctx)
		if cerr != nil {
			return "", cerr
		}
		name, derr := s.defaultIdentityName()
		if derr != nil {
			return "", derr
		}
		u, uerr := openIdentity(name)
		if uerr != nil {
			return "", fmt.Errorf("unlocking identity: %w", uerr)
		}
		defer u.Close()
		if serr := cloud.SendFriendRequest(ctx, c, identity.LockBundleOf(u.Info()), entry, lb); serr != nil {
			return "", serr
		}
		res.FriendRequestSent = true
	}

	if err := contactCapError(1); err != nil {
		return "", err
	}
	store, err := newContactStore()
	if err != nil {
		return "", err
	}
	alias, updated, err := contacts.SaveFromLock(store, lb)
	if err != nil {
		return "", err
	}
	if res.FriendRequestSent {
		if err := store.SetCloudConnection(alias, contacts.ConnectionInvited, time.Now()); err != nil {
			return "", err
		}
	}
	res.Alias, res.Updated = alias, updated
	out, err := json.Marshal(res)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// --- requests inbox ----------------------------------------------------------

type contactRequestJSON struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Alias       string `json:"alias,omitempty"`
	Email       string `json:"email,omitempty"`
	Fingerprint string `json:"fingerprint"`
}

// ContactRequests lists the decrypted incoming friend requests. Items that
// can't be decrypted right now (identity locked or not on this device) are
// skipped — they stay in the inbox for a later pass.
func (s *CloudService) ContactRequests() (string, error) {
	ensurePathsApplied()
	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return "", err
	}
	items, err := c.ListPending(ctx)
	if err != nil {
		return "", err
	}

	opened := map[string]*identity.Unlocked{}
	defer closeOpened(opened)

	out := []contactRequestJSON{}
	for _, it := range items {
		if it.Kind != cloud.KindContactRequest {
			continue
		}
		item, ferr := c.FetchPending(ctx, it.ID)
		if ferr != nil {
			continue
		}
		u, uerr := s.unlockedByFingerprint(item.ToFingerprint, opened)
		if uerr != nil {
			continue
		}
		upd, aerr := cloud.ApplyPending(u, item)
		if aerr != nil || upd.Lock == nil {
			continue
		}
		if validate.ValidateLockBundle(*upd.Lock) != nil {
			continue
		}
		out = append(out, contactRequestJSON{
			ID:          it.ID,
			Name:        upd.Lock.Name,
			Alias:       upd.Lock.Alias,
			Email:       upd.Lock.Email,
			Fingerprint: upd.Lock.Fingerprint,
		})
	}
	raw, err := json.Marshal(out)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

type respondRequestResult struct {
	Alias    string `json:"alias,omitempty"`
	Notified bool   `json:"notified"`
}

// RespondContactRequest accepts or declines one friend request. Accept saves
// the requester's lock as a contact and sends the encrypted accept-back (they
// see it on their side); decline just deletes the item — the requester is
// never notified of a decline.
func (s *CloudService) RespondContactRequest(id string, accept bool) (string, error) {
	ensurePathsApplied()
	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return "", err
	}

	if !accept {
		if err := c.AckPending(ctx, id); err != nil {
			return "", err
		}
		out, _ := json.Marshal(respondRequestResult{})
		return string(out), nil
	}

	item, err := c.FetchPending(ctx, id)
	if err != nil {
		return "", err
	}
	opened := map[string]*identity.Unlocked{}
	defer closeOpened(opened)
	u, err := s.unlockedByFingerprint(item.ToFingerprint, opened)
	if err != nil {
		return "", err
	}
	upd, err := cloud.ApplyPending(u, item)
	if err != nil {
		return "", err
	}
	if upd.Lock == nil {
		return "", fmt.Errorf("request carries no lock")
	}
	if err := validate.ValidateLockBundle(*upd.Lock); err != nil {
		return "", fmt.Errorf("invalid lock in request: %w", err)
	}

	if err := contactCapError(1); err != nil {
		return "", err
	}
	store, err := newContactStore()
	if err != nil {
		return "", err
	}
	alias, _, err := contacts.SaveFromLock(store, *upd.Lock)
	if err != nil {
		return "", err
	}
	// Accepting completes the mutual exchange from this side: we hold their
	// lock, and the accept-back below delivers ours.
	if err := store.SetCloudConnection(alias, contacts.ConnectionConnected, time.Now()); err != nil {
		return "", err
	}
	notified, err := cloud.AcceptContactRequest(ctx, c, upd, identity.LockBundleOf(u.Info()), id)
	if err != nil {
		return "", err
	}
	out, err := json.Marshal(respondRequestResult{Alias: alias, Notified: notified})
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// InviteContact sends a cloud connect invite to an existing contact (added
// by QR scan or file import) so THEY can accept and receive OUR lock —
// completing the mutual exchange without a second QR dance. Delivery
// requires the contact's identity to be published on the cloud; a 404 marks
// the contact "unreachable" (retryable — they may join/publish later).
func (s *CloudService) InviteContact(alias string) error {
	ensurePathsApplied()
	store, err := newContactStore()
	if err != nil {
		return err
	}
	list, err := store.Load()
	if err != nil {
		return fmt.Errorf("loading contacts: %w", err)
	}
	var target *contacts.Contact
	for i := range list {
		if list[i].Alias == alias {
			target = &list[i]
			break
		}
	}
	if target == nil {
		return fmt.Errorf("no contact named %q", alias)
	}

	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return err
	}
	name, err := s.defaultIdentityName()
	if err != nil {
		return err
	}
	u, err := openIdentity(name)
	if err != nil {
		return fmt.Errorf("unlocking identity: %w", err)
	}
	defer u.Close()

	err = cloud.InviteContact(ctx, c, identity.LockBundleOf(u.Info()), qr.LockBundle{
		Fingerprint: target.Fingerprint,
		EncPubKey:   target.EncPubKey,
	})
	if cloud.IsNotFound(err) {
		_ = store.SetCloudConnection(alias, contacts.ConnectionUnreachable, time.Now())
		return fmt.Errorf("%s isn't reachable on Instacrypt Cloud — ask them to join and list their identity in the directory (Settings → Keys → Publish), then retry. Or they can simply scan your QR back", alias)
	}
	if err != nil {
		return err
	}
	return store.SetCloudConnection(alias, contacts.ConnectionInvited, time.Now())
}

// --- publish -----------------------------------------------------------------

// PublishIdentity publishes one identity's lock (public key) to the cloud
// directory so others can find it by name, alias, or email. Opt-in and
// per identity; unpublished identities are never searchable.
func (s *CloudService) PublishIdentity(name string) error {
	ensurePathsApplied()
	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return err
	}
	u, err := openIdentity(name)
	if err != nil {
		return fmt.Errorf("unlocking identity: %w", err)
	}
	defer u.Close()

	err = cloud.PublishIdentityLock(ctx, c, identity.LockBundleOf(u.Info()))
	if errors.Is(err, cloud.ErrEmailRequired) {
		return fmt.Errorf("%w — add one first (Keys tab → Edit)", err)
	}
	return err
}

// UnpublishIdentity removes one identity's lock from the directory.
func (s *CloudService) UnpublishIdentity(name string) error {
	ensurePathsApplied()
	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return err
	}
	u, err := openIdentity(name)
	if err != nil {
		return fmt.Errorf("unlocking identity: %w", err)
	}
	defer u.Close()
	err = c.UnpublishDirectory(ctx, u.Info().Fingerprint)
	if cloud.IsNotFound(err) {
		return nil // already unpublished — the desired state
	}
	return err
}

// PublishedDirectory returns the account's published rows as
// {fingerprint, display_name} pairs. The Keys tab resolves publish-state
// hints by display name — fingerprints live in encrypted meta, so matching
// by name avoids unlocking identities (and HW-key touches) just to render a
// menu. The actual publish/unpublish ops stay fingerprint-keyed.
func (s *CloudService) PublishedDirectory() (string, error) {
	ensurePathsApplied()
	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return "", err
	}
	entries, err := c.ListMyDirectory(ctx)
	if err != nil {
		return "", err
	}
	type row struct {
		Fingerprint string `json:"fingerprint"`
		DisplayName string `json:"display_name"`
	}
	rows := make([]row, len(entries))
	for i, e := range entries {
		rows[i] = row{Fingerprint: e.Fingerprint, DisplayName: e.DisplayName}
	}
	out, err := json.Marshal(rows)
	if err != nil {
		return "", err
	}
	return string(out), nil
}
