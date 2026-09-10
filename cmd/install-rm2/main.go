// Command install-rm2 is a double-clickable host launcher for RemarkableMyscriptLocal.
// It opens a console and runs the tagged install-from-web script for this OS.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"time"
)

// ReleaseTag is the GitHub release / raw path tag this launcher installs.
// Override at build: -ldflags "-X main.ReleaseTag=v0.3.3"
var ReleaseTag = "v0.3.3"

const repoRaw = "https://raw.githubusercontent.com/schraederbr/RemarkableMyscriptLocal"

func main() {
	fmt.Println("============================================================")
	fmt.Printf(" RemarkableMyscriptLocal installer launcher (%s)\n", ReleaseTag)
	fmt.Println("============================================================")
	fmt.Println()

	var err error
	switch runtime.GOOS {
	case "windows":
		err = runWindows()
	case "linux", "darwin":
		err = runUnix()
	default:
		err = fmt.Errorf("unsupported OS: %s", runtime.GOOS)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "\nERROR: %v\n", err)
		pause()
		os.Exit(1)
	}
	fmt.Println("\nOK  Launcher finished")
	pause()
}

func runWindows() error {
	url := fmt.Sprintf("%s/%s/scripts/install-from-web.ps1", repoRaw, ReleaseTag)
	ps := fmt.Sprintf(
		"irm %s | iex",
		url,
	)
	cmd := exec.Command("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	fmt.Println("==> Running Windows install-from-web.ps1 via PowerShell")
	fmt.Println("    ", url)
	fmt.Println()
	return cmd.Run()
}

func runUnix() error {
	url := fmt.Sprintf("%s/%s/scripts/install-from-web.sh", repoRaw, ReleaseTag)
	// Prefer curl|bash so prompts stay on the same TTY.
	script := fmt.Sprintf(`set -euo pipefail
if command -v curl >/dev/null 2>&1; then
  curl -fsSL %q | bash
elif command -v wget >/dev/null 2>&1; then
  wget -qO- %q | bash
else
  echo "ERROR: need curl or wget" >&2
  exit 1
fi
`, url, url)
	shell := "bash"
	if _, err := exec.LookPath("bash"); err != nil {
		shell = "sh"
	}
	cmd := exec.Command(shell, "-c", script)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	fmt.Printf("==> Running Unix install-from-web.sh via %s\n", shell)
	fmt.Println("   ", url)
	fmt.Println()
	return cmd.Run()
}

func pause() {
	if runtime.GOOS != "windows" {
		// Double-click from a GUI may close immediately; wait briefly for Enter when TTY.
		if fi, err := os.Stdin.Stat(); err == nil && (fi.Mode()&os.ModeCharDevice) != 0 {
			fmt.Print("\nPress Enter to close...")
			var b [1]byte
			_, _ = os.Stdin.Read(b[:])
		} else {
			time.Sleep(2 * time.Second)
		}
		return
	}
	fmt.Print("\nPress Enter to close...")
	var b [1]byte
	_, _ = os.Stdin.Read(b[:])
}