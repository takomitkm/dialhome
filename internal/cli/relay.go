package cli

import (
	cryptorand "crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/takomitkm/dialhome/internal/crypto"
	"github.com/takomitkm/dialhome/internal/errs"
	"github.com/takomitkm/dialhome/internal/platform"
	"github.com/takomitkm/dialhome/internal/relay"
)

// relayPaths resolves the on-disk locations for the relay role.
func relayPaths() (store, ak, helperBin string, err error) {
	base := platform.DataDir("relay")
	if err := os.MkdirAll(base, 0o700); err != nil {
		return "", "", "", err
	}
	bin, err := os.Executable()
	if err != nil {
		bin = "dialhome"
	}
	return base, filepathStrings(base, "authorized_keys"), bin, nil
}

func filepathStrings(base, name string) string { return base + string(os.PathSeparator) + name }

func runRelayImpl(args []string) error {
	if len(args) == 0 {
		return usage()
	}
	base, akPath, helperBin, err := relayPaths()
	if err != nil {
		return err
	}
	store := relay.NewStore(base+string(os.PathSeparator)+"registry.json", base+string(os.PathSeparator)+"registry.lock")

	switch args[0] {
	case "init":
		// registry.json default + AK include line (with backup) + helper path
		err = store.WithLock(func(r *relay.Registry) error {
			r.HelperPath = helperBin
			return nil
		})
		if err != nil {
			return err
		}
		if _, err := os.Stat(akPath); errors.Is(err, os.ErrNotExist) {
			if err := os.WriteFile(akPath, []byte("# dialhome-managed keys (included by the system authorized_keys)\n"), 0o600); err != nil {
				return err
			}
		}
		fmt.Println("relay init ok: " + base)
		fmt.Println("ensure the system authorized_keys ends with:  Include " + akPath)
		return nil

	case "credentials":
		if len(args) < 3 {
			return fmt.Errorf("%w: credentials issue <name> | credentials revoke <id>", errs.ErrUsage)
		}
		switch args[1] {
		case "issue":
			return relayCredentialIssue(store, akPath, helperBin, args[2])
		case "revoke":
			return relayCredentialRevoke(store, akPath, args[2])
		default:
			return fmt.Errorf("%w: unknown credentials verb %q", errs.ErrUsage, args[1])
		}

	case "enroll":
		// `relay enroll <name>` issues a credential for <name> (spec §5.2 uses this form too)
		return relayCredentialIssue(store, akPath, helperBin, args[1])

	case "list":
		r, err := store.Load()
		if err != nil {
			return err
		}
		fmt.Printf("%-24s %-8s %-6s %-6s %-20s %s\n", "NODE", "STATE", "APP", "SSH", "TUNNEL-FP", "HW")
		for name, n := range r.Nodes {
			hw := "-"
			if n.Hardware.UUID != "" {
				hw = "uuid✓"
			}
			fmt.Printf("%-24s %-8s %-6d %-6d %-20s %s\n", name, n.State, n.Ports.App, n.Ports.SSH, short(n.TunnelKeyFP, 18), hw)
		}
		return nil

	case "inspect":
		if len(args) < 2 {
			return fmt.Errorf("%w: inspect <name>", errs.ErrUsage)
		}
		r, err := store.Load()
		if err != nil {
			return err
		}
		n, ok := r.Nodes[args[1]]
		if !ok {
			return fmt.Errorf("node %q not found", args[1])
		}
		raw, _ := json.MarshalIndent(n, "", "  ")
		fmt.Println(string(raw))
		return nil

	case "ports":
		r, err := store.Load()
		if err != nil {
			return err
		}
		for _, p := range relay.UsedPorts(r) {
			fmt.Println(p)
		}
		return nil

	case "revoke":
		if len(args) < 2 {
			return fmt.Errorf("%w: revoke <name>", errs.ErrUsage)
		}
		return relayRevoke(store, akPath, args[1])

	case "reconcile", "verify":
		return fmt.Errorf("%w: relay %s lands in Phase 6/9 (needs node channel)", errs.ErrNotImplemented, args[0])

	default:
		return fmt.Errorf("%w: unknown relay subcommand %q", errs.ErrUsage, args[0])
	}
}

