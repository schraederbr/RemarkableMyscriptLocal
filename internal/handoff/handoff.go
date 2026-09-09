// Package handoff builds NOTE.md and HANDOFF.json after an HWR run.
package handoff

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/schraederbr/RemarkableMyscriptLocal/internal/myscript"
)

// Page is one recognized (or skipped) page.
type Page struct {
	Index    int    `json:"index"`
	PageUUID string `json:"pageUuid"`
	Status   string `json:"status"` // OK|EMPTY|SKIP|MISSING|ERROR|DRY-RUN
	Text     string `json:"text"`
	// SvgPath is a relative filename like "<pageUuid>.svg" when an SVG was written.
	SvgPath string `json:"svgPath,omitempty"`
}

// Payload is the machine-readable handoff for Joplin / agent pipelines.
type Payload struct {
	Title      string `json:"title"`
	DocUUID    string `json:"docUuid"`
	Generated  string `json:"generated"`
	UploadMode string `json:"uploadMode,omitempty"`
	Pages      []Page `json:"pages"`
	FullText   string `json:"fullText"`
}

// BuildFullText concatenates pages into markdown suitable for Joplin.
// mode is text|svg|both (empty → text). Includes OK pages and SKIP pages that
// still have content (text and/or svgPath). Image lines use local filenames;
// joplin-upsert rewrites them to :/resourceId after upload.
func BuildFullText(title string, pages []Page, mode string) string {
	mode = myscript.NormalizeUploadMode(mode)
	wantText := mode == "text" || mode == "both"
	wantSVG := mode == "svg" || mode == "both"

	var b strings.Builder
	b.WriteString("# ")
	b.WriteString(title)
	b.WriteString("\n")
	first := true
	for _, p := range pages {
		if p.Status != "OK" && p.Status != "EMPTY" && p.Status != "SKIP" {
			continue
		}
		text := strings.TrimRight(p.Text, "\n")
		hasText := wantText && text != ""
		hasSVG := wantSVG && p.SvgPath != ""
		if !hasText && !hasSVG {
			continue
		}
		if !first {
			b.WriteString("\n\n---\n\n")
		} else {
			b.WriteString("\n")
		}
		first = false
		pageN := p.Index + 1
		b.WriteString(fmt.Sprintf("## Page %d\n\n", pageN))
		if hasSVG {
			// Use basename so upsert can rewrite ![Page N](file.svg) → :/id
			name := filepath.Base(p.SvgPath)
			b.WriteString(fmt.Sprintf("![Page %d](%s)\n\n", pageN, name))
		}
		if hasText {
			b.WriteString(text)
			b.WriteString("\n")
		}
	}
	return b.String()
}

// WriteArtifacts writes NOTE.md and HANDOFF.json under docOutDir.
func WriteArtifacts(docOutDir, title, docUUID, uploadMode string, pages []Page) error {
	if err := os.MkdirAll(docOutDir, 0o755); err != nil {
		return err
	}
	mode := myscript.NormalizeUploadMode(uploadMode)
	full := BuildFullText(title, pages, mode)
	payload := Payload{
		Title:      title,
		DocUUID:    docUUID,
		Generated:  time.Now().UTC().Format(time.RFC3339),
		UploadMode: mode,
		Pages:      pages,
		FullText:   full,
	}
	raw, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	if err := os.WriteFile(filepath.Join(docOutDir, "HANDOFF.json"), raw, 0o644); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(docOutDir, "NOTE.md"), []byte(full), 0o644)
}
