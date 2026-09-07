package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	icBundle "github.com/instacryptio/icfx/bundle"
	"github.com/instacryptio/icfx/contacts"
	"github.com/instacryptio/icfx/crypto"
	"github.com/instacryptio/icfx/format"
	"github.com/instacryptio/icfx/qr"
	"github.com/instacryptio/icfx/validate"
)

// Animated QR frame accumulation state (any-order, restart-on-new-bundle).
// A stale collection is discarded after frameCollectTTL so an abandoned
// half-scan never blocks the next one.
var (
	frameCollector = qr.NewFrameCollector()
	frameLastAdd   time.Time
	frameMu        sync.Mutex
)

const frameCollectTTL = 2 * time.Minute

// ListContacts returns the contact list as a JSON string. Contacts are now
// stored plaintext (mode 0600), so no unlock is needed.
func (s *IcfxService) ListContacts() (string, error) {
	contactStore, err := newContactStore()
	if err != nil {
		return "", err
	}
	contactList, err := contactStore.Load()
	if err != nil {
		return "", fmt.Errorf("loading contacts: %w", err)
	}

	data, err := json.Marshal(contactList)
	if err != nil {
		return "", fmt.Errorf("marshaling contacts: %w", err)
	}

	return string(data), nil
}

// AddContact adds a new contact manually. The fingerprint is always RECOMPUTED
// from the entered keys (never trusted from input) so it truly identifies those
// keys — the fingerprint parameter is ignored and the UI no longer collects it.
func (s *IcfxService) AddContact(alias, nickname, firstName, lastName, email, encPubKey, signPubKey, fingerprint string) (string, error) {
	computedFP, err := recomputeFingerprint(encPubKey, signPubKey)
	if err != nil {
		return "", err
	}
	// Alias = the contact's own public handle; Nickname = your local shortcut.
	// Both are typeable recipient selectors → alias charset (lowercase word).
	alias = strings.ToLower(strings.TrimSpace(alias))
	nickname = strings.ToLower(strings.TrimSpace(nickname))
	if err := validate.Alias(alias); err != nil {
		return "", fmt.Errorf("alias: %w", err)
	}
	if err := validate.Alias(nickname); err != nil {
		return "", fmt.Errorf("nickname: %w", err)
	}
	if err := validate.ValidateContactFields(alias, encPubKey, signPubKey, computedFP, email, nickname); err != nil {
		return "", err
	}
	if err := contactCapError(1); err != nil {
		return "", err
	}

	contact := contacts.Contact{
		Alias:       alias,
		Nickname:    nickname,
		FirstName:   firstName,
		LastName:    lastName,
		Email:       email,
		EncPubKey:   encPubKey,
		SignPubKey:  signPubKey,
		Fingerprint: computedFP,
		AddedAt:     time.Now(),
	}

	contactStore, err := newContactStore()
	if err != nil {
		return "", err
	}
	existing, err := contactStore.Load()
	if err != nil {
		existing = []contacts.Contact{}
	}

	if _, err := contactStore.Add(contact, existing); err != nil {
		return "", fmt.Errorf("adding contact: %w", err)
	}

	return "Contact added", nil
}

// ImportLockFile imports a contact from a lock, revocation, or rotation file.
// Returns the import outcome JSON (action/applied/token/fingerprints) for the
// Flutter UI to apply or prompt on.
func (s *IcfxService) ImportLockFile(filePath, alias string) (string, error) {
	raw, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("reading file: %w", err)
	}

	return s.processImportData(raw, alias)
}

// ImportLockQR imports a contact from QR code data.
// Returns the import outcome JSON (see ImportLockFile) for the Flutter UI.
func (s *IcfxService) ImportLockQR(qrData, alias string) (string, error) {
	return s.processImportData([]byte(qrData), alias)
}

// recomputeFingerprint derives the fingerprint from a contact's entered
// public keys so it is bound to the actual keys rather than typed by hand.
func recomputeFingerprint(encPubKey, signPubKey string) (string, error) {
	var signBytes []byte
	if signPubKey != "" {
		b, err := base64.StdEncoding.DecodeString(signPubKey)
		if err != nil {
			return "", fmt.Errorf("invalid signing lock: %w", err)
		}
		signBytes = b
	}
	return crypto.Fingerprint(encPubKey, signBytes), nil
}

