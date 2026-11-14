// Package platform centralises per-OS paths and file hardening.
// Windows uses icacls (strip inheritance, grant only the current user) because
// Go's os.Chmod cannot express NTFS ACLs (it only toggles the read-only bit).
package platform

import (
	"os"
	"path/filepath"
	"runtime"
)

// DataDir returns the per-role data root (docs/ARCHITECTURE.md §2).
// role: "node" | "controller"
func DataDir(role string) string {
	switch runtime.GOOS {
	case "windows":
		base := os.Getenv("LOCALAPPDATA")
		if base == "" {
			base = filepath.Join(os.Getenv("USERPROFILE"), "AppData", "Local")
		}
		if role == "controller" {
			base = os.Getenv("APPDATA")
			if base == "" {
				base = filepath.Join(os.Getenv("USERPROFILE"), "AppData", "Roaming")
			}
			return filepath.Join(base, "dialhome")
		}
		return filepath.Join(base, "dialhome")
	case "darwin":
		home, _ := os.UserHomeDir()
		if role == "controller" {
			return filepath.Join(home, ".config", "dialhome")
		}
		return filepath.Join(home, "Library", "Application Support", "dialhome")
	default: // linux and everything else unix-like: XDG
		if role == "controller" {
			base := os.Getenv("XDG_CONFIG_HOME")
			if base == "" {
				home, _ := os.UserHomeDir()
				base = filepath.Join(home, ".config")
			}
			return filepath.Join(base, "dialhome")
		}
		base := os.Getenv("XDG_DATA_HOME")
		if base == "" {
			home, _ := os.UserHomeDir()
			base = filepath.Join(home, ".local", "share")
		}
		return filepath.Join(base, "dialhome")
	}
}
