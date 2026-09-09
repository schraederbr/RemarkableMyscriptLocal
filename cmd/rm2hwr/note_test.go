package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildNoteMarkdown(t *testing.T) {
	got := buildNoteMarkdown("9-8-26", []notePage{
		{Number: 1, Body: "line one\nline two"},
		{Number: 2, Body: "_empty_"},
	})
	want := "# 9-8-26\n\n## Page 1\n\nline one\nline two\n\n---\n\n## Page 2\n\n_empty_\n"
	if got != want {
		t.Fatalf("got:\n%q\nwant:\n%q", got, want)
	}
}

func TestResolvePageBody(t *testing.T) {
	dir := t.TempDir()
	okPath := filepath.Join(dir, "ok.txt")
	emptyPath := filepath.Join(dir, "empty.txt")
	missingPath := filepath.Join(dir, "nope.txt")
	if err := os.WriteFile(okPath, []byte("hello\nworld\n\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(emptyPath, []byte("  \n"), 0o644); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		status string
		path   string
		want   string
	}{
		{"OK", okPath, "hello\nworld"},
		{"OK", emptyPath, "_empty_"},
		{"OK", missingPath, "_empty_"},
		{"EMPTY", emptyPath, "_empty_"},
		{"SKIP", okPath, "hello\nworld"},
		{"SKIP", missingPath, "_empty_"},
		{"ERROR", okPath, "_error_"},
		{"MISSING", okPath, "_missing_"},
		{"DRY-RUN", okPath, "hello\nworld"},
		{"DRY-RUN", missingPath, "_dry-run_"},
		{"DRY-RUN", emptyPath, "_dry-run_"},
	}
	for _, tc := range cases {
		got := resolvePageBody(tc.status, tc.path)
		if got != tc.want {
			t.Errorf("resolvePageBody(%q, %s)=%q want %q", tc.status, filepath.Base(tc.path), got, tc.want)
		}
	}
}

func TestResolvePageBodyKeepsInternalNewlines(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "p.txt")
	raw := "a\n\nb\n  "
	if err := os.WriteFile(p, []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
	got := resolvePageBody("OK", p)
	if !strings.Contains(got, "\n\n") {
		t.Fatalf("internal blank line lost: %q", got)
	}
	if strings.HasSuffix(got, " ") || strings.HasSuffix(got, "\n") {
		t.Fatalf("trailing whitespace not trimmed: %q", got)
	}
}