// pendingImport is a cached import awaiting user confirmation, tagged with a
// one-time correlation token. ConfirmContactImport must present the matching
// token so a second import that overwrote the cache can't cause the wrong
// change to be applied.
type pendingImport struct {
	result *icBundle.ImportResult
	token  string
}

// lastImport caches the most recent import awaiting confirmation.
// Guarded by importResultMu — bridge calls run on separate isolates and are
// not serialized, so concurrent imports/confirms would otherwise race it.
var (
	lastImport     *pendingImport
	importResultMu sync.Mutex
)

// newImportToken returns a random hex token correlating an import prompt with
// its later confirmation.
func newImportToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generating import token: %w", err)
	}
	return hex.EncodeToString(b), nil
}

// importOutcome is the uniform result shape returned to the Flutter UI for
// every import. ActionAdd is applied immediately (Applied=true, no Token);
// ActionUpdate/ActionRevoke carry a Token the UI echoes back to
// ConfirmContactImport after the user confirms. Fingerprints are grouped for
// out-of-band verification in the confirm dialog.
type importOutcome struct {
	Action         int    `json:"action"`
	Applied        bool   `json:"applied"`
	Token          string `json:"token,omitempty"`
	Name           string `json:"name,omitempty"`
	Message        string `json:"message"`
	OldFingerprint string `json:"oldFingerprint,omitempty"`
	NewFingerprint string `json:"newFingerprint,omitempty"`
}

// marshalOutcome serializes an importOutcome to the JSON string the bridge
// returns.
func marshalOutcome(o importOutcome) (string, error) {
	data, err := json.Marshal(o)
	if err != nil {
		return "", fmt.Errorf("marshaling import result: %w", err)
	}
	return string(data), nil
}

// verifyImportBundle authenticates a parsed bundle before it is applied or
// cached for confirmation. A revocation for an unknown contact is
// informational (nothing to apply) and needs no signature check.
func verifyImportBundle(parsed *icBundle.ParsedBundle, result *icBundle.ImportResult) error {
	switch result.Action {
	case icBundle.ActionAdd:
		return icBundle.VerifyLockForAdd(parsed)
	case icBundle.ActionUpdate:
		if parsed.Type == icBundle.BundleRotate {
			return icBundle.VerifyRotation(parsed, result.Contact)
		}
		return icBundle.VerifyLockForAdd(parsed)
	case icBundle.ActionRevoke:
		if result.Contact == nil {
			return nil
		}
		return icBundle.VerifyRevocation(parsed, result.Contact)
	}
	return nil
}

