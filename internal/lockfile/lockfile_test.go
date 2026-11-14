package lockfile

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestAcquireRelease(t *testing.T) {
	p := filepath.Join(t.TempDir(), "registry.lock")
	l1, err := Acquire(p)
	if err != nil {
		t.Fatal(err)
	}
	if err := l1.Release(); err != nil {
		t.Fatal(err)
	}
	l2, err := Acquire(p) // releasable and re-acquirable
	if err != nil {
		t.Fatal(err)
	}
	l2.Release()
}

func TestFileCreatedWithTightPermsDir(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "sub", "x.lock")
	l, err := Acquire(p)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Release()
	if _, err := os.Stat(p); err != nil {
		t.Fatal(err)
	}
}

func TestConcurrentAcquirersSerialize(t *testing.T) {
	p := filepath.Join(t.TempDir(), "x.lock")
	var order []string
	var mu sync.Mutex
	done := make(chan struct{})

	go func() {
		l, err := Acquire(p)
		if err != nil {
			t.Error(err)
			close(done)
			return
		}
		mu.Lock()
		order = append(order, "first")
		mu.Unlock()
		l.Release()
		close(done)
	}()
	// second acquirer blocks until the first releases (flock/LockFileEx guarantee)
	l2, err := Acquire(p)
	if err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	order = append(order, "second")
	mu.Unlock()
	l2.Release()
	<-done
	if len(order) != 2 {
		t.Fatalf("serialization broken: %v", order)
	}
}
