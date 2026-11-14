package logging

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRedactCoversContractShapes(t *testing.T) {
	cases := map[string]string{
		"-----BEGIN OPENSSH PRIVATE KEY-----\nabc\ndef\n-----END OPENSSH PRIVATE KEY-----": "[REDACTED]",
		"token sk-Abc123XYZ_more":                                              "token [REDACTED]",
		"Authorization: Bearer eyJhbGciOiXYZ123":                               "Authorization: [REDACTED]",
		"pub AAAAC3NzaC1lZDI1NTE5AAAAIAbc123 injected":                         "pub [REDACTED] injected",
		"sha 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef": "sha [REDACTED]",
	}
	for in, want := range cases {
		got := Redact(in)
		if got != want {
			t.Fatalf("Redact(%q) = %q, want %q", in, got, want)
		}
		if strings.Contains(got, "sk-Abc") || strings.Contains(got, "AAAAC3NzaC1lZDI1NTE5") {
			t.Fatalf("secret survived redaction: %q", got)
		}
	}
}

func TestFileLoggingAndRedaction(t *testing.T) {
	dir := t.TempDir()
	logger, closer, err := New(Options{Dir: dir, Name: "node", AlsoStderr: false})
	if err != nil {
		t.Fatal(err)
	}
	logger.Info("tunnel connected", "key", "-----BEGIN OPENSSH PRIVATE KEY----- leak")
	closer.Close()

	raw, err := os.ReadFile(filepath.Join(dir, "node.log"))
	if err != nil {
		t.Fatal(err)
	}
	line := string(raw)
	if strings.Contains(line, "BEGIN OPENSSH") || strings.Contains(line, "leak") {
		t.Fatalf("secret leaked into log: %s", line)
	}
	if !strings.Contains(line, "tunnel connected") {
		t.Fatalf("normal content lost: %s", line)
	}
}

func TestRotation(t *testing.T) {
	dir := t.TempDir()
	logger, closer, err := New(Options{Dir: dir, Name: "node", MaxBytes: 200, Keep: 2})
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 40; i++ {
		logger.Info("filler entry to force rotation beyond 200 bytes quickly", "i", i)
	}
	closer.Close()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) < 2 {
		t.Fatalf("expected rotated files, got %d entries", len(entries))
	}
	// keep cap: main + at most Keep rotated files
	if len(entries) > 4 {
		t.Fatalf("rotation leaked files: %d entries", len(entries))
	}
}
