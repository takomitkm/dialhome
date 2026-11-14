// Package logging provides slog-based logging with rotation hooks and mandatory
// secret redaction (docs/SECURITY_MODEL.md §5): private key bodies, bearer tokens,
// sk- style API keys, and long hex/base64 key bodies never reach a log line.
package logging

import (
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
)

var (
	redactors = []struct{ re *regexp.Regexp }{
		{regexp.MustCompile(`(?s)-----BEGIN [A-Z ]+PRIVATE KEY-----.*?-----END [A-Z ]+PRIVATE KEY-----`)},
		// truncated dumps: a BEGIN with no END on the same line still carries the body
		{regexp.MustCompile(`-----BEGIN [A-Z ]+PRIVATE KEY-----.*`)},
		{regexp.MustCompile(`(?i)sk-[A-Za-z0-9_-]{8,}`)},
		{regexp.MustCompile(`(?i)bearer [A-Za-z0-9._-]{8,}`)},
		{regexp.MustCompile(`AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/=]+`)},
		{regexp.MustCompile(`\b[0-9a-fA-F]{40,}\b`)},
	}
	redactOnce sync.Once
	redactRe   []*regexp.Regexp
)

// Redact scrubs known secret shapes from a string.
func Redact(s string) string {
	redactOnce.Do(func() {
		for _, r := range redactors {
			redactRe = append(redactRe, r.re)
		}
	})
	for _, re := range redactRe {
		s = re.ReplaceAllString(s, "[REDACTED]")
	}
	return s
}

// Options configures a file logger.
type Options struct {
	Dir        string // log directory (created 0700)
	Name       string // e.g. "node", "sshd", "tunnel-ssh"
	MaxBytes   int64  // rotate when a file exceeds this (default 5 MiB)
	Keep       int    // rotated files to keep (default 3)
	AlsoStderr bool   // mirror to stderr (interactive runs)
}

// New returns a *slog.Logger writing JSON lines into Dir/Name.log with rotation.
func New(opts Options) (*slog.Logger, io.Closer, error) {
	if opts.MaxBytes <= 0 {
		opts.MaxBytes = 5 << 20
	}
	if opts.Keep <= 0 {
		opts.Keep = 3
	}
	if err := os.MkdirAll(opts.Dir, 0o700); err != nil {
		return nil, nil, err
	}
	path := filepath.Join(opts.Dir, opts.Name+".log")
	w := &rotator{path: path, max: opts.MaxBytes, keep: opts.Keep, mirror: opts.AlsoStderr}
	level := slog.LevelInfo
	if os.Getenv("DIALHOME_DEBUG") != "" {
		level = slog.LevelDebug
	}
	h := slog.NewJSONHandler(w, &slog.HandlerOptions{
		Level: level,
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			if a.Value.Kind() == slog.KindString {
				a.Value = slog.StringValue(Redact(a.Value.String()))
			}
			return a
		},
	})
	return slog.New(h), w, nil
}

// rotator is an io.WriteCloser with size-based rotation.
type rotator struct {
	path   string
	max    int64
	keep   int
	mirror bool
	mu     sync.Mutex
	f      *os.File
	size   int64
}

func (r *rotator) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.f == nil || r.size+int64(len(p)) > r.max {
		if err := r.rotateLocked(); err != nil {
			return 0, err
		}
	}
	// last-line defence: redact the serialized line (covers msg and any attr the
	// handler does not route through ReplaceAttr, e.g. multi-line private keys)
	clean := []byte(Redact(string(p)))
	n, err := r.f.Write(clean)
	r.size += int64(n)
	if r.mirror {
		os.Stderr.Write(clean)
	}
	return n, err
}

func (r *rotator) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.f == nil {
		return nil
	}
	err := r.f.Close()
	r.f = nil
	return err
}

func (r *rotator) rotateLocked() error {
	if r.f != nil {
		r.f.Close()
		r.f = nil
	}
	if err := os.MkdirAll(filepath.Dir(r.path), 0o700); err != nil {
		return err
	}
	// shift old files: name.log.2 -> .3, .1 -> .2, current -> .1
	for i := r.keep - 1; i >= 1; i-- {
		src := r.path + rotateSuffix(i)
		dst := r.path + rotateSuffix(i+1)
		if _, err := os.Stat(src); err == nil {
			os.Remove(dst)
			os.Rename(src, dst)
		}
	}
	if _, err := os.Stat(r.path); err == nil {
		os.Rename(r.path, r.path+rotateSuffix(1))
	}
	f, err := os.OpenFile(r.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	r.f = f
	r.size = st.Size()
	return nil
}

func rotateSuffix(i int) string {
	return "." + strconv.Itoa(i)
}