// processImportData parses bundle data and returns the import result as JSON.
func (s *IcfxService) processImportData(data []byte, alias string) (string, error) {
	parsed, err := icBundle.Parse(data)
	if err != nil {
		return "", fmt.Errorf("parsing bundle: %w", err)
	}

	contactStore, err := newContactStore()
	if err != nil {
		return "", err
	}
	existing, err := contactStore.Load()
	if err != nil {
		existing = []contacts.Contact{}
	}

	result, err := icBundle.ProcessImport(parsed, existing)
	if err != nil {
		return "", fmt.Errorf("invalid bundle: %w", err)
	}

	// Authenticate before caching/prompting: a first-contact lock by its
	// self-signature, a key update by rotation continuity (or the new lock's
	// self-sig), a revocation by the revoked key. An unauthenticated bundle is
	// rejected here and never reaches the confirm prompt.
	if verr := verifyImportBundle(parsed, result); verr != nil {
		return "", fmt.Errorf("this bundle could not be authenticated and was rejected: %w", verr)
	}

	// ActionAdd — apply immediately (no confirmation needed).
	if result.Action == icBundle.ActionAdd && result.NewKeys != nil {
		if err := contactCapError(1); err != nil {
			return "", err
		}
		// Alias is the publisher's own handle from the lock (fallback to their
		// name). The caller-supplied `alias` arg is the user's LOCAL shortcut →
		// stored as Nickname.
		contactAlias := result.NewKeys.Alias
		if contactAlias == "" {
			contactAlias = result.NewKeys.Name
		}
		contact := contacts.Contact{
			ID:          result.NewKeys.ID,
			Alias:       contactAlias,
			Nickname:    alias,
			Email:       result.NewKeys.Email,
			EncPubKey:   result.NewKeys.EncPubKey,
			SignPubKey:  result.NewKeys.SignPubKey,
			Fingerprint: result.NewKeys.Fingerprint,
			AddedAt:     time.Now(),
		}
		if _, err := contactStore.Add(contact, existing); err != nil {
			return "", fmt.Errorf("adding contact: %w", err)
		}
		return marshalOutcome(importOutcome{
			Action:  int(result.Action),
			Applied: true,
			Name:    contactAlias,
			Message: result.Message,
		})
	}

	// A revocation for an unknown contact is informational — nothing to apply
	// and nothing to confirm.
	if result.Action == icBundle.ActionRevoke && result.Contact == nil {
		return marshalOutcome(importOutcome{
			Action:  int(result.Action),
			Applied: false,
			Message: result.Message,
		})
	}

	// ActionUpdate / ActionRevoke of a known contact — cache under a one-time
	// token and prompt for confirmation. The token guards against a second
	// import overwriting the cache before the user confirms this one.
	token, err := newImportToken()
	if err != nil {
		return "", err
	}
	importResultMu.Lock()
	lastImport = &pendingImport{result: result, token: token}
	importResultMu.Unlock()

	out := importOutcome{
		Action:  int(result.Action),
		Applied: false,
		Token:   token,
		Name:    result.Contact.Alias,
		Message: result.Message,
	}
	out.OldFingerprint = crypto.FormatGrouped(result.Contact.Fingerprint)
	if result.Action == icBundle.ActionUpdate && result.NewKeys != nil {
		out.NewFingerprint = crypto.FormatGrouped(result.NewKeys.Fingerprint)
	}
	return marshalOutcome(out)
}

// ConfirmContactImport applies the cached import result after user
// confirmation. The token must match the one handed out with the prompt, so a
// second import that overwrote the cache can't cause the wrong change to apply.
func (s *IcfxService) ConfirmContactImport(token string) (string, error) {
	importResultMu.Lock()
	pending := lastImport
	lastImport = nil
	importResultMu.Unlock()
	if pending == nil || token == "" || token != pending.token {
		return "", fmt.Errorf("pending import expired — re-scan or re-import")
	}
	result := pending.result

	contactStore, err := newContactStore()
	if err != nil {
		return "", err
	}
	existing, err := contactStore.Load()
	if err != nil {
		return "", fmt.Errorf("loading contacts: %w", err)
	}

	switch result.Action {
	case icBundle.ActionUpdate:
		if result.Contact == nil || result.NewKeys == nil {
			return "", fmt.Errorf("invalid update result")
		}
		// Find the contact again in the freshly loaded list
		c, err := contacts.FindByAlias(existing, result.Contact.Alias)
		if err != nil {
			return "", fmt.Errorf("contact %q not found", result.Contact.Alias)
		}
		icBundle.ApplyUpdate(c, result.NewKeys)
		if err := contactStore.Save(existing); err != nil {
			return "", fmt.Errorf("saving contacts: %w", err)
		}
		return "Contact updated", nil

	case icBundle.ActionRevoke:
		if result.Contact == nil {
			return "", fmt.Errorf("no contact to revoke")
		}
		c, err := contacts.FindByAlias(existing, result.Contact.Alias)
		if err != nil {
			return "", fmt.Errorf("contact %q not found", result.Contact.Alias)
		}
		icBundle.ApplyRevoke(c)
		if err := contactStore.Save(existing); err != nil {
			return "", fmt.Errorf("saving contacts: %w", err)
		}
		return "Contact keys revoked", nil
	}

	return "", fmt.Errorf("unknown action")
}

