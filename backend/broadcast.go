package main

import (
	"context"
	"time"

	"github.com/instacryptio/icfx/bundle"
	"github.com/instacryptio/icfx/cloud"
	"github.com/instacryptio/icfx/crypto"
)

// keySigner signs with a raw ML-DSA-65 private key — used to seal rotation and
// revocation bundles with the key being rotated away from.
type keySigner struct{ key []byte }

func (k keySigner) Sign(data []byte) ([]byte, error) { return crypto.Sign(data, k.key) }

// broadcastRotationToCloud posts a signed rotation to every cloud contact,
// best-effort: if the user isn't signed in it returns an empty report (the
// change is still recorded locally; contacts learn of it out-of-band). Returns
// the report so the caller can surface how many contacts were notified.
func broadcastRotationToCloud(rot bundle.RotationBundle) cloud.BroadcastReport {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	c, err := (&CloudService{}).authedClient(ctx)
	if err != nil {
		return cloud.BroadcastReport{}
	}
	store, err := newContactStore()
	if err != nil {
		return cloud.BroadcastReport{}
	}
	rep, _ := cloud.BroadcastRotation(ctx, c, store, rot)
	return rep
}

// broadcastRevocationToCloud is the revocation counterpart.
func broadcastRevocationToCloud(rev bundle.RevocationBundle) cloud.BroadcastReport {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	c, err := (&CloudService{}).authedClient(ctx)
	if err != nil {
		return cloud.BroadcastReport{}
	}
	store, err := newContactStore()
	if err != nil {
		return cloud.BroadcastReport{}
	}
	rep, _ := cloud.BroadcastRevocation(ctx, c, store, rev)
	return rep
}
