package svg

import (
	"strings"
	"testing"

	"github.com/schraederbr/RemarkableMyscriptLocal/internal/rmv5"
	"github.com/schraederbr/RemarkableMyscriptLocal/internal/rmv6"
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
				{X: 100, Y: 200, Width: 3},
				{X: 150, Y: 250, Width: 3},
				{X: 200, Y: 220, Width: 3},
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
	if !strings.Contains(s, `stroke-width="3.00"`) {
		t.Fatalf("expected mean point width 3.00, got: %s", s)
	}
}

func TestStrokeWidthUsesPointMean(t *testing.T) {
	page := &rmv5.Page{Layers: []rmv5.Layer{{
		Strokes: []rmv5.Stroke{{
			Width: 2, // pen size - must NOT win over point widths
			Points: []rmv5.Point{
				{X: 0, Y: 0, Width: 2},
				{X: 10, Y: 0, Width: 4},
				{X: 20, Y: 0, Width: 6},
			},
		}},
	}}}
	s := string(Render(page))
	if !strings.Contains(s, `stroke-width="4.00"`) {
		t.Fatalf("want mean point width 4.00: %s", s)
	}
}

func TestStrokeWidthFallsBackToStrokeWidth(t *testing.T) {
	page := &rmv5.Page{Layers: []rmv5.Layer{{
		Strokes: []rmv5.Stroke{{
			Brush: rmv5.BrushBallpointV5,
			Width: 2.5,
			Points: []rmv5.Point{
				{X: 0, Y: 0},
				{X: 10, Y: 0},
			},
		}},
	}}}
	s := string(Render(page))
	if !strings.Contains(s, `stroke-width="2.50"`) {
		t.Fatalf("want stroke-level fallback 2.50: %s", s)
	}
}

func TestStrokeWidthFinelinerFallbackUsesRmcFactor(t *testing.T) {
	// rmc Fineliner: base_width * 1.8 when using thickness_scale
	page := &rmv5.Page{Layers: []rmv5.Layer{{
		Strokes: []rmv5.Stroke{{
			Brush: rmv5.BrushFinelinerV5,
			Width: 2,
			Points: []rmv5.Point{
				{X: 0, Y: 0},
				{X: 10, Y: 0},
			},
		}},
	}}}
	s := string(Render(page))
	if !strings.Contains(s, `stroke-width="3.60"`) {
		t.Fatalf("want fineliner fallback 2*1.8=3.60: %s", s)
	}

	pageV1 := &rmv5.Page{Layers: []rmv5.Layer{{
		Strokes: []rmv5.Stroke{{
			Brush: rmv6.PenFinelinerV1,
			Width: 2,
			Points: []rmv5.Point{
				{X: 0, Y: 0},
				{X: 10, Y: 0},
			},
		}},
	}}}
	s2 := string(Render(pageV1))
	if !strings.Contains(s2, `stroke-width="3.60"`) {
		t.Fatalf("want v1 fineliner fallback 3.60: %s", s2)
	}
}

func TestStrokeWidthPointMeanBeatsFinelinerFallback(t *testing.T) {
	page := &rmv5.Page{Layers: []rmv5.Layer{{
		Strokes: []rmv5.Stroke{{
			Brush: rmv5.BrushFinelinerV5,
			Width: 2,
			Points: []rmv5.Point{
				{X: 0, Y: 0, Width: 1.5},
				{X: 10, Y: 0, Width: 1.5},
			},
		}},
	}}}
	s := string(Render(page))
	if !strings.Contains(s, `stroke-width="1.50"`) {
		t.Fatalf("point mean must win over fineliner*1.8: %s", s)
	}
}