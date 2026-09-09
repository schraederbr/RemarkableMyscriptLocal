// Package notebook discovers reMarkable xochitl documents and their .rm pages.
package notebook

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const DefaultXochitl = "/home/root/.local/share/remarkable/xochitl"

// Metadata is the .metadata sidecar.
type Metadata struct {
	Deleted     bool   `json:"deleted"`
	Parent      string `json:"parent"`
	Type        string `json:"type"`
	VisibleName string `json:"visibleName"`
}

// Content is the .content sidecar.
type Content struct {
	FileType    string   `json:"fileType"`
	Orientation string   `json:"orientation"`
	PageCount   int      `json:"pageCount"`
	Pages       []string `json:"pages"`
}

// Document is one notebook (or other document) under xochitl.
type Document struct {
	UUID     string
	Meta     Metadata
	Content  Content
	Dir      string // xochitl root
	MetaPath string
}

// PageRef points at one page's .rm file.
type PageRef struct {
	Doc      *Document
	PageUUID string
	Index    int
	RMPath   string
}

// Landscape reports whether the notebook is landscape-oriented.
func (d *Document) Landscape() bool {
	return strings.EqualFold(d.Content.Orientation, "landscape")
}

// Find selects documents under xochitlDir.
// Exactly one of all / nameSubstr / uuid must be set (enforced by CLI).
func Find(xochitlDir string, all bool, nameSubstr, uuid string) ([]*Document, error) {
	entries, err := os.ReadDir(xochitlDir)
	if err != nil {
		return nil, fmt.Errorf("notebook: read xochitl: %w", err)
	}
	var docs []*Document
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".metadata") {
			continue
		}
		id := strings.TrimSuffix(name, ".metadata")
		if uuid != "" && id != uuid {
			continue
		}
		metaPath := filepath.Join(xochitlDir, name)
		raw, err := os.ReadFile(metaPath)
		if err != nil {
			continue
		}
		var meta Metadata
		if err := json.Unmarshal(raw, &meta); err != nil {
			continue
		}
		if meta.Deleted || meta.Type != "DocumentType" {
			continue
		}
		if nameSubstr != "" && !strings.Contains(strings.ToLower(meta.VisibleName), strings.ToLower(nameSubstr)) {
			continue
		}
		contentPath := filepath.Join(xochitlDir, id+".content")
		craw, err := os.ReadFile(contentPath)
		if err != nil {
			continue
		}
		var content Content
		if err := json.Unmarshal(craw, &content); err != nil {
			continue
		}
		if content.FileType != "" && content.FileType != "notebook" {
			// Still allow notebooks; skip pdf/epub without pages.
			if len(content.Pages) == 0 {
				continue
			}
		}
		docs = append(docs, &Document{
			UUID:     id,
			Meta:     meta,
			Content:  content,
			Dir:      xochitlDir,
			MetaPath: metaPath,
		})
	}
	if uuid != "" && len(docs) == 0 {
		return nil, fmt.Errorf("notebook: no document with uuid %s", uuid)
	}
	if nameSubstr != "" && len(docs) == 0 {
		return nil, fmt.Errorf("notebook: no document matching name %q", nameSubstr)
	}
	return docs, nil
}

// Pages returns page refs, optionally filtered by page UUID.
func (d *Document) Pages(pageFilter string) []PageRef {
	var out []PageRef
	for i, pid := range d.Content.Pages {
		if pageFilter != "" && pid != pageFilter {
			continue
		}
		// Pages live at <xochitl>/<doc-uuid>/<page-uuid>.rm
		rm := filepath.Join(d.Dir, d.UUID, pid+".rm")
		out = append(out, PageRef{Doc: d, PageUUID: pid, Index: i, RMPath: rm})
	}
	return out
}

// OutPaths returns plaintext / optional json / index paths under outDir.
func OutPaths(outDir, docUUID, pageUUID string) (txt, js, index string) {
	base := filepath.Join(outDir, docUUID)
	return filepath.Join(base, pageUUID+".txt"),
		filepath.Join(base, pageUUID+".json"),
		filepath.Join(base, "INDEX.txt")
}

// ShouldSkip returns true when out txt exists and is newer than the .rm.
func ShouldSkip(rmPath, txtPath string) bool {
	rmInfo, err := os.Stat(rmPath)
	if err != nil {
		return false
	}
	txtInfo, err := os.Stat(txtPath)
	if err != nil {
		return false
	}
	return !txtInfo.ModTime().Before(rmInfo.ModTime())
}
