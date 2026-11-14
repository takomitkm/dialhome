// Package cli routes subcommands. Keep it thin: parse, dispatch, report.
// Exit codes: 0 ok; 1 generic failure; 2 usage error; 10+ domain codes (see internal/errs).
package cli

import (
	"fmt"
	"strings"

	"github.com/takomitkm/dialhome/internal/errs"
)

// Run executes argv (without the program name).
func Run(argv []string) error {
	if len(argv) == 0 {
		return usage()
	}
	role, rest := argv[0], argv[1:]
	switch role {
	case "-h", "--help", "help":
		return usage()
	case "node":
		return runNode(rest)
	case "controller":
		return runController(rest)
	case "relay":
		return runRelayImpl(rest)
	case "relay-helper":
		return runRelayHelperImpl(rest)
	case "autostart":
		return runAutostart(rest)
	case "service":
		return runService(rest)
	case "migrate":
		return runMigrate(rest)
	case "doctor":
		return runDoctor(rest)
	case "version":
		fmt.Println("dialhome " + version)
		return nil
	default:
		return fmt.Errorf("%w: unknown command %q", errs.ErrUsage, role)
	}
}

func usage() error {
	fmt.Print(`dialhome -- reverse SSH access for NAT-ed, admin-less machines

  dialhome node install [--mode temporary|persistent] [--credential FILE] [--relay USER@HOST:PORT] [--name NAME]
  dialhome node run                        run supervisor in the foreground
  dialhome node status [--verbose]
  dialhome node stop | uninstall
  dialhome node logs [channel]
  dialhome controller list | status
  dialhome controller shell <node> | exec <node> <command...>
  dialhome controller anchors <node>
  dialhome relay init | enroll <name> | list | inspect <name> | revoke <name>
  dialhome relay reconcile | ports | verify
  dialhome relay credentials issue <name> | revoke <id>
  dialhome relay-helper --port <p>         (internal: ssh forced-command entry)
  dialhome autostart install | uninstall | status
  dialhome service install | uninstall | status --scope system
  dialhome migrate --from-legacy
  dialhome doctor
  dialhome version

Docs: docs/ARCHITECTURE.md, docs/SECURITY_MODEL.md, docs/man-dialhome (legacy PS edition)
`)
	return nil
}

// version is set by the release build via -ldflags; keep a dev default.
var version = "dev"

func runNode(args []string) error {
	if len(args) == 0 {
		return usage()
	}
	switch args[0] {
	case "install":
		return fmt.Errorf("%w: node install lands in Phase 5", errs.ErrNotImplemented)
	case "run", "status", "stop", "uninstall", "logs", "enroll":
		return fmt.Errorf("%w: node %s lands in Phase 5", errs.ErrNotImplemented, args[0])
	default:
		return fmt.Errorf("%w: unknown node subcommand %q", errs.ErrUsage, args[0])
	}
}

func runController(args []string) error {
	if len(args) == 0 {
		return usage()
	}
	switch args[0] {
	case "list", "status", "shell", "exec", "anchors":
		return fmt.Errorf("%w: controller %s lands in Phase 6", errs.ErrNotImplemented, args[0])
	default:
		return fmt.Errorf("%w: unknown controller subcommand %q", errs.ErrUsage, args[0])
	}
}

func runAutostart(args []string) error {
	if len(args) == 0 {
		return usage()
	}
	switch args[0] {
	case "install", "uninstall", "status":
		return fmt.Errorf("%w: autostart %s lands in Phase 7", errs.ErrNotImplemented, args[0])
	default:
		return fmt.Errorf("%w: unknown autostart subcommand %q", errs.ErrUsage, args[0])
	}
}

func runService(args []string) error {
	if len(args) == 0 {
		return usage()
	}
	switch args[0] {
	case "install", "uninstall", "status":
		return fmt.Errorf("%w: service %s lands in Phase 7 (optional, never default)", errs.ErrNotImplemented, args[0])
	default:
		return fmt.Errorf("%w: unknown service subcommand %q", errs.ErrUsage, args[0])
	}
}

func runMigrate(args []string) error {
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "--from-legacy") {
		return fmt.Errorf("%w: migrate requires --from-legacy", errs.ErrUsage)
	}
	return fmt.Errorf("%w: migrate lands in Phase 8", errs.ErrNotImplemented)
}

func runDoctor(args []string) error {
	return fmt.Errorf("%w: doctor lands in Phase 6", errs.ErrNotImplemented)
}
