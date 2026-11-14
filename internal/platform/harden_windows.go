//go:build windows

package platform

import (
	"fmt"
	"os"
	"os/exec"
)

// HardenFile strips inherited ACLs and grants only the current user Full control.
// Go's os.Chmod cannot express this on Windows (it toggles the read-only bit only).
func HardenFile(path string) error {
	user := os.Getenv("USERNAME")
	domain := os.Getenv("USERDOMAIN")
	if user == "" {
		return fmt.Errorf("harden: USERNAME empty")
	}
	grant := user + ":F"
	if domain != "" {
		grant = domain + "\\" + user + ":F"
	}
	cmd := exec.Command("icacls", path, "/inheritance:r", "/grant:r", grant)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("harden %s: %v: %s", path, err, string(out))
	}
	return nil
}
