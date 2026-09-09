package handoff

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildFullTextTextMode(t *testing.T) {
	pages := []Page{
		{Index: 0, PageUUID: "a", Status: "OK", Text: "hello\n"},
		{Index: 1, PageUUID: "b", Status: "EMPTY", Text: ""},
		{Index: 2, PageUUID: "c", Status: "SKIP", Text: "ignored"},
		{Index: 3, PageUUID: "d", Status: "OK", Text: "world"},
	}
	got := BuildFullText("9-8-26", pages, "text")
	if !strings.HasPrefix(got, "# 9-8-26\n") {
		t.Fatalf("title missing: %q", got)
	}
	if !strings.Contains(got, "## Page 1\n\nhello") {
		t.Fatalf("page 1 missing: %q", got)
	}
	if !strings.Contains(got, "## Page 4\n\nworld") {
		t.Fatalf("page 4 missing: %q", got)
	}
	// SKIP with text is included in text mode
	if !strings.Contains(got, "## Page 3\n\nignored") {
		t.Fatalf("skip with text missing: %q", got)
	}
	if strings.Contains(got, "## Page 2") {
		t.Fatalf("empty leaked: %q", got)
	}
	if !strings.Contains(got, "\n\n---\n\n") {
		t.Fatalf("missing separator: %q", got)
	}
	if strings.Contains(got, "![Page") {
		t.Fatalf("text mode should not embed images: %q", got)
	}
}

func TestBuildFullTextSVGAndBoth(t *testing.T) {
	pages := []Page{
		{Index: 0, PageUUID: "a", Status: "OK", Text: "hello\n", SvgPath: "a.svg"},
		{Index: 1, PageUUID: "b", Status: "OK", Text: "", SvgPath: "b.svg"},
		{Index: 2, PageUUID: "c", Status: "EMPTY", Text: ""},
	}
	svgOnly := BuildFullText("Note", pages, "svg")
	if !strings.Contains(svgOnly, "![Page 1](a.svg)") {
		t.Fatalf("svg page1: %q", svgOnly)
	}
	if !strings.Contains(svgOnly, "![Page 2](b.svg)") {
		t.Fatalf("svg page2: %q", svgOnly)
	}
	if strings.Contains(svgOnly, "hello") {
		t.Fatalf("svg mode should omit text: %q", svgOnly)
	}
	if strings.Contains(svgOnly, "## Page 3") {
		t.Fatalf("empty page in svg: %q", svgOnly)
	}

	both := BuildFullText("Note", pages, "both")
	if !strings.Contains(both, "![Page 1](a.svg)\n\nhello") {
		t.Fatalf("both page1: %q", both)
	}
	if !strings.Contains(both, "![Page 2](b.svg)") {
		t.Fatalf("both page2: %q", both)
	}
	if strings.Contains(both, "## Page 3") {
		t.Fatalf("empty in both: %q", both)
	}
}

func TestWriteArtifacts(t *testing.T) {
	dir := t.TempDir()
	pages := []Page{{Index: 0, PageUUID: "p1", Status: "OK", Text: "note body\n", SvgPath: "p1.svg"}}
	if err := WriteArtifacts(dir, "Test Note", "doc-uuid", "both", pages); err != nil {
		t.Fatal(err)
	}
	md, err := os.ReadFile(filepath.Join(dir, "NOTE.md"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(md), "# Test Note") {
		t.Fatalf("NOTE.md: %s", md)
	}
	if !strings.Contains(string(md), "![Page 1](p1.svg)") {
		t.Fatalf("NOTE.md missing image: %s", md)
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
	if p.UploadMode != "both" {
		t.Fatalf("uploadMode: %q", p.UploadMode)
	}
	if len(p.Pages) != 1 || p.Pages[0].Status != "OK" || p.Pages[0].SvgPath != "p1.svg" {
		t.Fatalf("pages: %+v", p.Pages)
	}
}
