// akfile.go -- structured authorized_keys maintenance.
//
// Contract (docs/SECURITY_MODEL.md §3):
//   - parse into entries (dialhome-managed lines are recognised, everything else is
//     preserved byte-for-byte)
//   - mutate ONLY the target node's line
//   - atomic write (tmp+rename) with a timestamped backup, all under the caller's lock
//   - never wipe the file on a parse failure: abort instead
package relay

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/takomitkm/dialhome/internal/crypto"
)

// dialhome-node-<name> / dialhome-credential-<id> markers live at end of comment.
var (
	nodeMarkerRe       = regexp.MustCompile(`dialhome-node-([a-z0-9-]+)$`)
	credentialMarkerRe = regexp.MustCompile(`dialhome-credential-([a-z0-9-]+)$`)
)

// Entry is one authorized_keys line.
type Entry struct {
	Raw   string
	Kind  string // "node" | "credential" | "other"
	Name  string // node name or credential id (dialhome lines only)
	Ports []int  // permitlisten ports (node lines)
	KeyFP string // SHA256 fingerprint of the key body (dialhome lines)
}

// parseAKLine parses an authorized_keys line that MAY carry an options prefix
// ("restrict,command=\"...\" ssh-ed25519 AAAA... comment"): the key type is located
// by scanning fields, and the base64 body is validated down to its embedded type.
func parseAKLine(line string) (crypto.AuthorizedKey, bool) {
	fields := strings.Fields(line)
	idx := -1
	for i, f := range fields {
		if f == "ssh-ed25519" {
			idx = i
			break
		}
	}
	if idx < 0 || idx+1 >= len(fields) {
		return crypto.AuthorizedKey{}, false
	}
	blob, err := base64.StdEncoding.DecodeString(fields[idx+1])
	if err != nil {
		return crypto.AuthorizedKey{}, false
	}
	// wire blob opens with: uint32(11) || "ssh-ed25519"
	if len(blob) < 15 || !strings.HasPrefix(string(blob), "\x00\x00\x00\x0bssh-ed25519") {
		return crypto.AuthorizedKey{}, false
	}
	return crypto.AuthorizedKey{
		Type:    "ssh-ed25519",
		Blob:    blob,
		Comment: strings.Join(fields[idx+2:], " "),
	}, true
}

// Parse splits authorized_keys content into entries. Comment-only and empty lines
// are preserved as "other" entries so rendering is lossless for foreign content.
func Parse(content string) []Entry {
	var out []Entry
	for _, line := range strings.Split(content, "\n") {
		e := Entry{Raw: strings.TrimRight(line, "\r"), Kind: "other"}
		trimmed := strings.TrimSpace(e.Raw)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			out = append(out, e)
			continue
		}
		kp, ok := parseAKLine(trimmed)
		if !ok {
			out = append(out, e)
			continue
		}
		e.KeyFP = kp.Fingerprint()
		if m := nodeMarkerRe.FindStringSubmatch(kp.Comment); m != nil {
			e.Kind, e.Name = "node", m[1]
			e.Ports = permitListens(trimmed)
		} else if m := credentialMarkerRe.FindStringSubmatch(kp.Comment); m != nil {
			e.Kind, e.Name = "credential", m[1]
		}
		out = append(out, e)
	}
	return out
}

// permitListens extracts the numeric ports from permitlisten="127.0.0.1:P" options.
func permitListens(line string) []int {
	var out []int
	for _, m := range regexp.MustCompile(`permitlisten="127\.0\.0\.1:(\d+)"`).FindAllStringSubmatch(line, -1) {
		var p int
		for _, r := range m[1] {
			p = p*10 + int(r-'0')
		}
		out = append(out, p)
	}
	return out
}

// Render serialises entries back to authorized_keys content (LF endings).
func Render(entries []Entry) string {
	var b strings.Builder
	for _, e := range entries {
		b.WriteString(e.Raw)
		b.WriteString("\n")
	}
	return b.String()
}

// NodeLine renders the canonical restricted line for a node.
// The 127.0.0.1 literal is a security boundary (PITFALLS B1): never localise it.
func NodeLine(helperPath string, ports Ports, pub crypto.AuthorizedKey, name string) string {
	opts := fmt.Sprintf(
		"restrict,command=%q,port-forwarding,permitlisten=\"127.0.0.1:%d\",permitlisten=\"127.0.0.1:%d\",permitopen=\"127.0.0.1:1\"",
		helperCommand(helperPath, ports.SSH), ports.SSH, ports.App)
	return opts + " " + pub.Line()[:strings.LastIndex(pub.Line(), " ")+1] + "dialhome-node-" + name
}

// CredentialLine renders the enrollment-credential restricted line (no forwarding at all).
func CredentialLine(helperPath string, credID string, pub crypto.AuthorizedKey) string {
	return fmt.Sprintf("restrict,command=%q,no-port-forwarding,no-pty,no-user-rc %s",
		helperCommandEnroll(helperPath), pub.Type+" "+b64Body(pub)+" dialhome-credential-"+credID)
}

func helperCommand(helperPath string, port int) string {
	return helperPath + " tunnel --port " + fmt.Sprint(port)
}

func helperCommandEnroll(helperPath string) string {
	return helperPath + " enroll"
}

func b64Body(pub crypto.AuthorizedKey) string {
	parts := strings.Fields(pub.Line())
	if len(parts) >= 2 {
		return parts[1]
	}
	return ""
}

// UpsertNode replaces (or appends) the dialhome-node-<name> line, preserving all others.
func UpsertNode(entries []Entry, name, newLine string) ([]Entry, bool) {
	out := make([]Entry, 0, len(entries)+1)
	replaced := false
	for _, e := range entries {
		if e.Kind == "node" && e.Name == name {
			out = append(out, Entry{Raw: newLine, Kind: "node", Name: name})
			replaced = true
			continue
		}
		out = append(out, e)
	}
	if !replaced {
		out = append(out, Entry{Raw: newLine, Kind: "node", Name: name})
	}
	return out, replaced
}

// RemoveNode deletes the dialhome-node-<name> line; reports whether it existed.
func RemoveNode(entries []Entry, name string) ([]Entry, bool) {
	out := make([]Entry, 0, len(entries))
	removed := false
	for _, e := range entries {
		if e.Kind == "node" && e.Name == name {
			removed = true
			continue
		}
		out = append(out, e)
	}
	return out, removed
}

// RemoveCredential deletes a dialhome-credential-<id> line.
func RemoveCredential(entries []Entry, credID string) ([]Entry, bool) {
	out := make([]Entry, 0, len(entries))
	removed := false
	for _, e := range entries {
		if e.Kind == "credential" && e.Name == credID {
			removed = true
			continue
		}
		out = append(out, e)
	}
	return out, removed
}

// WriteWithBackup atomically replaces path with content, keeping a timestamped copy
// of the previous content beside it. The file is hardened 0600-equivalent afterwards
// (unix chmod; Windows inherits the creator's hardened tmp file).
func WriteWithBackup(path, content string) error {
	if raw, err := os.ReadFile(path); err == nil {
		bak := path + ".bak-" + time.Now().Format("20060102-150405")
		if err := os.WriteFile(bak, raw, 0o600); err != nil {
			return fmt.Errorf("ak backup: %w", err)
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.WriteString(content); err != nil {
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
