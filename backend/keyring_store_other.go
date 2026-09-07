//go:build !android

package main

import (
	"github.com/instacryptio/icfx/cloud"
	ks "github.com/instacryptio/icfx/keystore"
)

// androidKeyringStore: desktop platforms use icfx's native keychain — nil selects
// the default inside the roaming functions.
func androidKeyringStore() ks.Keystore { return nil }

// keyringEncKeyStoreIfAvailable: the Android Keystore encKey store does not
// exist off-Android; nil falls through to the keychain/file selection.
func keyringEncKeyStoreIfAvailable() cloud.EncKeyStore { return nil }

// keyringTokenBackendIfAvailable: the Android Keystore token backend does not
// exist off-Android; nil falls through to the keychain/file selection.
func keyringTokenBackendIfAvailable() cloud.TokenBackend { return nil }
