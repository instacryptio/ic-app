package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/instacryptio/icfx/contacts"
	"github.com/instacryptio/icfx/groups"
	"github.com/instacryptio/icfx/validate"
)

const maxGroupNameLen = 256

// newGroupStore constructs the contact-groups store, applying any pending path
// overrides first (same guard every store constructor uses).
func newGroupStore() (*groups.Store, error) {
	return newStore(groups.NewStore, "group")
}

// groupMemberJSON / groupJSON are the shapes returned to the Dart UI. Members
// are resolved to their current contact aliases; dangling IDs (a member whose
// contact was deleted) are omitted.
type groupMemberJSON struct {
	ID    string `json:"id"`
	Alias string `json:"alias"`
}

type groupJSON struct {
	ID          string            `json:"id"`
	Name        string            `json:"name"`
	Members     []groupMemberJSON `json:"members"`
	MemberCount int               `json:"member_count"`
}

// ListGroups returns all groups with their members resolved to contact aliases.
func (s *IcfxService) ListGroups() (string, error) {
	gs, err := newGroupStore()
	if err != nil {
		return "", err
	}
	list, err := gs.List()
	if err != nil {
		return "", fmt.Errorf("loading groups: %w", err)
	}

	contactStore, err := newContactStore()
	if err != nil {
		return "", err
	}
	contactList, err := contactStore.Load()
	if err != nil {
		contactList = []contacts.Contact{}
	}

	out := make([]groupJSON, 0, len(list))
	for _, g := range list {
		members := make([]groupMemberJSON, 0, len(g.MemberIDs))
		for _, mid := range g.MemberIDs {
			c, cerr := contacts.FindByID(contactList, mid)
			if cerr != nil {
				continue // dangling member (contact deleted) — skip
			}
			members = append(members, groupMemberJSON{ID: mid, Alias: c.Alias})
		}
		out = append(out, groupJSON{ID: g.ID, Name: g.Name, Members: members, MemberCount: len(members)})
	}

	data, err := json.Marshal(out)
	if err != nil {
		return "", fmt.Errorf("marshaling groups: %w", err)
	}
	return string(data), nil
}

// AddGroup creates a group from a name and a set of member contact aliases.
func (s *IcfxService) AddGroup(name string, memberAliases []string) (string, error) {
	name, err := validateGroupName(name)
	if err != nil {
		return "", err
	}
	memberIDs, err := s.resolveMembers(memberAliases)
	if err != nil {
		return "", err
	}
	gs, err := newGroupStore()
	if err != nil {
		return "", err
	}
	if _, err := gs.Add(name, memberIDs); err != nil {
		if errors.Is(err, groups.ErrAlreadyExists) {
			return "", fmt.Errorf("a group named %q already exists", name)
		}
		return "", fmt.Errorf("adding group: %w", err)
	}
	return "Group added", nil
}

// EditGroup updates a group's name and members.
func (s *IcfxService) EditGroup(id, name string, memberAliases []string) (string, error) {
	name, err := validateGroupName(name)
	if err != nil {
		return "", err
	}
	memberIDs, err := s.resolveMembers(memberAliases)
	if err != nil {
		return "", err
	}
	gs, err := newGroupStore()
	if err != nil {
		return "", err
	}
	if err := gs.Edit(id, name, memberIDs); err != nil {
		if errors.Is(err, groups.ErrNotFound) {
			return "", fmt.Errorf("group not found")
		}
		return "", fmt.Errorf("updating group: %w", err)
	}
	return "Group updated", nil
}

// RemoveGroup deletes a group by ID.
func (s *IcfxService) RemoveGroup(id string) (string, error) {
	gs, err := newGroupStore()
	if err != nil {
		return "", err
	}
	if err := gs.Remove(id); err != nil {
		if errors.Is(err, groups.ErrNotFound) {
			return "", fmt.Errorf("group not found")
		}
		return "", fmt.Errorf("removing group: %w", err)
	}
	return "Group removed", nil
}

func validateGroupName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", fmt.Errorf("group name is required")
	}
	if len(name) > maxGroupNameLen {
		return "", fmt.Errorf("group name too long (max %d characters)", maxGroupNameLen)
	}
	if err := validate.ValidateNoControlChars("group name", name); err != nil {
		return "", err
	}
	return name, nil
}

// resolveMembers maps member contact aliases to their stable contact IDs,
// deduping. A contact that has no ID yet (manually-added contacts start
// without one) is assigned a stable ID, which is persisted so groups can
// reference it reliably across renames.
func (s *IcfxService) resolveMembers(memberAliases []string) ([]string, error) {
	contactStore, err := newContactStore()
	if err != nil {
		return nil, err
	}
	contactList, err := contactStore.Load()
	if err != nil {
		return nil, fmt.Errorf("loading contacts: %w", err)
	}

	ids := make([]string, 0, len(memberAliases))
	seen := map[string]struct{}{}
	assigned := false
	for _, alias := range memberAliases {
		c, ferr := contacts.FindByAlias(contactList, alias)
		if ferr != nil {
			return nil, fmt.Errorf("contact %q not found", alias)
		}
		if contacts.EnsureID(c) { // mutates the slice element in place
			assigned = true
		}
		if _, dup := seen[c.ID]; dup {
			continue
		}
		seen[c.ID] = struct{}{}
		ids = append(ids, c.ID)
	}
	if assigned {
		if err := contactStore.Save(contactList); err != nil {
			return nil, fmt.Errorf("persisting contact ids: %w", err)
		}
	}
	return ids, nil
}
