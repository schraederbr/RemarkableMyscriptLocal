package handoff

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildFullText(t *testing.T) {
	pages := []Page{
		{Index: 0, PageUUID: "a", Status: "OK", Text: "hello\n"},
		{Index: 1, PageUUID: "b", Status: "EMPTY", Text: ""},
		{Index: 2, PageUUID: "c", Status: "SKIP", Text: "ignored"},
		{Index: 3, PageUUID: "d", Status: "OK", Text: "world"},
	}
	got := BuildFullText("9-8-26", pages)
	if !strings.HasPrefix(got, "# 9-8-26\n") {
		t.Fatalf("title missing: %q", got)
	}
	if !strings.Contains(got, "## Page 1\n\nhello") {
		t.Fatalf("page 1 missing: %q", got)
	}
	if !strings.Contains(got, "## Page 4\n\nworld") {
		t.Fatalf("page 4 missing: %q", got)
	}
	if strings.Contains(got, "## Page 2") || strings.Contains(got, "ignored") {
		t.Fatalf("empty/skip leaked: %q", got)
	}
	if !strings.Contains(got, "\n\n---\n\n") {
		t.Fatalf("missing separator: %q", got)
	}
}

func TestWriteArtifacts(t *testing.T) {
	dir := t.TempDir()
	pages := []Page{{Index: 0, PageUUID: "p1", Status: "OK", Text: "note body\n"}}
	if err := WriteArtifacts(dir, "Test Note", "doc-uuid", pages); err != nil {
		t.Fatal(err)
	}
	md, err := os.ReadFile(filepath.Join(dir, "NOTE.md"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(md), "# Test Note") {
		t.Fatalf("NOTE.md: %s", md)
	}
	raw, err := os.ReadFile(filepath.Join(dir, "HANDOFF.json"))
	if err != nil {
		t.Fatal(err)
	}
	var p Payload
	if err := json.Unmarshal(raw, &p); err != nil {
		t.Fatal(err)
	}
	if p.Title != "Test Note" || p.DocUUID != "doc-uuid" || p.FullText == "" {
		t.Fatalf("payload: %+v", p)
	}
	if len(p.Pages) != 1 || p.Pages[0].Status != "OK" {
		t.Fatalf("pages: %+v", p.Pages)
	}
}
