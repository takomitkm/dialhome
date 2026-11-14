// helper.go -- the forced-command entry a Relay SSH session runs (one process per
// connection). Two trust domains:
//
//	tunnel keys    command="<helper> tunnel --port <sshPort>"   (AK line written at enroll)
//	credentials    command="<helper> enroll --credential <id>"  (AK line written at issue)
//
// The port / credential id are baked into the caller's OWN authorized_keys line, so a
// client cannot claim another node's identity (docs/SECURITY_MODEL.md §1).
// SSH_ORIGINAL_COMMAND carries the actual request; anything else is denied.
package relay

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/takomitkm/dialhome/internal/crypto"
)

var (
	ErrUnknownCaller   = errors.New("relay: no node matches this port")
	ErrDenied          = errors.New("relay: denied")
	ErrBadOriginal     = errors.New("relay: SSH_ORIGINAL_COMMAND not understood")
	ErrPayloadTooLarge = errors.New("relay: payload too large")
)

// Helper carries the injected dependencies so the whole dispatch is unit-testable.
type Helper struct {
	Store      *Store
	AKPath     string
	OpenSSHZip string // whitelisted file served by `get openssh`
	Now        func() time.Time
	HelperPath string // the binary path baked into authorized_keys (falls back to os.Args[0])
	// AppProbe maps an app port to a probe answer ("ok"/"down") -- injected so tests
	// never need a live service. Production wires TcpProbe(127.0.0.1:port).
	AppProbe func(appPort int) bool
}

var registerSanitize = regexp.MustCompile(`[^\w .:@\-]`)

// TunnelCommand handles a node-key connection bound to ssh `port`.
func (h *Helper) TunnelCommand(port int, original string) (string, int) {
	original = strings.TrimSpace(original)
	switch {
	case original == "check":
		return h.check(port)
	case strings.HasPrefix(original, "register "):
		return h.register(port, strings.TrimPrefix(original, "register "))
	case original == "get openssh":
		return h.serveFile(h.OpenSSHZip)
	default:
		return "DENY: unknown request\n", 1
	}
}

// EnrollCommand handles a credential connection: `enroll <pubkey-line>`.
func (h *Helper) EnrollCommand(credID, original string) (string, int) {
	original = strings.TrimSpace(original)
	if !strings.HasPrefix(original, "enroll ") {
		return "DENY: enroll expects a public key\n", 1
	}
	pubText := strings.TrimSpace(strings.TrimPrefix(original, "enroll "))
	if len(pubText) > 2000 {
		return "DENY: payload too large\n", 1
	}
	pub, err := crypto.ParsePublicKeyLine(pubText)
	if err != nil {
		return fmt.Sprintf("DENY: %v\n", err), 1
	}
	fp := pub.Fingerprint()
	usedAt := h.Now().UTC().Format(time.RFC3339)
	helperPath := h.HelperPath
	if helperPath == "" && len(os.Args) > 0 {
		helperPath = os.Args[0]
	}
	var out string
	err = h.Store.WithLock(func(r *Registry) error {
		cred, ok := r.Credentials[credID]
		if !ok {
			return fmt.Errorf("%w: unknown credential", ErrCredentialBad)
		}
		if cred.UsedAt != "" {
			return fmt.Errorf("%w: %s", ErrCredentialUsed, credID)
		}
		exp, perr := time.Parse(time.RFC3339, cred.ExpiresAt)
		if perr != nil || h.Now().UTC().After(exp) {
			return fmt.Errorf("%w: %s", ErrCredentialExpiry, cred.ExpiresAt)
		}
		node, ok := r.Nodes[cred.Node]
		if !ok {
			return fmt.Errorf("%w: %s (dangling credential)", ErrNodeMissing, cred.Node)
		}
		// bind the submitted public key to THIS credential's node only
		node.TunnelKeyFP = fp
		node.State = "active"
		cred.UsedAt = usedAt
		cred.PubKeyFP = fp

		raw, rerr := os.ReadFile(h.AKPath)
		if rerr != nil && !errors.Is(rerr, os.ErrNotExist) {
			return rerr
		}
		entries := Parse(string(raw))
		line := NodeLine(helperPath, node.Ports, pub, cred.Node)
		entries, _ = UpsertNode(entries, cred.Node, line)
		entries, _ = RemoveCredential(entries, credID) // one-shot: credential retires here
		if werr := WriteWithBackup(h.AKPath, Render(entries)); werr != nil {
			return werr
		}
		out = fmt.Sprintf("ENROLL-OK node=%s ports=%d,%d\n", cred.Node, node.Ports.App, node.Ports.SSH)
		return nil
	})
	if err != nil {
		if errors.Is(err, ErrCredentialUsed) || errors.Is(err, ErrCredentialExpiry) || errors.Is(err, ErrCredentialBad) {
			return fmt.Sprintf("DENY: %v\n", err), 1
		}
		return fmt.Sprintf("ENROLL-FAILED: %v\n", err), 1
	}
	return out, 0
}

