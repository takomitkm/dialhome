//go:build windows

package platform

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestHardenFileStripsInheritance pins the NTFS contract: after harden, the file has
// no inherited ACEs and the current user holds Full control (PITFALLS: wide ACLs on
// key material are a real finding, not cosmetics).
func TestHardenFileStripsInheritance(t *testing.T) {
	p := filepath.Join(t.TempDir(), "tunnel.key")
	if err := os.WriteFile(p, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := HardenFile(p); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command("icacls", p).CombinedOutput()
	if err != nil {
		t.Fatal(err)
	}
	text := string(out)
	if !strings.Contains(text, "(F)") {
		t.Fatalf("current user must hold Full control: %s", text)
	}
	// The Mandatory Label (integrity-level) ACE survives /inheritance:r -- it is a
	// system label, not an inherited discretionary grant. Every OTHER ACE must be
	// non-inherited after hardening.
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, p) || strings.Contains(line, "Successfully processed") {
			continue
		}
		if strings.Contains(line, "Mandatory Label") {
			continue
		}
		if strings.Contains(line, "(I)") {
			t.Fatalf("inherited discretionary ACE survived: %s (full output: %s)", line, text)
		}
	}
}
