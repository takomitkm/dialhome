// Package errs defines the error taxonomy. Every domain failure maps to a distinct
// exit code so `doctor` and CI can tell failures apart (spec §8: not everything is 255).
package errs

import "errors"

var (
	// ErrUsage marks command-line misuse (exit 2).
	ErrUsage = errors.New("usage error")
	// ErrNotImplemented marks scaffolding that a later phase fills in.
	ErrNotImplemented = errors.New("not implemented")
)

// ExitCode maps an error to a process exit code.
func ExitCode(err error) int {
	switch {
	case err == nil:
		return 0
	case isErr(err, ErrUsage):
		return 2
	case isErr(err, ErrNotImplemented):
		return 3
	default:
		return 1
	}
}

func isErr(err, target error) bool {
	for err != nil {
		if err == target {
			return true
		}
		type unwrapper interface{ Unwrap() error }
		u, ok := err.(unwrapper)
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}

// Domain exit codes (used by node/controller/relay commands once implemented).
const (
	ExitOK              = 0
	ExitGeneric         = 1
	ExitUsage           = 2
	ExitNotImplemented  = 3
	ExitSSHDNotFound    = 10 // doctor: portable sshd not present
	ExitSSHDDown        = 11 // doctor: sshd configured but not running
	ExitTunnelDown      = 12 // doctor/supervisor: tunnel process absent or exited
	ExitRelayUnreach    = 13 // doctor: relay not reachable on its port
	ExitHostKeyMismatch = 14 // doctor: ssh host key changed on the relay
	ExitAuthFailed      = 15 // doctor: publickey auth refused
	ExitListenRefused   = 16 // doctor/relay: relay refused the reverse listen (permitlisten)
	ExitPortTaken       = 17 // doctor/relay: port held by another node
	ExitManagerKeyBad   = 18 // doctor: controller management key rejected by node
	ExitShellUnusable   = 19 // doctor: node user shell is nologin/missing
)
