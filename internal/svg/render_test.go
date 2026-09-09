package svg

import (
	"strings"
	"testing"

	"github.com/schraederbr/RemarkableMyscriptLocal/internal/rmv5"
)

func TestRenderEmpty(t *testing.T) {
	if got := Render(nil); got != nil {
		t.Fatalf("nil page: got %d bytes", len(got))
	}
	if got := Render(&rmv5.Page{}); got != nil {
		t.Fatalf("empty page: got %d bytes", len(got))
	}
	page := &rmv5.Page{Layers: []rmv5.Layer{{
		Strokes: []rmv5.Stroke{{Width: 2, Points: []rmv5.Point{{X: 1, Y: 1}}}},
	}}}
	if got := Render(page); got != nil {
		t.Fatalf("single-point stroke: got %d bytes", len(got))
	}
}

func TestRenderContentFit(t *testing.T) {
	page := &rmv5.Page{Layers: []rmv5.Layer{{
		Strokes: []rmv5.Stroke{{
			Width: 2,
			Points: []rmv5.Point{
				{X: 100, Y: 200},
				{X: 150, Y: 250},
				{X: 200, Y: 220},
			},
		}},
	}}}
	raw := Render(page)
	if raw == nil {
		t.Fatal("expected SVG bytes")
	}
	s := string(raw)
	if !strings.Contains(s, `xmlns="http://www.w3.org/2000/svg"`) {
		t.Fatalf("missing svg xmlns: %s", s)
	}
	if !strings.Contains(s, `fill="white"`) {
		t.Fatalf("missing white background: %s", s)
	}
	if !strings.Contains(s, `<polyline`) {
		t.Fatalf("missing polyline: %s", s)
	}
	if strings.Contains(s, "stroke-dasharray") || strings.Contains(s, "#ccc") {
		t.Fatalf("unexpected page frame: %s", s)
	}
	// bbox 100..200 x 200..250 + pad 40 => viewBox 60 160 180 130
	if !strings.Contains(s, `viewBox="60.00 160.00 180.00 130.00"`) {
		t.Fatalf("unexpected viewBox: %s", s)
	}
	if !strings.Contains(s, `width="180" height="130"`) {
		t.Fatalf("unexpected width/height: %s", s)
	}
	if !strings.Contains(s, "100.00,200.00 150.00,250.00 200.00,220.00") {
		t.Fatalf("missing points: %s", s)
	}
}
