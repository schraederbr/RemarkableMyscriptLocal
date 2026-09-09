package main

import (
	"fmt"
	"os"
	"strings"
)

// notePage is one section in NOTE.md.
type notePage struct {
	Number int // 1-based page number shown in the heading
	Body   string
}

// pageOutcome records what processDoc decided for a page.
type pageOutcome struct {
	Index    int // 0-based index in the document page list
	PageUUID string
	Status   string // OK, EMPTY, SKIP, ERROR, MISSING, DRY-RUN
}

// resolvePageBody picks the NOTE.md body for one page status + optional .txt path.
func resolvePageBody(status, txtPath string) string {
	readTrimmed := func() (content string, present bool) {
		data, err := os.ReadFile(txtPath)
		if err != nil {
			return "", false
		}
		s := strings.TrimRight(string(data), " \t\r\n")
		return s, true
	}

	switch status {
	case "ERROR":
		return "_error_"
	case "MISSING":
		return "_missing_"
	case "DRY-RUN":
		if s, ok := readTrimmed(); ok && s != "" {
			return s
		}
		return "_dry-run_"
	case "SKIP":
		if s, ok := readTrimmed(); ok && s != "" {
			return s
		}
		return "_empty_"
	case "OK", "EMPTY":
		if s, ok := readTrimmed(); ok && s != "" {
			return s
		}
		return "_empty_"
	default:
		if s, ok := readTrimmed(); ok && s != "" {
			return s
		}
		return "_empty_"
	}
}

// buildNoteMarkdown builds the Joplin-mirror markdown for a document.
// Pages are separated by a horizontal rule; bodies are already resolved.
func buildNoteMarkdown(visibleName string, pages []notePage) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n", visibleName)
	for i, p := range pages {
		if i > 0 {
			b.WriteString("\n---\n")
		}
		fmt.Fprintf(&b, "\n## Page %d\n\n%s\n", p.Number, p.Body)
	}
	return b.String()
}
