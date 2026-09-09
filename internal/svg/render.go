// Package svg renders content-fit page SVGs from reMarkable ink strokes.
package svg

import (
	"fmt"
	"math"
	"strings"

	"github.com/schraederbr/RemarkableMyscriptLocal/internal/rmv5"
	"github.com/schraederbr/RemarkableMyscriptLocal/internal/rmv6"
)

const pad = 40.0

// Render returns SVG bytes for the page's ink, or nil when there are no usable strokes.
// viewBox = ink bbox + padding; width/height = ceil(viewBox) at 1:1 (no downscale).
// White background; black polylines with round caps; no page frame.
//
// Stroke width policy (aligned with modern rm→svg tools, not classic maxio polynomials):
//
//   - Prefer mean of per-point Width values already in page space. Firmware bakes
//     pressure into those; v6 point-format v2 uint16 widths are decoded as /4 in
//     rmv6 (rmscene stores width as float*4 / uint16*4; rmc formulas use width/4).
//   - We emit one polyline per stroke (unlike rmc's per-segment widths), so the
//     mean is the practical single-width approximation of rmc's point-width path.
//   - Fallback when no positive point widths: stroke-level thickness_scale
//     (Stroke.Width), with fineliner *1.8 like rmc Fineliner(base_width * 1.8).
//
// Citations:
//   https://github.com/ricklupton/rmc/blob/main/src/rmc/exporters/writing_tools.py
//   https://github.com/ricklupton/rmc/blob/main/src/rmc/exporters/svg.py
//   https://github.com/ricklupton/rmscene/blob/main/src/rmscene/scene_stream.py
//     (point_from_stream: v1 width=round(float*4); v2 width=uint16)
// Classic maxio/rM2svg 32w²−116w+107 is legacy and intentionally not used.
func Render(page *rmv5.Page) []byte {
	if page == nil {
		return nil
	}
	strokes := page.InkStrokes()
	if len(strokes) == 0 {
		return nil
	}

	minX, minY := float32(math.MaxFloat32), float32(math.MaxFloat32)
	maxX, maxY := float32(-math.MaxFloat32), float32(-math.MaxFloat32)
	usable := 0
	for _, s := range strokes {
		if len(s.Points) < 2 {
			continue
		}
		usable++
		for _, p := range s.Points {
			if p.X < minX {
				minX = p.X
			}
			if p.Y < minY {
				minY = p.Y
			}
			if p.X > maxX {
				maxX = p.X
			}
			if p.Y > maxY {
				maxY = p.Y
			}
		}
	}
	if usable == 0 {
		return nil
	}

	vbX := float64(minX) - pad
	vbY := float64(minY) - pad
	vbW := float64(maxX-minX) + 2*pad
	vbH := float64(maxY-minY) + 2*pad
	if vbW < 1 {
		vbW = 1
	}
	if vbH < 1 {
		vbH = 1
	}
	widthAttr := int(math.Ceil(vbW))
	heightAttr := int(math.Ceil(vbH))

	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="UTF-8"?>` + "\n")
	b.WriteString(fmt.Sprintf(
		`<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="%.2f %.2f %.2f %.2f">`+"\n",
		widthAttr, heightAttr, vbX, vbY, vbW, vbH,
	))
	b.WriteString(fmt.Sprintf(
		`  <rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="white"/>`+"\n",
		vbX, vbY, vbW, vbH,
	))

	for _, s := range strokes {
		if len(s.Points) < 2 {
			continue
		}
		pts := make([]string, 0, len(s.Points))
		for _, p := range s.Points {
			pts = append(pts, fmt.Sprintf("%.2f,%.2f", p.X, p.Y))
		}
		sw := strokeWidth(s)
		b.WriteString(fmt.Sprintf(
			`  <polyline fill="none" stroke="#111" stroke-width="%.2f" stroke-linecap="round" stroke-linejoin="round" points="%s"/>`+"\n",
			sw, strings.Join(pts, " "),
		))
	}
	b.WriteString("</svg>\n")
	return []byte(b.String())
}

// strokeWidth returns SVG user-unit stroke-width for one polyline.
// Prefer mean page-space per-point width; else thickness_scale with pen factor.
func strokeWidth(s rmv5.Stroke) float64 {
	var sum float64
	n := 0
	for _, p := range s.Points {
		if p.Width > 0 {
			sum += float64(p.Width)
			n++
		}
	}
	var sw float64
	if n > 0 {
		sw = sum / float64(n)
	} else {
		sw = fallbackThickness(s)
	}
	if sw < 0.25 {
		sw = 0.25
	}
	if sw > 24 {
		sw = 24
	}
	return sw
}

// fallbackThickness mirrors rmc when point widths are missing:
// fineliner uses thickness_scale * 1.8; other pens use raw thickness_scale.
func fallbackThickness(s rmv5.Stroke) float64 {
	sw := float64(s.Width)
	switch s.Brush {
	case rmv5.BrushFinelinerV5, rmv6.PenFinelinerV1: // 17 (== PenFinelinerV2), 4
		sw *= 1.8
	}
	return sw
}