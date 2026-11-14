// Package config loads, validates and saves dialhome JSON configuration.
// Invariants enforced here (docs/CONFIG_SCHEMA.md):
//   - channel local/remote must start with "127.0.0.1:" (loopback-only, literal)
//   - at least one channel named "ssh"; channel names unique
//   - mode is persistent|temporary
//   - supervisor retry numbers sane
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const Version = 1

var (
	ErrLoopbackRequired = errors.New("channel addresses must be literal 127.0.0.1:<port>")
	ErrSSHChannelNeeded = errors.New("channels must contain one named \"ssh\"")
	ErrBadMode          = errors.New("mode must be persistent or temporary")
	ErrBadRetry         = errors.New("supervisor retry numbers are inconsistent")
)

type Channel struct {
	Name    string `json:"name"`
	Local   string `json:"local"`
	Remote  string `json:"remote"`
	Enabled bool   `json:"enabled"`
}

type RelayAddr struct {
	Address string `json:"address"`
	Port    int    `json:"port"`
	User    string `json:"user"`
}

type SSHD struct {
	Listen         string `json:"listen"`
	OpenSSHDir     string `json:"openssh_dir"`
	HostKey        string `json:"host_key"`
	AuthorizedKeys string `json:"authorized_keys"`
	Log            string `json:"log"`
	PidFile        string `json:"pid_file"`
}

type Retry struct {
	BaseSeconds    int `json:"base_seconds"`
	MaxSeconds     int `json:"max_seconds"`
	FailsToHourly  int `json:"fails_to_hourly"`
	HourlySeconds  int `json:"hourly_seconds"`
}

type Keepalive struct {
	IntervalSeconds int `json:"interval_seconds"`
	CountMax        int `json:"count_max"`
}

type Supervisor struct {
	BootWaitMaxSeconds int        `json:"boot_wait_max_seconds"`
	Retry              Retry      `json:"retry"`
	Keepalive          Keepalive  `json:"keepalive"`
	ConnectTimeout     int        `json:"connect_timeout_seconds"`
}

type Register struct {
	Enabled         bool `json:"enabled"`
	IntervalMinutes int  `json:"interval_minutes"`
}

type Node struct {
	Name      string   `json:"name"`
	Relay     RelayAddr `json:"relay"`
	SSHD      SSHD     `json:"sshd"`
	Channels  []Channel `json:"channels"`
	Mode      string   `json:"mode"`
	Register  Register `json:"register"`
}

type NodeConfig struct {
	ConfigVersion int        `json:"config_version"`
	Node          Node       `json:"node"`
	Supervisor    Supervisor `json:"supervisor"`
}

// Defaults returns the documented default configuration (CONFIG_SCHEMA §1).
func Defaults() *NodeConfig {
	return &NodeConfig{
		ConfigVersion: Version,
		Node: Node{
			Name:  "",
			Relay: RelayAddr{Address: "10.101.54.192", Port: 18322, User: "user"},
			SSHD: SSHD{
				Listen:         "127.0.0.1:19022",
				OpenSSHDir:     "openssh",
				HostKey:        "keys/host_ed25519",
				AuthorizedKeys: "keys/authorized_keys",
				Log:            "logs/sshd.log",
				PidFile:        "state/sshd.pid",
			},
			Channels: []Channel{
				{Name: "ssh", Local: "127.0.0.1:19022", Remote: "127.0.0.1:13441", Enabled: true},
				{Name: "application", Local: "127.0.0.1:3425", Remote: "127.0.0.1:13440", Enabled: false},
			},
			Mode:     "persistent",
			Register: Register{Enabled: true, IntervalMinutes: 30},
		},
		Supervisor: Supervisor{
			BootWaitMaxSeconds: 600,
			Retry:              Retry{BaseSeconds: 5, MaxSeconds: 60, FailsToHourly: 10, HourlySeconds: 3600},
			Keepalive:          Keepalive{IntervalSeconds: 15, CountMax: 3},
			ConnectTimeout:     10,
		},
	}
}

// Load reads and validates a config file.
func Load(path string) (*NodeConfig, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg NodeConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return nil, fmt.Errorf("config %s: %w", path, err)
	}
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("config %s: %w", path, err)
	}
	return &cfg, nil
}

// Save writes atomically (tmp in the same dir, then rename) with 0600.
func Save(path string, cfg *NodeConfig) error {
	if err := cfg.Validate(); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(raw); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, 0o600); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

// Validate enforces the documented invariants.
func (c *NodeConfig) Validate() error {
	if c.ConfigVersion > Version {
		return fmt.Errorf("config_version %d is newer than this build (%d)", c.ConfigVersion, Version)
	}
	if c.Node.Mode != "persistent" && c.Node.Mode != "temporary" {
		return fmt.Errorf("%w: got %q", ErrBadMode, c.Node.Mode)
	}
	if len(c.Node.Channels) == 0 {
		return ErrSSHChannelNeeded
	}
	hasSSH := false
	seen := map[string]bool{}
	for _, ch := range c.Node.Channels {
		if seen[ch.Name] {
			return fmt.Errorf("duplicate channel name %q", ch.Name)
		}
		seen[ch.Name] = true
		if err := checkLoopback(ch.Local); err != nil {
			return fmt.Errorf("channel %q local: %w", ch.Name, err)
		}
		if err := checkLoopback(ch.Remote); err != nil {
			return fmt.Errorf("channel %q remote: %w", ch.Name, err)
		}
		if ch.Name == "ssh" && ch.Enabled {
			hasSSH = true
		}
	}
	if !hasSSH {
		return ErrSSHChannelNeeded
	}
	s := c.Supervisor
	if s.Retry.BaseSeconds <= 0 || s.Retry.MaxSeconds < s.Retry.BaseSeconds ||
		s.Retry.FailsToHourly < 1 || s.Retry.HourlySeconds < s.Retry.MaxSeconds {
		return ErrBadRetry
	}
	if s.Keepalive.IntervalSeconds <= 0 || s.Keepalive.CountMax < 1 || s.ConnectTimeout <= 0 {
		return ErrBadRetry
	}
	return nil
}

func checkLoopback(addr string) error {
	const prefix = "127.0.0.1:"
	if len(addr) <= len(prefix) || addr[:len(prefix)] != prefix {
		return fmt.Errorf("%w: got %q", ErrLoopbackRequired, addr)
	}
	port := addr[len(prefix):]
	for _, r := range port {
		if r < '0' || r > '9' {
			return fmt.Errorf("%w: bad port %q", ErrLoopbackRequired, addr)
		}
	}
	return nil
}