// ShowContact returns a single contact's details as a JSON string.
func (s *IcfxService) ShowContact(alias string) (string, error) {
	contactStore, err := newContactStore()
	if err != nil {
		return "", err
	}
	contactList, err := contactStore.Load()
	if err != nil {
		return "", fmt.Errorf("loading contacts: %w", err)
	}

	c, err := contacts.FindByAlias(contactList, alias)
	if err != nil {
		return "", fmt.Errorf("contact %q not found", alias)
	}

	data, err := json.Marshal(c)
	if err != nil {
		return "", fmt.Errorf("marshaling contact: %w", err)
	}

	return string(data), nil
}

// EditContact updates an existing contact's metadata.
func (s *IcfxService) EditContact(alias, nickname, firstName, lastName, email, encPubKey, signPubKey, fingerprint string) (string, error) {
	contactStore, err := newContactStore()
	if err != nil {
		return "", err
	}
	contactList, err := contactStore.Load()
	if err != nil {
		return "", fmt.Errorf("loading contacts: %w", err)
	}

	c, err := contacts.FindByAlias(contactList, alias)
	if err != nil {
		return "", fmt.Errorf("contact %q not found", alias)
	}

	computedFP, err := recomputeFingerprint(encPubKey, signPubKey)
	if err != nil {
		return "", err
	}
	// Nickname is your local shortcut — a typeable selector, so alias charset.
	nickname = strings.ToLower(strings.TrimSpace(nickname))
	if err := validate.Alias(nickname); err != nil {
		return "", fmt.Errorf("nickname: %w", err)
	}
	c.Nickname = nickname
	c.FirstName = firstName
	c.LastName = lastName
	c.Email = email
	c.EncPubKey = encPubKey
	c.SignPubKey = signPubKey
	c.Fingerprint = computedFP // always bound to the keys, never typed

	if err := contactStore.Save(contactList); err != nil {
		return "", fmt.Errorf("saving contacts: %w", err)
	}

	return "Contact updated", nil
}

// RemoveContact removes a contact by alias.
func (s *IcfxService) RemoveContact(alias string) (string, error) {
	contactStore, err := newContactStore()
	if err != nil {
		return "", err
	}
	contactList, err := contactStore.Load()
	if err != nil {
		return "", fmt.Errorf("loading contacts: %w", err)
	}

	if _, err := contactStore.Remove(alias, contactList); err != nil {
		return "", fmt.Errorf("removing contact: %w", err)
	}

	return "Contact removed", nil
}

// ExportContactLock exports a contact's public keys as an armored lock string.
func (s *IcfxService) ExportContactLock(alias string) (string, error) {
	contactStore, err := newContactStore()
	if err != nil {
		return "", err
	}
	contactList, err := contactStore.Load()
	if err != nil {
		return "", fmt.Errorf("loading contacts: %w", err)
	}

	c, err := contacts.FindByAlias(contactList, alias)
	if err != nil {
		return "", fmt.Errorf("contact %q not found", alias)
	}

	bundle := qr.LockBundle{
		Name:        c.Alias,
		EncPubKey:   c.EncPubKey,
		SignPubKey:  c.SignPubKey,
		Fingerprint: c.Fingerprint,
		Email:       c.Email,
		Alias:       c.Alias,
	}

	data, err := json.MarshalIndent(bundle, "", "  ")
	if err != nil {
		return "", fmt.Errorf("marshaling lock: %w", err)
	}

	armored := format.ArmorEncode(data, format.ArmorLockLabel)
	return string(armored), nil
}

// ExportContactLockQR exports a contact's public keys as a base64-encoded
// animated QR code GIF (looping multi-frame sequence).
func (s *IcfxService) ExportContactLockQR(alias string) (string, error) {
	contactStore, err := newContactStore()
	if err != nil {
		return "", err
	}
	contactList, err := contactStore.Load()
	if err != nil {
		return "", fmt.Errorf("loading contacts: %w", err)
	}

	c, err := contacts.FindByAlias(contactList, alias)
	if err != nil {
		return "", fmt.Errorf("contact %q not found", alias)
	}

	bundle := qr.LockBundle{
		Name:        c.Alias,
		EncPubKey:   c.EncPubKey,
		SignPubKey:  c.SignPubKey,
		Fingerprint: c.Fingerprint,
		Email:       c.Email,
		Alias:       c.Alias,
	}

	gifBytes, err := qr.GenerateAnimatedQRGIF(bundle, 512, qr.DefaultFrameDelay)
	if err != nil {
		return "", fmt.Errorf("generating animated QR code: %w", err)
	}

	return base64.StdEncoding.EncodeToString(gifBytes), nil
}

