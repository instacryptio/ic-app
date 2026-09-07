//go:build android

package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"

	"github.com/hkdb/flugo/pkg/keyring"
	"github.com/instacryptio/icfx/cloud"
	ks "github.com/instacryptio/icfx/keystore"
)

const (
	keyringEncSuffix  = "-enc"
	keyringSignSuffix = "-sign"
	keyringIndexKey   = "_icfx_keyring_index"
)

// KeyringKeychainStore adapts flugo's keyring.Keyring to icfx's keystore.Keystore interface.
type KeyringKeychainStore struct {
	kr keyring.Keyring
}

// NewKeyringKeychainStore creates a Keystore backed by the platform keyring.
func NewKeyringKeychainStore(kr keyring.Keyring) ks.Keystore {
	return &KeyringKeychainStore{kr: kr}
}

func (s *KeyringKeychainStore) StoreEncryptionIdentity(name, identity string) error {
	if err := s.kr.Set(name+keyringEncSuffix, identity); err != nil {
		return fmt.Errorf("storing encryption identity in keyring: %w", err)
	}
	return s.addToIndex(name)
}

func (s *KeyringKeychainStore) LoadEncryptionIdentity(name string) (string, error) {
	val, err := s.kr.Get(name + keyringEncSuffix)
	if err != nil {
		return "", fmt.Errorf("loading encryption identity from keyring: %w", err)
	}
	return val, nil
}

func (s *KeyringKeychainStore) StoreSigningKey(name string, key []byte) error {
	encoded := base64.StdEncoding.EncodeToString(key)
	if err := s.kr.Set(name+keyringSignSuffix, encoded); err != nil {
		return fmt.Errorf("storing signing key in keyring: %w", err)
	}
	return s.addToIndex(name)
}

func (s *KeyringKeychainStore) LoadSigningKey(name string) ([]byte, error) {
	encoded, err := s.kr.Get(name + keyringSignSuffix)
	if err != nil {
		return nil, fmt.Errorf("loading signing key from keyring: %w", err)
	}
	return base64.StdEncoding.DecodeString(encoded)
}

func (s *KeyringKeychainStore) HasKeys(name string) bool {
	_, err1 := s.kr.Get(name + keyringEncSuffix)
	_, err2 := s.kr.Get(name + keyringSignSuffix)
	return err1 == nil && err2 == nil
}

func (s *KeyringKeychainStore) Clear(name string) error {
	_ = s.kr.Delete(name + keyringEncSuffix)
	_ = s.kr.Delete(name + keyringSignSuffix)
	return s.removeFromIndex(name)
}

func (s *KeyringKeychainStore) ListNames() ([]string, error) {
	data, err := s.kr.Get(keyringIndexKey)
	if err != nil {
		return []string{}, nil
	}
	var names []string
	if err := json.Unmarshal([]byte(data), &names); err != nil {
		return []string{}, nil
	}
	return names, nil
}

func (s *KeyringKeychainStore) addToIndex(name string) error {
	names, _ := s.ListNames()
	for _, n := range names {
		if n == name {
			return nil
		}
	}
	names = append(names, name)
	data, err := json.Marshal(names)
	if err != nil {
		return err
	}
	return s.kr.Set(keyringIndexKey, string(data))
}

func (s *KeyringKeychainStore) removeFromIndex(name string) error {
	names, _ := s.ListNames()
	filtered := make([]string, 0, len(names))
	for _, n := range names {
		if n != name {
			filtered = append(filtered, n)
		}
	}
	data, err := json.Marshal(filtered)
	if err != nil {
		return err
	}
	return s.kr.Set(keyringIndexKey, string(data))
}

// androidKeyringStore returns the keychain store roamed identities land in on
// Android: the platform Keystore via the flugo keyring when available, nil
// (icfx default — non-functional here) otherwise, in which case the caller
// falls back to the file backend anyway.
func androidKeyringStore() ks.Keystore {
	kr := keyring.New()
	if !kr.Available() {
		return nil
	}
	return NewKeyringKeychainStore(kr)
}

// keyringEncKeyStore persists the cloud account encryption key in the
// Android Keystore (via the flugo keyring) — same hardware-backed store the
// identity keys use, so no passphrase file and no unlock prompt.
type keyringEncKeyStore struct {
	kr keyring.Keyring
}

func keyringEncKeyStoreIfAvailable() cloud.EncKeyStore {
	kr := keyring.New()
	if !kr.Available() {
		return nil
	}
	return &keyringEncKeyStore{kr: kr}
}

func keyringEncKeyEntry(email string) string { return "cloud-enckey:" + email }

func (s *keyringEncKeyStore) Save(email string, encKey []byte) error {
	return s.kr.Set(keyringEncKeyEntry(email), base64.StdEncoding.EncodeToString(encKey))
}

func (s *keyringEncKeyStore) Load(email string) ([]byte, error) {
	val, err := s.kr.Get(keyringEncKeyEntry(email))
	if err != nil {
		return nil, fmt.Errorf("keyring enc key: %w", cloud.ErrEncKeyMissing)
	}
	decoded, err := base64.StdEncoding.DecodeString(val)
	if err != nil {
		return nil, fmt.Errorf("decoding keyring enc key: %w", cloud.ErrEncKeyMissing)
	}
	return decoded, nil
}

func (s *keyringEncKeyStore) Clear(email string) error {
	return s.kr.Delete(keyringEncKeyEntry(email))
}

// keyringTokenBackend persists the cloud session tokens in the Android Keystore
// (via the flugo keyring) — the same hardware-backed store the encKey and
// identity keys use, so tokens are never a plaintext file and need no unlock.
type keyringTokenBackend struct {
	kr keyring.Keyring
}

func keyringTokenBackendIfAvailable() cloud.TokenBackend {
	kr := keyring.New()
	if !kr.Available() {
		return nil
	}
	return &keyringTokenBackend{kr: kr}
}

func keyringTokenEntry(email string) string { return "cloud-tokens:" + email }

func (s *keyringTokenBackend) SaveTokens(email string, t *cloud.Tokens) error {
	raw, err := json.Marshal(t)
	if err != nil {
		return err
	}
	return s.kr.Set(keyringTokenEntry(email), base64.StdEncoding.EncodeToString(raw))
}

func (s *keyringTokenBackend) LoadTokens(email string) (*cloud.Tokens, error) {
	val, err := s.kr.Get(keyringTokenEntry(email))
	if err != nil {
		return nil, cloud.ErrNoSession
	}
	raw, err := base64.StdEncoding.DecodeString(val)
	if err != nil {
		return nil, fmt.Errorf("decoding keyring tokens: %w", err)
	}
	var t cloud.Tokens
	if err := json.Unmarshal(raw, &t); err != nil {
		return nil, fmt.Errorf("keyring token entry corrupt: %w", err)
	}
	return &t, nil
}

func (s *keyringTokenBackend) HasTokens(email string) bool {
	_, err := s.kr.Get(keyringTokenEntry(email))
	return err == nil
}

func (s *keyringTokenBackend) ClearTokens(email string) error {
	return s.kr.Delete(keyringTokenEntry(email))
}
