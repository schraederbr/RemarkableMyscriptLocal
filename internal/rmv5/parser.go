// Package rmv5 parses reMarkable .rm page files (lines format version 5).
//
// Binary layout (little-endian), verified against firmware 2.x fixtures:
//
//	43-byte ASCII header containing "version=5"
//	u32 layer count
//	per layer:
//	  u32 stroke count
//	  per stroke:
//	    u32 brush, u32 color, u32 padding, f32 width,
//	    u32 unknown (v5-only), u32 npoints
//	    npoints × (f32 x, y, speed, tilt, width, pressure)
//
// Brush IDs 12–17 are ink tools kept for HWR; 18 (highlighter) and 6/8 (eraser)
// are dropped. Unknown non-text brushes are logged and skipped.
package rmv5

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"math"
	"os"
	"strings"
)

const (
	headerLen     = 43
	headerPrefix  = "reMarkable .lines file, version="
	pageWidthPx   = 1404
	pageHeightPx  = 1872
	maxPointsKeep = 400
)

// Brush IDs (v5).
const (
	BrushPaintbrushV5  uint32 = 12
	BrushMechPencilV5  uint32 = 13
	BrushPencilV5      uint32 = 14
	BrushBallpointV5   uint32 = 15
	BrushMarkerV5      uint32 = 16
	BrushFinelinerV5   uint32 = 17
	BrushHighlighterV5 uint32 = 18
	BrushEraserV3      uint32 = 6
	BrushEraseAreaV3   uint32 = 8
)

// Point is one sample along a stroke.
type Point struct {
	X, Y     float32
	Speed    float32
	Tilt     float32
	Width    float32
	Pressure float32
}

// Stroke is a single pen stroke.
type Stroke struct {
	Brush  uint32
	Color  uint32
	Width  float32
	Points []Point
}

// Layer groups strokes.
type Layer struct {
	Strokes []Stroke
}

// Page is one .rm file.
type Page struct {
	Header string
	Layers []Layer
}

// ParseFile opens path and parses a v5 .rm page.
func ParseFile(path string) (*Page, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return Parse(f)
}

// Parse reads a v5 .rm page from r.
func Parse(r io.Reader) (*Page, error) {
	hdr := make([]byte, headerLen)
	if _, err := io.ReadFull(r, hdr); err != nil {
		return nil, fmt.Errorf("rmv5: read header: %w", err)
	}
	header := string(hdr)
	if !strings.Contains(header, "version=5") {
		ver := "?"
		if i := strings.Index(header, "version="); i >= 0 {
			ver = strings.TrimSpace(header[i+len("version="):])
		}
		return nil, fmt.Errorf("rmv5: unsupported .rm version %q (this package only parses version=5; use internal/rm for auto-dispatch)", ver)
	}

	var nLayers uint32
	if err := binary.Read(r, binary.LittleEndian, &nLayers); err != nil {
		return nil, fmt.Errorf("rmv5: read layer count: %w", err)
	}

	page := &Page{Header: strings.TrimRight(header, "\x00 "), Layers: make([]Layer, 0, nLayers)}
	for li := uint32(0); li < nLayers; li++ {
		layer, err := readLayer(r)
		if err != nil {
			return nil, fmt.Errorf("rmv5: layer %d: %w", li, err)
		}
		page.Layers = append(page.Layers, layer)
	}
	return page, nil
}

func readLayer(r io.Reader) (Layer, error) {
	var nStrokes uint32
	if err := binary.Read(r, binary.LittleEndian, &nStrokes); err != nil {
		return Layer{}, fmt.Errorf("stroke count: %w", err)
	}
	layer := Layer{Strokes: make([]Stroke, 0, nStrokes)}
	for si := uint32(0); si < nStrokes; si++ {
		stroke, keep, err := readStroke(r)
		if err != nil {
			return Layer{}, fmt.Errorf("stroke %d: %w", si, err)
		}
		if keep {
			layer.Strokes = append(layer.Strokes, stroke)
		}
	}
	return layer, nil
}

