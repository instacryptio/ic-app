//go:build integration

// Concurrency stress: bridge methods run on separate isolates and are not
// serialized, so the guarded package globals (sessionPass, lastImportResult,
// frameCollector) must survive concurrent access. Run under -race; the test
// asserts only no data race / no panic, not logical outcomes.
package main

import (
	"sync"
	"testing"

	"github.com/instacryptio/icfx/qr"
)

func TestConcurrentSessionAndFrameAccess(t *testing.T) {
	ic := setupLocalEnv(t)
	resetQRImportState()

	frames, err := qr.MarshalAnimatedQR(testLockBundle(t, "conc"))
	if err != nil {
		t.Fatal(err)
	}

	const iters = 200
	var wg sync.WaitGroup

	// Readers of sessionPass (IsUnlocked) racing the writers below.
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < iters; i++ {
				_, _ = ic.IsUnlocked()
			}
		}()
	}
	// Writers of sessionPass.
	for g := 0; g < 4; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < iters; i++ {
				cachePassphrase([]byte("pass"))
				clearSessionPass()
			}
		}()
	}
	// Concurrent animated-frame imports hammering the shared collector.
	for g := 0; g < 6; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < iters; i++ {
				_, _ = ic.ImportLockQRPart(string(frames[i%len(frames)]), "")
			}
		}()
	}
	// Concurrent confirm/import-result access.
	for g := 0; g < 4; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < iters; i++ {
				_, _ = ic.ConfirmContactImport("")
			}
		}()
	}

	wg.Wait()
}
