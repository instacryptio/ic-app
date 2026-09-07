package main

import (
	"context"
	"encoding/json"
)

// Devices (sessions) bridge — the Cloud tab's Devices section lists the
// account's live logins and can log any of them out. All logic lives in
// icfx (ListSessions/RevokeSession); these methods only adapt to the UI.

// ListCloudSessions returns the account's live sessions as JSON, newest
// activity first. The caller's own session carries "current": true.
func (s *CloudService) ListCloudSessions() (string, error) {
	ensurePathsApplied()
	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return "", err
	}
	sessions, err := c.ListSessions(ctx)
	if err != nil {
		return "", err
	}
	out, err := json.Marshal(sessions)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// RevokeCloudSession logs the identified device out. Revoking this device's
// own session is a logout — the UI warns before offering it.
func (s *CloudService) RevokeCloudSession(id string) error {
	ensurePathsApplied()
	ctx := context.Background()
	c, err := s.authedClient(ctx)
	if err != nil {
		return err
	}
	return c.RevokeSession(ctx, id)
}