func relayCredentialIssue(store *relay.Store, akPath, helperBin, name string) error {
	kp, err := crypto.Generate("dialhome-credential")
	if err != nil {
		return err
	}
	credID := "cred-" + randHex(6)
	exp := time.Now().UTC().Add(24 * time.Hour).Format(time.RFC3339)
	managerPub := ""
	if raw, err := os.ReadFile(filepath.Join(platform.DataDir("relay"), "manager.pub")); err == nil {
		managerPub = strings.TrimSpace(string(raw))
	}
	var credB64 string
	err = store.WithLock(func(r *relay.Registry) error {
		// idempotent: an existing node keeps its ports
		ports, err := relay.AllocatePair(r, relay.UsedPorts(r), livePorts())
		if err != nil {
			return err
		}
		n := r.Nodes[name]
		if n == nil {
			n = &relay.NodeRecord{Ports: ports, RegisteredAt: time.Now().UTC().Format(time.RFC3339)}
			r.Nodes[name] = n
		} else {
			n.CredentialID = credID
		}
		if n.State == "" || n.State == "revoked" {
			n.State = "pending"
		}
		n.CredentialID = credID
		r.Credentials[credID] = &relay.Credential{
			Node:      name,
			PubKeyFP:  kp.Public.Fingerprint(),
			ExpiresAt: exp,
			CreatedAt: time.Now().UTC().Format(time.RFC3339),
		}
		raw, rerr := os.ReadFile(akPath)
		if rerr != nil && !errors.Is(rerr, os.ErrNotExist) {
			return rerr
		}
		entries := relay.Parse(string(raw))
		entries = append(entries, relay.Entry{Raw: relay.CredentialLine(helperBin, credID, kp.Public), Kind: "credential", Name: credID})
		if err := relay.WriteWithBackup(akPath, relay.Render(entries)); err != nil {
			return err
		}
		doc := map[string]string{
			"credential_version":      "1",
			"node_name":               name,
			"private_key_openssh_b64": base64.StdEncoding.EncodeToString([]byte(kp.Private)),
			"manager_pubkey":          managerPub,
			"expires_at":              exp,
		}
		docB, _ := json.MarshalIndent(doc, "", "  ")
		credB64 = base64.StdEncoding.EncodeToString(docB)
		return nil
	})
	if err != nil {
		return err
	}
	fmt.Println("CREDENTIAL-B64 = " + credB64)
	fmt.Println("feed it to: dialhome node install --credential <that b64 or file>")
	return nil
}

func relayCredentialRevoke(store *relay.Store, akPath, credID string) error {
	return store.WithLock(func(r *relay.Registry) error {
		if c, ok := r.Credentials[credID]; ok {
			delete(r.Credentials, credID)
			_ = c
		} else {
			return fmt.Errorf("credential %s not found", credID)
		}
		raw, err := os.ReadFile(akPath)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		entries := relay.Parse(string(raw))
		entries, removed := relay.RemoveCredential(entries, credID)
		if !removed {
			fmt.Println("credential AK line already absent")
		}
		return relay.WriteWithBackup(akPath, relay.Render(entries))
	})
}

func relayRevoke(store *relay.Store, akPath, name string) error {
	return store.WithLock(func(r *relay.Registry) error {
		n, ok := r.Nodes[name]
		if !ok {
			return fmt.Errorf("node %s not found", name)
		}
		n.State = "revoked"
		raw, err := os.ReadFile(akPath)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		entries := relay.Parse(string(raw))
		entries, removed := relay.RemoveNode(entries, name)
		if !removed {
			fmt.Println("node AK line already absent")
		}
		if err := relay.WriteWithBackup(akPath, relay.Render(entries)); err != nil {
			return err
		}
		fmt.Printf("revoked %s (ports %d/%d freed in registry; listeners disappear after sshd re-key or timeout)\n",
			name, n.Ports.App, n.Ports.SSH)
		return nil
	})
}

func runRelayHelperImpl(args []string) error {
	fs := flag.NewFlagSet("relay-helper", flag.ContinueOnError)
	port := fs.Int("port", 0, "ssh port baked into the caller's authorized_keys line")
	cred := fs.String("credential", "", "credential id baked into the caller's authorized_keys line")
	base := platform.DataDir("relay")
	fs.StringVar(&base, "base", base, "relay data dir")
	if err := fs.Parse(args); err != nil {
		return err
	}
	original := os.Getenv("SSH_ORIGINAL_COMMAND")
	store := relay.NewStore(base+string(os.PathSeparator)+"registry.json", base+string(os.PathSeparator)+"registry.lock")
	h := &relay.Helper{
		Store:      store,
		AKPath:     base + string(os.PathSeparator) + "authorized_keys",
		OpenSSHZip: base + string(os.PathSeparator) + "openssh/OpenSSH-Win64.zip",
		Now:        time.Now,
	}
	switch {
	case *cred != "":
		out, code := h.EnrollCommand(*cred, original)
		fmt.Print(out)
		if code != 0 {
			os.Exit(code)
		}
	case *port != 0:
		out, code := h.TunnelCommand(*port, original)
		if out != "" {
			fmt.Print(out)
		}
		if code != 0 {
			os.Exit(code)
		}
	default:
		return fmt.Errorf("%w: relay-helper needs --port or --credential", errs.ErrUsage)
	}
	return nil
}

func livePorts() []int {
	out, err := exec.Command("ss", "-ltn").Output()
	if err != nil {
		return nil
	}
	var ports []int
	for _, line := range strings.Split(string(out), "\n") {
		for _, field := range strings.Fields(line) {
			if strings.HasPrefix(field, "127.0.0.1:") {
				p := 0
				for _, r := range field[len("127.0.0.1:"):] {
					if r < '0' || r > '9' {
						p = 0
						break
					}
					p = p*10 + int(r-'0')
				}
				if p > 0 {
					ports = append(ports, p)
				}
			}
		}
	}
	return ports
}

func randHex(n int) string {
	const hex = "0123456789abcdef"
	b := make([]byte, n)
	_, _ = cryptorand.Read(b)
	for i := range b {
		b[i] = hex[int(b[i])%16]
	}
	return string(b)
}

func short(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
