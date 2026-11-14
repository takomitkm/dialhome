// Command dialhome is the single binary for all three roles (node / controller / relay).
//
// Usage:
//
//	dialhome node install|run|status|stop|uninstall|enroll|migrate
//	dialhome controller list|status|shell|exec
//	dialhome relay init|enroll|list|inspect|revoke|reconcile|ports|verify|credentials
//	dialhome relay-helper --port <p>          (forced-command entry, one process per connection)
//	dialhome autostart install|uninstall|status
//	dialhome service install|uninstall|status --scope system
//	dialhome doctor
package main

import (
	"fmt"
	"os"

	"github.com/takomitkm/dialhome/internal/cli"
)

func main() {
	if err := cli.Run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "dialhome:", err)
		os.Exit(1)
	}
}
