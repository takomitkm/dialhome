package relay

import (
	"github.com/takomitkm/dialhome/internal/crypto"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func submittedPub(t *testing.T) string {
	t.Helper()
	kp, err := crypto.Generate("submitted")
	if err != nil {
		t.Fatal(err)
	}
	return kp.Public.Line()
}

func testHelper(t *testing.T) (*Helper, string) {
	t.Helper()
	dir := t.TempDir()
	store := NewStore(filepath.Join(dir, "registry.json"), filepath.Join(dir, "registry.lock"))
	h := &Helper{Store: store, AKPath: filepath.Join(dir, "authorized_keys"), Now: func() time.Time { return time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC) }}
	return h, dir
}

// issueCredential pre-registers a node + credential, as `relay credentials issue` does.
func issueCredential(t *testing.T, h *Helper, name, credID string, expireOffset time.Duration, usedAt string) {
	t.Helper()
	exp := h.Now().Add(expireOffset).UTC().Format(time.RFC3339)
	err := h.Store.WithLock(func(r *Registry) error {
		ports, err := AllocatePair(r, UsedPorts(r), nil)
		if err != nil {
			return err
		}
		r.Nodes[name] = &NodeRecord{State: "pending", Ports: ports, CredentialID: credID, RegisteredAt: h.Now().UTC().Format(time.RFC3339)}
		r.Credentials[credID] = &Credential{Node: name, ExpiresAt: exp, CreatedAt: h.Now().UTC().Format(time.RFC3339), UsedAt: usedAt}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestEnrollHappyPath(t *testing.T) {
	sub := submittedPub(t)
	h, dir := testHelper(t)
	// seed foreign lines: they must survive the enroll
	if err := os.WriteFile(h.AKPath, []byte(foreignAK()), 0o600); err != nil {
		t.Fatal(err)
	}
	issueCredential(t, h, "hp66", "cred-1", 24*time.Hour, "")

	out, code := h.EnrollCommand("cred-1", "enroll "+sub)
	if code != 0 {
		t.Fatalf("enroll failed: %s", out)
	}
	if !strings.Contains(out, "ENROLL-OK node=hp66") {
		t.Fatalf("unexpected output: %s", out)
	}

	// registry: node active, credential used
	r, err := h.Store.Load()
	if err != nil {
		t.Fatal(err)
	}
	if r.Nodes["hp66"].State != "active" || r.Nodes["hp66"].TunnelKeyFP == "" {
		t.Fatalf("node not activated: %+v", r.Nodes["hp66"])
	}
	if r.Credentials["cred-1"].UsedAt == "" {
		t.Fatal("credential not marked used")
	}

	// AK: node line present, credential line retired, foreign lines preserved
	content, err := os.ReadFile(h.AKPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(content)
	if !strings.Contains(text, "dialhome-node-hp66") {
		t.Fatal("node AK line missing")
	}
	if strings.Contains(text, "dialhome-credential-cred-1") {
		t.Fatal("credential AK line must retire after use")
	}
	if !strings.Contains(text, "# someone else's key") {
		t.Fatal("foreign lines must be preserved")
	}
	_ = dir
}

func TestEnrollFillsAK(t *testing.T) {
	sub := submittedPub(t)
	h, _ := testHelper(t)
	issueCredential(t, h, "n2", "cred-2", 24*time.Hour, "")
	out, code := h.EnrollCommand("cred-2", "enroll "+sub)
	if code != 0 {
		t.Fatalf("enroll failed: %s", out)
	}
	raw, _ := os.ReadFile(h.AKPath)
	entries := Parse(string(raw))
	found := false
	for _, e := range entries {
		if e.Kind == "node" && e.Name == "n2" {
			found = true
			if len(e.Ports) != 2 {
				t.Fatalf("node line must carry two permitlisten ports: %v", e.Ports)
			}
			if e.Ports[0] < 13440 || e.Ports[1] > 13600 {
				t.Fatalf("ports outside pool: %v", e.Ports)
			}
			if !strings.Contains(e.Raw, `permitopen="127.0.0.1:1"`) {
				t.Fatal("permitopen boundary missing")
			}
			if !strings.Contains(e.Raw, `port-forwarding`) {
				t.Fatal("port-forwarding missing")
			}
		}
	}
	if !found {
		t.Fatal("node line not found in AK")
	}
}

func TestEnrollIdempotentPorts(t *testing.T) {
	sub := submittedPub(t)
	h, _ := testHelper(t)
	issueCredential(t, h, "dup", "cred-a", 24*time.Hour, "")
	_, code := h.EnrollCommand("cred-a", "enroll "+sub)
	if code != 0 {
		t.Fatal("first enroll failed")
	}
	r, _ := h.Store.Load()
	ports := r.Nodes["dup"].Ports

	// second credential for the SAME node name must reuse the slot (fp reuse semantics)
	issueCredential2(t, h, "dup", "cred-b")
	_, code = h.EnrollCommand("cred-b", "enroll "+sub)
	if code != 0 {
		t.Fatal("second enroll failed")
	}
	r2, _ := h.Store.Load()
	if r2.Nodes["dup"].Ports != ports {
		t.Fatalf("idempotency broken: %v -> %v", ports, r2.Nodes["dup"].Ports)
	}
}

func issueCredential2(t *testing.T, h *Helper, name, credID string) {
	t.Helper()
	err := h.Store.WithLock(func(r *Registry) error {
		// reuse the existing slot (fp identity semantics)
		n := r.Nodes[name]
		if n == nil {
			ports, err := AllocatePair(r, UsedPorts(r), nil)
			if err != nil {
				return err
			}
			n = &NodeRecord{Ports: ports}
			r.Nodes[name] = n
		}
		n.State = "pending"
		n.CredentialID = credID
		r.Credentials[credID] = &Credential{Node: name, ExpiresAt: h.Now().Add(24 * time.Hour).UTC().Format(time.RFC3339), CreatedAt: h.Now().UTC().Format(time.RFC3339)}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestEnrollNegative(t *testing.T) {
	sub := submittedPub(t)
	h, _ := testHelper(t)

	// unknown credential
	if _, code := h.EnrollCommand("cred-none", "enroll "+sub); code == 0 {
		t.Fatal("unknown credential must be denied")
	}

	// used credential
	issueCredential(t, h, "used", "cred-u", 24*time.Hour, "")
	h.EnrollCommand("cred-u", "enroll "+sub)
	if _, code := h.EnrollCommand("cred-u", "enroll "+sub); code == 0 {
		t.Fatal("used credential must be denied (N9)")
	}

	// expired credential
	issueCredential(t, h, "expired", "cred-e", -1*time.Hour, "")
	if _, code := h.EnrollCommand("cred-e", "enroll "+sub); code == 0 {
		t.Fatal("expired credential must be denied")
	}

	// bad payload
	issueCredential(t, h, "bad", "cred-b", 24*time.Hour, "")
	if _, code := h.EnrollCommand("cred-b", "enroll not-a-key"); code == 0 {
		t.Fatal("bad key must be denied")
	}
}

func TestTunnelRegisterAndCheck(t *testing.T) {
	sub := submittedPub(t)
	h, _ := testHelper(t)
	issueCredential(t, h, "reg-node", "cred-r", 24*time.Hour, "")
	h.EnrollCommand("cred-r", "enroll "+sub)
	r, _ := h.Store.Load()
	port := r.Nodes["reg-node"].Ports.SSH

	out, code := h.TunnelCommand(port, `register {"uuid":"4C4C4544","macs":"AA:BB:CC","user":"Administrator"}`)
	if code != 0 || !strings.Contains(out, `"ok":true`) {
		t.Fatalf("register failed: %s", out)
	}
	r2, _ := h.Store.Load()
	if r2.Nodes["reg-node"].Hardware.UUID != "4C4C4544" || len(r2.Nodes["reg-node"].Hardware.MACs) != 1 {
		t.Fatalf("hardware not recorded: %+v", r2.Nodes["reg-node"].Hardware)
	}

	out, code = h.TunnelCommand(port, "check")
	if code != 0 || !strings.Contains(out, `"node":"reg-node"`) {
		t.Fatalf("check failed: %s", out)
	}

	// unknown port denied
	if _, code := h.TunnelCommand(99999, "check"); code == 0 {
		t.Fatal("unknown port must be denied")
	}

	// register sanitizes hostile payloads
	out, code = h.TunnelCommand(port, `register {"uuid":"evil$(rm)","macs":"M","user":"u"}`)
	if code != 0 {
		t.Fatalf("sanitized register should still succeed: %s", out)
	}
	r3, _ := h.Store.Load()
	if strings.Contains(r3.Nodes["reg-node"].Hardware.UUID, "$(") {
		t.Fatal("hostile characters must be stripped")
	}
}

func TestAllocatePairExhaustion(t *testing.T) {
	r := &Registry{PortPool: PortPool{Base: 13440, Top: 13444}} // 2 pairs
	taken := []int{13440, 13441, 13442, 13443}
	if _, err := AllocatePair(r, taken, nil); err == nil {
		t.Fatal("exhausted pool must fail")
	}
	p, err := AllocatePair(r, []int{13440, 13441}, nil)
	if err != nil || p.App != 13442 || p.SSH != 13443 {
		t.Fatalf("allocator picked wrong pair: %+v %v", p, err)
	}
	live := []int{13442} // as parsed from `ss -ltn` output
	if _, err := AllocatePair(r, []int{13440, 13441}, live); err == nil {
		t.Fatal("live listening port must block allocation")
	}
}