// ImportLockQRPart ingests one scanned QR payload and returns a JSON result.
// It accepts animated frames (v1 format) and raw single-QR bundles. Returns
// {"complete":false,"received":r,"total":n} while frames are still missing,
// or {"complete":true,"received":n,"total":n,"result":{...}} once the bundle
// is assembled, where "result" is the same import outcome processImportData
// returns (action/applied/token/fingerprints for a confirm prompt).
func (s *IcfxService) ImportLockQRPart(partJSON, alias string) (string, error) {
	if qr.ClassifyPayload([]byte(partJSON)) == qr.PayloadFrame {
		return s.importAnimatedFrame(partJSON, alias)
	}

	// Raw single-QR bundle.
	result, err := s.processImportData([]byte(partJSON), alias)
	if err != nil {
		return "", err
	}
	return qrImportResponse(true, 1, 1, result)
}

// importAnimatedFrame feeds one animated QR frame into the shared collector
// and imports the contact once every frame has arrived.
func (s *IcfxService) importAnimatedFrame(frameJSON, alias string) (string, error) {
	progress, bundleJSON, complete, err := accumulateFrame(frameJSON)
	if err != nil {
		return "", err
	}
	if !complete {
		return qrImportResponse(false, progress.Received, progress.Total, "")
	}
	result, err := s.processImportData(bundleJSON, alias)
	if err != nil {
		return "", err
	}
	return qrImportResponse(true, progress.Total, progress.Total, result)
}

// accumulateFrame adds one frame to the shared collector under frameMu and,
// once complete, returns the reassembled bundle JSON. Holding frameMu across
// the whole sequence (TTL-reset decision → Add → Bundle → Reset) is what makes
// it correct under concurrent frame scans — otherwise one call's Reset could
// land between another's Add and Bundle. processImportData runs OUTSIDE this
// lock (it does I/O and takes its own locks).
func accumulateFrame(frameJSON string) (progress qr.Progress, bundleJSON []byte, complete bool, err error) {
	frameMu.Lock()
	defer frameMu.Unlock()

	if time.Since(frameLastAdd) > frameCollectTTL {
		frameCollector.Reset()
	}
	frameLastAdd = time.Now()

	progress, err = frameCollector.Add([]byte(frameJSON))
	if err != nil {
		return qr.Progress{}, nil, false, fmt.Errorf("scanning frame: %w", err)
	}
	if progress.Received < progress.Total {
		return progress, nil, false, nil
	}

	bundle, err := frameCollector.Bundle()
	if err != nil {
		frameCollector.Reset()
		return qr.Progress{}, nil, false, fmt.Errorf("reassembling animated QR: %w", err)
	}
	frameCollector.Reset()

	bundleJSON, err = qr.MarshalLockBundle(bundle)
	if err != nil {
		return qr.Progress{}, nil, false, fmt.Errorf("marshaling reassembled bundle: %w", err)
	}
	return progress, bundleJSON, true, nil
}

// qrImportResponse marshals the ImportLockQRPart result JSON. Progress frames
// return {"complete":false,"received":r,"total":n}; once the bundle is
// assembled the import outcome rides in a nested "result" object (the same
// shape processImportData returns) rather than being stuffed into a string.
func qrImportResponse(complete bool, received, total int, resultJSON string) (string, error) {
	resp := map[string]interface{}{
		"complete": complete,
		"received": received,
		"total":    total,
	}
	if resultJSON != "" {
		resp["result"] = json.RawMessage(resultJSON)
	}
	data, err := json.Marshal(resp)
	if err != nil {
		return "", fmt.Errorf("marshaling QR import response: %w", err)
	}
	return string(data), nil
}
