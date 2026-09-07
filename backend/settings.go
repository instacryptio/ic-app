package main

import (
	"encoding/json"
	"fmt"

	"github.com/instacryptio/icfx/config"
)

// GetSettings returns all config settings as a JSON string.
func (s *IcfxService) GetSettings() (string, error) {
	ensurePathsApplied()
	cfg, err := config.Load()
	if err != nil {
		return "", fmt.Errorf("loading config: %w", err)
	}

	settings := map[string]interface{}{
		"conf_path":         cfg.ConfPath,
		"data_path":         cfg.DataPath,
		"key_path":          cfg.KeyPath,
		"default_identity":  cfg.DefaultIdentity,
		"default_format":    cfg.DefaultFormat,
		"keystore":          cfg.Keystore,
		"verbose":           cfg.Verbose,
		"auto_lock_minutes": cfg.AutoLockMinutes,
		// Display only — writes go through CloudService.SetServerURL, which
		// handles the sign-out side effects of switching servers.
		"cloud_base_url": cfg.CloudBaseURL,
	}

	data, err := json.Marshal(settings)
	if err != nil {
		return "", fmt.Errorf("marshaling settings: %w", err)
	}
	return string(data), nil
}

// SetSetting updates a single config setting by key.
func (s *IcfxService) SetSetting(key, value string) (string, error) {
	ensurePathsApplied()
	cfg, err := config.Load()
	if err != nil {
		return "", fmt.Errorf("loading config: %w", err)
	}

	if err := cfg.Set(key, value); err != nil {
		return "", fmt.Errorf("invalid setting: %w", err)
	}

	if err := cfg.Save(); err != nil {
		return "", fmt.Errorf("saving config: %w", err)
	}

	// Re-apply path overrides so subsequent operations use new paths
	applyPathOverrides(cfg)

	return "Setting updated", nil
}
