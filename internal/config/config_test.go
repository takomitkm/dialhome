package config

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestValidateDefaults(t *testing.T) {
	if err := Defaults().Validate(); err != nil {
		t.Fatalf("defaults must validate: %v", err)
	}
}

func TestLoopbackLiteralRequired(t *testing.T) {
	for _, bad := range []string{"localhost:19022", "0.0.0.0:19022", "127.0.0.1:", "127.0.0.1:abc", "192.168.1.5:19022"} {
		cfg := Defaults()
		cfg.Node.Channels[0].Local = bad
		if err := cfg.Validate(); !errors.Is(err, ErrLoopbackRequired) {
			t.Fatalf("local %q: want ErrLoopbackRequired, got %v", bad, err)
		}
	}
	// remote side too
	cfg := Defaults()
	cfg.Node.Channels[0].Remote = "0.0.0.0:13441"
	if err := cfg.Validate(); !errors.Is(err, ErrLoopbackRequired) {
		t.Fatalf("remote 0.0.0.0 must be rejected, got %v", err)
	}
}

func TestSSHChannelRequired(t *testing.T) {
	cfg := Defaults()
	cfg.Node.Channels[0].Enabled = false
	if err := cfg.Validate(); !errors.Is(err, ErrSSHChannelNeeded) {
		t.Fatalf("want ErrSSHChannelNeeded, got %v", err)
	}
	cfg2 := Defaults()
	cfg2.Node.Channels = cfg2.Node.Channels[1:] // only application
	if err := cfg2.Validate(); !errors.Is(err, ErrSSHChannelNeeded) {
		t.Fatalf("ssh-only-missing must fail, got %v", err)
	}
}

func TestModeRestricted(t *testing.T) {
	cfg := Defaults()
	cfg.Node.Mode = "system-wide"
	if err := cfg.Validate(); !errors.Is(err, ErrBadMode) {
		t.Fatalf("want ErrBadMode, got %v", err)
	}
}

func TestRetrySanity(t *testing.T) {
	cfg := Defaults()
	cfg.Supervisor.Retry.BaseSeconds = 0
	if err := cfg.Validate(); !errors.Is(err, ErrBadRetry) {
		t.Fatalf("zero base must fail, got %v", err)
	}
	cfg2 := Defaults()
	cfg2.Supervisor.Retry.MaxSeconds = 7200 // above hourly
	if err := cfg2.Validate(); !errors.Is(err, ErrBadRetry) {
		t.Fatalf("max above hourly must fail, got %v", err)
	}
}

func TestSaveLoadRoundTrip(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "config.json")
	cfg := Defaults()
	cfg.Node.Name = "hp66"
	if err := Save(p, cfg); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("saved perms = %v, want 0600", st.Mode().Perm())
	}
	got, err := Load(p)
	if err != nil {
		t.Fatal(err)
	}
	if got.Node.Name != "hp66" || got.Node.Channels[0].Remote != "127.0.0.1:13441" {
		t.Fatalf("round trip mismatch: %+v", got.Node)
	}
	// atomic-write leaves no tmp litter
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.Contains(e.Name(), ".tmp-") {
			t.Fatalf("temp litter left behind: %s", e.Name())
		}
	}
}

func TestNewerVersionRejected(t *testing.T) {
	body := `{"config_version": 99, "node": {"mode": "persistent"}}`
	if _, err := Load(write(t, body)); err == nil {
		t.Fatal("newer config_version must be rejected")
	}
}
