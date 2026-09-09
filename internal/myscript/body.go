package myscript

import (
	"encoding/json"

	"github.com/schraederbr/RemarkableMyscriptLocal/internal/rmv5"
)

const (
	DefaultXDPI       = 226
	DefaultYDPI       = 226
	PortraitWidth     = 1404
	PortraitHeight    = 1872
	PointTimeStepMs   = 16
)

// Config holds recognition / page settings for the batch body.
type Config struct {
	Lang        string
	ContentType string
	Landscape   bool
}

// StrokePoint is the MyScript ink point shape.
type StrokePoint struct {
	X float32 `json:"x"`
	Y float32 `json:"y"`
	T int     `json:"t"`
	P float32 `json:"p"`
}

// Stroke is one MyScript stroke.
type Stroke struct {
	ID          string        `json:"id,omitempty"`
	PointerType string        `json:"pointerType"`
	X           []float32     `json:"x"`
	Y           []float32     `json:"y"`
	T           []int         `json:"t"`
	P           []float32     `json:"p"`
}

// StrokeGroup wraps strokes.
type StrokeGroup struct {
	Strokes []Stroke `json:"strokes"`
}

// BatchRequest is the MyScript iink batch JSON body.
type BatchRequest struct {
	ContentType      string                 `json:"contentType"`
	ConversionState  string                 `json:"conversionState"`
	XDPI             int                    `json:"xDPI"`
	YDPI             int                    `json:"yDPI"`
	Width            int                    `json:"width"`
	Height           int                    `json:"height"`
	Configuration    map[string]interface{} `json:"configuration"`
	StrokeGroups     []StrokeGroup          `json:"strokeGroups"`
}

// BuildBatchJSON builds the MyScript batch request body from a parsed page.
// Returns (nil, false) when the page has no ink (caller should skip HTTP).
func BuildBatchJSON(page *rmv5.Page, cfg Config) ([]byte, bool, error) {
	strokes := page.InkStrokes()
	if len(strokes) == 0 {
		return nil, false, nil
	}
	lang := cfg.Lang
	if lang == "" {
		lang = "en_US"
	}
	ct := cfg.ContentType
	if ct == "" {
		ct = "Text"
	}
	w, h := PortraitWidth, PortraitHeight
	if cfg.Landscape {
		w, h = PortraitHeight, PortraitWidth
	}

	msStrokes := make([]Stroke, 0, len(strokes))
	for _, s := range strokes {
		xs := make([]float32, len(s.Points))
		ys := make([]float32, len(s.Points))
		ts := make([]int, len(s.Points))
		ps := make([]float32, len(s.Points))
		for i, pt := range s.Points {
			x, y := pt.X, pt.Y
			if cfg.Landscape {
				// Swap axes for landscape notebooks.
				x, y = pt.Y, pt.X
			}
			xs[i] = x
			ys[i] = y
			ts[i] = i * PointTimeStepMs
			ps[i] = rmv5.ClampPressure(pt.Pressure)
		}
		msStrokes = append(msStrokes, Stroke{
			PointerType: "PEN",
			X:           xs,
			Y:           ys,
			T:           ts,
			P:           ps,
		})
	}

	req := BatchRequest{
		ContentType:     ct,
		ConversionState: "DIGITAL_EDIT",
		XDPI:            DefaultXDPI,
		YDPI:            DefaultYDPI,
		Width:           w,
		Height:          h,
		Configuration: map[string]interface{}{
			"lang": lang,
		},
		StrokeGroups: []StrokeGroup{{Strokes: msStrokes}},
	}
	raw, err := json.Marshal(req)
	if err != nil {
		return nil, false, err
	}
	return raw, true, nil
}
