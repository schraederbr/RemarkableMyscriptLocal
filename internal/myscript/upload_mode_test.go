package myscript

import "testing"

func TestNormalizeUploadMode(t *testing.T) {
	cases := map[string]string{
		"": "text", "TEXT": "text", "svg": "svg", "Both": "both", "nope": "text",
	}
	for in, want := range cases {
		if got := NormalizeUploadMode(in); got != want {
			t.Fatalf("%q: got %q want %q", in, got, want)
		}
	}
}

func TestWantTextSVG(t *testing.T) {
	e := &Env{UploadMode: "text"}
	if !e.WantText() || e.WantSVG() {
		t.Fatalf("text: %+v", e)
	}
	e.UploadMode = "svg"
	if e.WantText() || !e.WantSVG() {
		t.Fatalf("svg: %+v", e)
	}
	e.UploadMode = "both"
	if !e.WantText() || !e.WantSVG() {
		t.Fatalf("both: %+v", e)
	}
	e.UploadMode = ""
	if !e.WantText() || e.WantSVG() {
		t.Fatalf("empty defaults to text: %+v", e)
	}
}