// helperPathFromArgs recovers the helper binary path from the process argv
// (the forced command runs `<path> enroll --credential <id>`).
func (h *Helper) helperPathFromArgs() string {
	if len(os.Args) > 0 {
		return os.Args[0]
	}
	return "dialhome"
}

func (h *Helper) check(port int) (string, int) {
	var resp string
	err := h.Store.WithLock(func(r *Registry) error {
		for name, n := range r.Nodes {
			if n.Ports.SSH == port && n.State != "revoked" {
				n.LastCheck = h.Now().UTC().Format(time.RFC3339)
				appUp := false
				if h.AppProbe != nil && n.Ports.App > 0 {
					appUp = h.AppProbe(n.Ports.App)
				}
				b, _ := json.Marshal(struct {
					OK         bool   `json:"ok"`
					Node       string `json:"node"`
					SSH        int    `json:"ssh"`
					App        int    `json:"app"`
					AppService bool   `json:"app_service"`
				}{true, name, n.Ports.SSH, n.Ports.App, appUp})
				resp = string(b)
				return nil
			}
		}
		return ErrUnknownCaller
	})
	if err != nil {
		return fmt.Sprintf(`{"ok":false,"reason":"unknown-caller","port":%d}`+"\n", port), 1
	}
	return resp + "\n", 0
}

func nodeOf(r *Registry, port int) *NodeRecord {
	for _, n := range r.Nodes {
		if n.Ports.SSH == port && n.State != "revoked" {
			return n
		}
	}
	return nil
}

func (h *Helper) register(port int, payload string) (string, int) {
	payload = strings.TrimSpace(payload)
	if !strings.HasPrefix(payload, "{") || !strings.HasSuffix(payload, "}") {
		return `{"ok":false,"reason":"bad-payload"}` + "\n", 1
	}
	if len(payload) > 2000 {
		return `{"ok":false,"reason":"payload-too-large"}` + "\n", 1
	}
	// the legacy wire form carries macs as ONE string; keep that shape
	var facts struct {
		UUID string `json:"uuid"`
		MACs string `json:"macs"`
		User string `json:"user"`
	}
	if err := json.Unmarshal([]byte(payload), &facts); err != nil {
		return `{"ok":false,"reason":"bad-json"}` + "\n", 1
	}
	var out string
	err := h.Store.WithLock(func(r *Registry) error {
		node := nodeOf(r, port)
		if node == nil {
			return ErrUnknownCaller
		}
		node.Hardware = Hardware{
			UUID:     sanitizeField(facts.UUID),
			MACs:     []string{sanitizeField(facts.MACs)},
			User:     sanitizeField(facts.User),
			Hostname: node.Hardware.Hostname,
		}
		node.LastCheck = h.Now().UTC().Format(time.RFC3339)
		out = `{"ok":true}`
		return nil
	})
	if err != nil {
		return fmt.Sprintf(`{"ok":false,"reason":"%v"}`+"\n", err), 1
	}
	return out + "\n", 0
}

func sanitizeField(s string) string {
	s = strings.TrimSpace(s)
	if len(s) > 200 {
		s = s[:200]
	}
	return registerSanitize.ReplaceAllString(s, "")
}

func (h *Helper) serveFile(path string) (string, int) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "DENY: file not staged\n", 1
	}
	os.Stdout.Write(raw) // binary passthrough: the caller redirects raw bytes
	return "", 0
}
