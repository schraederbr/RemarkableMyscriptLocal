// Package svg renders content-fit page SVGs from reMarkable ink strokes.
package svg

import (
	"fmt"
	"math"
	"strings"

	"github.com/schraederbr/RemarkableMyscriptLocal/internal/rmv5"
)

const pad = 40.0

// Render returns SVG bytes for the page's ink, or nil when there are no usable strokes.
// viewBox = ink bbox + padding; width/height = ceil(viewBox) at 1:1 (no downscale).
// White background; black polylines with round caps; no page frame.
//
// stroke-width uses the mean of per-point Width values (firmware already folds
// pressure into those). Falls back to the stroke-level Width (pen size /
// thickness_scale) when no positive point widths exist.
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
// Prefer mean per-point width (page-space); fall back to stroke.Width.
func strokeWidth(s rmv5.Stroke) float64 {
	var sum float64
	n := 0
	for _, p := range s.Points {
		if p.Width > 0 {
			sum += float64(p.Width)
			n++
		}
	}
	sw := float64(s.Width)
	if n > 0 {
		sw = sum / float64(n)
	}
	if sw < 0.25 {
		sw = 0.25
	}
	if sw > 24 {
		sw = 24
	}
	return sw
}