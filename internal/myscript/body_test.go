package myscript

import (
	"encoding/json"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/schraederbr/RemarkableMyscriptLocal/internal/rmv5"
)

func TestBuildBatchJSONFromFixture(t *testing.T) {
	_, file, _, _ := runtime.Caller(0)
	rm := filepath.Join(filepath.Dir(file), "..", "..", "testdata", "fixtures", "d94c0b46-d3e2-4f3b-a8ef-e0fb836ad705.rm")
	page, err := rmv5.ParseFile(rm)
	if err != nil {
		t.Fatal(err)
	}
	raw, ok, err := BuildBatchJSON(page, Config{Lang: "en_US", ContentType: "Text"})
	if err != nil || !ok {
		t.Fatalf("ok=%v err=%v", ok, err)
	}
	var req BatchRequest
	if err := json.Unmarshal(raw, &req); err != nil {
		t.Fatal(err)
	}
	if req.ConversionState != "DIGITAL_EDIT" {
		t.Fatal(req.ConversionState)
	}
	if req.Width != 1404 || req.Height != 1872 {
		t.Fatalf("size %dx%d", req.Width, req.Height)
	}
	if req.XDPI != 226 {
		t.Fatal(req.XDPI)
	}
	if len(req.StrokeGroups) != 1 || len(req.StrokeGroups[0].Strokes) != 111 {
		t.Fatalf("strokes=%d", len(req.StrokeGroups[0].Strokes))
	}
	s0 := req.StrokeGroups[0].Strokes[0]
	if s0.PointerType != "PEN" {
		t.Fatal(s0.PointerType)
	}
	if len(s0.X) < 2 || len(s0.X) != len(s0.Y) || len(s0.X) != len(s0.T) || len(s0.X) != len(s0.P) {
		t.Fatalf("point arrays mismatched: %d", len(s0.X))
	}
	if s0.T[1] != 16 {
		t.Fatalf("t step = %d", s0.T[1])
	}
	if s0.P[0] < 0.01 || s0.P[0] > 0.99 {
		t.Fatalf("p=%v", s0.P[0])
	}
}
