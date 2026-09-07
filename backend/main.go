package main

import (
	"github.com/hkdb/flugo/pkg/bridge"
)

func init() {
	bridge.Bind(&IcfxService{})
	bridge.Bind(&CloudService{})
	startAutoLockWatcher()
	// Windows deep-link registration (no-op elsewhere; other platforms
	// register statically via `flugo deeplink`).
	_ = bridge.RegisterURLScheme("instacrypt")
}

func main() {}
