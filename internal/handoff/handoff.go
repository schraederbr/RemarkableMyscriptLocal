// Package handoff builds NOTE.md and HANDOFF.json after an HWR run.
package handoff

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Page is one recognized (or skipped) page.
type Page struct {
	Index    int    `json:"index"`
	PageUUID string `json:"pageUuid"`
	Status   string `json:"status"` // OK|EMPTY|SKIP|MISSING|ERROR|DRY-RUN
	Text     string `json:"text"`
}

// Payload is the machine-readable handoff for Joplin / agent pipelines.
type Payload struct {
	Title     string `json:"title"`
	DocUUID   string `json:"docUuid"`
	Generated string `json:"generated"`
	Pages     []Page `json:"pages"`
	FullText  string `json:"fullText"`
}

// BuildFullText concatenates pages into markdown suitable for Joplin.
func BuildFullText(title string, pages []Page) string {
	var b strings.Builder
	b.WriteString("# ")
	b.WriteString(title)
	b.WriteString("\n")
	first := true
	for _, p := range pages {
		if p.Status != "OK" && p.Status != "EMPTY" {
			continue
		}
		text := strings.TrimRight(p.Text, "\n")
		if p.Status == "EMPTY" || text == "" {
			continue
		}
		if !first {
			b.WriteString("\n\n---\n\n")
		} else {
			b.WriteString("\n")
		}
		first = false
		b.WriteString(fmt.Sprintf("## Page %d\n\n", p.Index+1))
		b.WriteString(text)
		b.WriteString("\n")
	}
	return b.String()
}

// WriteArtifacts writes NOTE.md and HANDOFF.json under docOutDir.
func WriteArtifacts(docOutDir, title, docUUID string, pages []Page) error {
	if err := os.MkdirAll(docOutDir, 0o755); err != nil {
		return err
	}
	full := BuildFullText(title, pages)
	payload := Payload{
		Title:     title,
		DocUUID:   docUUID,
		Generated: time.Now().UTC().Format(time.RFC3339),
		Pages:     pages,
		FullText:  full,
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
