// Package rm dispatches reMarkable .rm page parsing by header version.
//
// Supported:
//
//	version=5 ? internal/rmv5
//	version=6 ? internal/rmv6 (SceneLineItem strokes ? *rmv5.Page)
//
// Any other version returns a clear error.
package rm

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/schraederbr/RemarkableMyscriptLocal/internal/rmv5"
	"github.com/schraederbr/RemarkableMyscriptLocal/internal/rmv6"
)

const headerLen = 43

// ParseFile opens path, peeks the 43-byte header, and dispatches to the
// appropriate parser. Both paths return *rmv5.Page for myscript.BuildBatchJSON.
func ParseFile(path string) (*rmv5.Page, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return Parse(f)
}

// Parse peeks the .rm header and dispatches to v5 or v6.
func Parse(r io.Reader) (*rmv5.Page, error) {
	hdr := make([]byte, headerLen)
	if _, err := io.ReadFull(r, hdr); err != nil {
		return nil, fmt.Errorf("rm: read header: %w", err)
	}
	ver, err := headerVersion(hdr)
	if err != nil {
		return nil, err
	}
	rest := io.MultiReader(bytes.NewReader(hdr), r)
	switch ver {
	case 5:
		return rmv5.Parse(rest)
	case 6:
		return rmv6.Parse(rest)
	default:
		return nil, fmt.Errorf("rm: unsupported .rm version=%d (supported: 5, 6)", ver)
	}
}

func headerVersion(hdr []byte) (int, error) {
	if len(hdr) < headerLen {
		return 0, fmt.Errorf("rm: header too short (%d bytes)", len(hdr))
	}
	s := string(hdr)
	const key = "version="
	i := strings.Index(s, key)
	if i < 0 {
		return 0, fmt.Errorf("rm: not a reMarkable .lines header %q", strings.TrimRight(s, "\x00 "))
	}
	rest := strings.TrimSpace(s[i+len(key):])
	if rest == "" {
		return 0, fmt.Errorf("rm: empty version in header")
	}
	// version is a single digit in practice (5 or 6), space-padded.
	n := 0
	for _, c := range rest {
		if c < '0' || c > '9' {
			break
		}
		n = n*10 + int(c-'0')
	}
	if n == 0 && (rest[0] < '0' || rest[0] > '9') {
		return 0, fmt.Errorf("rm: cannot parse version from %q", strings.TrimRight(s, "\x00 "))
	}
	return n, nil
}