func readStroke(r io.Reader) (Stroke, bool, error) {
	var (
		brush, color, padding uint32
		width                 float32
		unknown               uint32
		nPoints               uint32
	)
	if err := binary.Read(r, binary.LittleEndian, &brush); err != nil {
		return Stroke{}, false, err
	}
	if err := binary.Read(r, binary.LittleEndian, &color); err != nil {
		return Stroke{}, false, err
	}
	if err := binary.Read(r, binary.LittleEndian, &padding); err != nil {
		return Stroke{}, false, err
	}
	if err := binary.Read(r, binary.LittleEndian, &width); err != nil {
		return Stroke{}, false, err
	}
	// v5-only unknown field (absent in v3).
	if err := binary.Read(r, binary.LittleEndian, &unknown); err != nil {
		return Stroke{}, false, err
	}
	if err := binary.Read(r, binary.LittleEndian, &nPoints); err != nil {
		return Stroke{}, false, err
	}

	points := make([]Point, nPoints)
	for i := uint32(0); i < nPoints; i++ {
		var p Point
		if err := binary.Read(r, binary.LittleEndian, &p.X); err != nil {
			return Stroke{}, false, fmt.Errorf("point %d: %w", i, err)
		}
		if err := binary.Read(r, binary.LittleEndian, &p.Y); err != nil {
			return Stroke{}, false, fmt.Errorf("point %d: %w", i, err)
		}
		if err := binary.Read(r, binary.LittleEndian, &p.Speed); err != nil {
			return Stroke{}, false, fmt.Errorf("point %d: %w", i, err)
		}
		if err := binary.Read(r, binary.LittleEndian, &p.Tilt); err != nil {
			return Stroke{}, false, fmt.Errorf("point %d: %w", i, err)
		}
		if err := binary.Read(r, binary.LittleEndian, &p.Width); err != nil {
			return Stroke{}, false, fmt.Errorf("point %d: %w", i, err)
		}
		if err := binary.Read(r, binary.LittleEndian, &p.Pressure); err != nil {
			return Stroke{}, false, fmt.Errorf("point %d: %w", i, err)
		}
		points[i] = p
	}

	keep := shouldKeepBrush(brush)
	if !keep {
		if brush != BrushHighlighterV5 && brush != BrushEraserV3 && brush != BrushEraseAreaV3 {
			log.Printf("rmv5: skipping unknown brush id %d (%d points)", brush, nPoints)
		}
		return Stroke{}, false, nil
	}

	points = resample(points)
	if len(points) < 2 {
		// Never emit strokes with fewer than 2 points.
		return Stroke{}, false, nil
	}
	return Stroke{Brush: brush, Color: color, Width: width, Points: points}, true, nil
}

func shouldKeepBrush(brush uint32) bool {
	return brush >= BrushPaintbrushV5 && brush <= BrushFinelinerV5
}

// resample keeps first/last and every 2nd point when n > 400.
func resample(pts []Point) []Point {
	n := len(pts)
	if n <= maxPointsKeep {
		return pts
	}
	out := make([]Point, 0, (n/2)+2)
	out = append(out, pts[0])
	for i := 1; i < n-1; i++ {
		if i%2 == 0 {
			out = append(out, pts[i])
		}
	}
	last := pts[n-1]
	if out[len(out)-1] != last {
		out = append(out, last)
	}
	// Ensure still at least 2 (caller also checks).
	if len(out) < 2 && n >= 2 {
		return []Point{pts[0], pts[n-1]}
	}
	return out
}

// InkStrokes returns all kept strokes across layers.
func (p *Page) InkStrokes() []Stroke {
	var out []Stroke
	for _, l := range p.Layers {
		out = append(out, l.Strokes...)
	}
	return out
}

// Empty reports whether the page has no ink strokes after filtering.
func (p *Page) Empty() bool {
	return len(p.InkStrokes()) == 0
}

// ClampPressure maps tablet pressure into MyScript's preferred (0.01, 0.99) range.
func ClampPressure(p float32) float32 {
	if math.IsNaN(float64(p)) || p <= 0 {
		return 0.01
	}
	if p >= 1 {
		return 0.99
	}
	if p < 0.01 {
		return 0.01
	}
	if p > 0.99 {
		return 0.99
	}
	return p
}

// PageWidth and PageHeight are the reMarkable 2 portrait pixel dimensions.
func PageWidth() int  { return pageWidthPx }
func PageHeight() int { return pageHeightPx }
