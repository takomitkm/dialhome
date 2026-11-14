// Package relay implements the Relay-side state: node registry, port allocator,
// enrollment credentials, authorized_keys maintenance and the forced-command helper.
package relay

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/takomitkm/dialhome/internal/lockfile"
)

const RegistryVersion = 1

var (
	ErrPortExhausted    = errors.New("relay: port pool exhausted")
	ErrNodeExists       = errors.New("relay: node already registered")
	ErrNodeMissing      = errors.New("relay: node not registered")
	ErrCredentialBad    = errors.New("relay: enrollment credential invalid")
	ErrCredentialUsed   = errors.New("relay: credential already used")
	ErrCredentialExpiry = errors.New("relay: credential expired")
)

type PortPool struct {
	Base int `json:"base"`
	Top  int `json:"top"`
}

type Ports struct {
	SSH int `json:"ssh"`
	App int `json:"app"`
}

type Hardware struct {
	UUID     string   `json:"uuid,omitempty"`
	MACs     []string `json:"macs,omitempty"`
	User     string   `json:"user,omitempty"`
	Hostname string   `json:"hostname,omitempty"`
}

type NodeRecord struct {
	State        string   `json:"state"` // pending | active | revoked
	Ports        Ports    `json:"ports"`
	TunnelKeyFP  string   `json:"tunnel_pubkey_fp,omitempty"`
	CredentialID string   `json:"credential_id,omitempty"`
	Hardware     Hardware `json:"hardware,omitempty"`
	RegisteredAt string   `json:"registered_at,omitempty"`
	LastCheck    string   `json:"last_check,omitempty"`
}

type Credential struct {
	Node      string `json:"node"`
	PubKeyFP  string `json:"pubkey_fp,omitempty"`
	ExpiresAt string `json:"expires_at"`
	UsedAt    string `json:"used_at,omitempty"`
	CreatedAt string `json:"created_at"`
}

type Registry struct {
	ConfigVersion int                    `json:"config_version"`
	PortPool      PortPool               `json:"port_pool"`
	HelperPath    string                 `json:"helper_path"`
	Nodes         map[string]*NodeRecord `json:"nodes"`
	Credentials   map[string]*Credential `json:"credentials"`
}

// Store wraps a registry file with its lock. All mutations go through WithLock.
type Store struct {
	path   string
	lock   string
	mu     sync.Mutex // in-process serialization (tests use the same Store)
	nowFn  func() time.Time
	liveFn func() []string // ports currently listening (ss -ltn equivalent), injected for tests
}

func NewStore(path, lockPath string) *Store {
	return &Store{path: path, lock: lockPath, nowFn: time.Now, liveFn: func() []string { return nil }}
}

func (s *Store) SetNow(fn func() time.Time)      { s.nowFn = fn }
func (s *Store) SetLivePorts(fn func() []string) { s.liveFn = fn }

func (s *Store) Load() (*Registry, error) {
	raw, err := os.ReadFile(s.path)
	if err != nil {
		return nil, err
	}
	var r Registry
	if err := json.Unmarshal(raw, &r); err != nil {
		return nil, fmt.Errorf("registry %s: %w", s.path, err)
	}
	if r.Nodes == nil {
		r.Nodes = map[string]*NodeRecord{}
	}
	if r.Credentials == nil {
		r.Credentials = map[string]*Credential{}
	}
	return &r, nil
}

// Save writes atomically (same-dir tmp + rename), assuming the caller holds the lock.
func (s *Store) Save(r *Registry) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	tmp, err := os.CreateTemp(filepath.Dir(s.path), filepath.Base(s.path)+".tmp-*")
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
	return os.Rename(tmpName, s.path)
}

// WithLock runs fn while holding the registry lock, loading a fresh registry.
// Empty file (first run) yields a default registry.
func (s *Store) WithLock(fn func(r *Registry) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	lk, err := lockfile.Acquire(s.lock)
	if err != nil {
		return err
	}
	defer lk.Release()
	r, err := s.Load()
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		r = &Registry{
			ConfigVersion: RegistryVersion,
			PortPool:      PortPool{Base: 13440, Top: 13600},
			Nodes:         map[string]*NodeRecord{},
			Credentials:   map[string]*Credential{},
		}
	}
	if err := fn(r); err != nil {
		return err
	}
	return s.Save(r)
}

// UsedPorts returns every port referenced by a live (non-revoked) node.
func UsedPorts(r *Registry) []int {
	var out []int
	for _, n := range r.Nodes {
		if n.State == "revoked" {
			continue
		}
		out = append(out, n.Ports.SSH, n.Ports.App)
	}
	sort.Ints(out)
	return out
}

// AllocatePair picks the first free (even, odd) pair inside the pool.
// taken: registry ports; live: ports currently bound on the relay (from ss -ltn).
// Callers must run inside WithLock.
func AllocatePair(r *Registry, taken, live []int) (Ports, error) {
	used := map[int]bool{}
	for _, p := range taken {
		used[p] = true
	}
	for _, p := range live {
		used[p] = true
	}
	for base := r.PortPool.Base; base+1 < r.PortPool.Top; base += 2 {
		if !used[base] && !used[base+1] {
			return Ports{App: base, SSH: base + 1}, nil
		}
	}
	return Ports{}, ErrPortExhausted
}

// livePortsExec is the default liveFn for real relays: parse `ss -ltn`.
func LivePortsFromSS(output string) []string {
	var out []string
	for _, line := range strings.Split(output, "\n") {
		for _, field := range strings.Fields(line) {
			if strings.HasPrefix(field, "127.0.0.1:") {
				out = append(out, field)
			}
		}
	}
	return out
}
