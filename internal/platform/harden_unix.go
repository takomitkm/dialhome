//go:build !windows

package platform

import "os"

// HardenFile enforces 0600 on unix (owner read/write only).
func HardenFile(path string) error {
	return os.Chmod(path, 0o600)
}
