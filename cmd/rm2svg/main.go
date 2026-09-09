package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/schraederbr/RemarkableMyscriptLocal/internal/rm"
	"github.com/schraederbr/RemarkableMyscriptLocal/internal/svg"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: rm2svg in.rm out.svg")
		os.Exit(2)
	}
	in, out := os.Args[1], os.Args[2]
	page, err := rm.ParseFile(in)
	if err != nil {
		fmt.Fprintf(os.Stderr, "parse: %v\n", err)
		os.Exit(1)
	}
	raw := svg.Render(page)
	if raw == nil {
		fmt.Fprintf(os.Stderr, "no ink strokes; skipping write\n")
		os.Exit(0)
	}
	if err := os.WriteFile(out, raw, 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "write: %v\n", err)
		os.Exit(1)
	}
	abs, _ := filepath.Abs(out)
	fmt.Printf("wrote %s (%d bytes)\n", abs, len(raw))
}
