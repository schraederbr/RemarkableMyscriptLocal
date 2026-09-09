// Package rmv6 parses reMarkable .rm page files (lines format version 6).
//
// It converts SceneLineItem strokes into the same *rmv5.Page / Stroke / Point
// shapes used by myscript.BuildBatchJSON.
//
// Coordinate transform (documented):
//
//	v6 stores x with origin at page centre and y with origin at page top.
//	MyScript/v5 expect top-left origin, y down, portrait 1404?1872:
//	  x_out = x + 1404/2
//	  y_out = y
//
// Typed text (RootText 0x07) and non-line scene blocks are ignored for the
// MyScript stroke path. Only enough TLV is parsed to recover pen + points;
// unknown tags inside a block are skipped by type.
package rmv6

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"math"
	"os"
	"strings"

	"github.com/schraederbr/RemarkableMyscriptLocal/internal/rmv5"
)

const (
	headerLen    = 43
	headerPrefix = "reMarkable .lines file, version="
	pageWidthPx  = 1404
	pageHeightPx = 1872                     // documented portrait size; landscape handled upstream
	xOriginShift = float32(pageWidthPx) / 2 // 702: v6 x is page-centre origin

	blockTypeSceneLineItem = 0x05

	tagTypeByte1   = 0x1
	tagTypeByte4   = 0x4
	tagTypeByte8   = 0x8
	tagTypeLength4 = 0xC
	tagTypeID      = 0xF

	maxPointsKeep = 400
)

// Pen / brush IDs (v1 and v2 tooling).
const (
	PenPaintbrushV1  uint32 = 0
	PenPencilV1      uint32 = 1
	PenBallpointV1   uint32 = 2
	PenMarkerV1      uint32 = 3
	PenFinelinerV1   uint32 = 4
	PenHighlighterV1 uint32 = 5
	PenEraser        uint32 = 6
	PenMechPencilV1  uint32 = 7
	PenEraserArea    uint32 = 8
	PenPaintbrushV2  uint32 = 12
	PenMechPencilV2  uint32 = 13
	PenPencilV2      uint32 = 14
	PenBallpointV2   uint32 = 15
	PenMarkerV2      uint32 = 16
	PenFinelinerV2   uint32 = 17
	PenHighlighterV2 uint32 = 18
	PenCalligraphy   uint32 = 21
	PenShader        uint32 = 23
)

// ParseFile opens path and parses a v6 .rm page into an rmv5-compatible Page.
func ParseFile(path string) (*rmv5.Page, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return Parse(f)
}

// Parse reads a v6 .rm page from r and returns strokes in rmv5 coordinate space.
func Parse(r io.Reader) (*rmv5.Page, error) {
	hdr := make([]byte, headerLen)
	if _, err := io.ReadFull(r, hdr); err != nil {
		return nil, fmt.Errorf("rmv6: read header: %w", err)
	}
	header := string(hdr)
	if !strings.Contains(header, "version=6") {
		ver := "?"
		if i := strings.Index(header, "version="); i >= 0 {
			ver = strings.TrimSpace(header[i+len("version="):])
		}
		return nil, fmt.Errorf("rmv6: unsupported .rm version %q (only version=6)", ver)
	}

	page := &rmv5.Page{
		Header: strings.TrimRight(header, "\x00 "),
		Layers: []rmv5.Layer{{}}, // single flat layer of kept ink
	}

	for {
		var size uint32
		err := binary.Read(r, binary.LittleEndian, &size)
		if err == io.EOF {
			break
		}
		if err != nil {
			// Clean EOF after last block.
			if err == io.ErrUnexpectedEOF {
				break
			}
			return nil, fmt.Errorf("rmv6: read block size: %w", err)
		}
		meta := make([]byte, 4)
		if _, err := io.ReadFull(r, meta); err != nil {
			return nil, fmt.Errorf("rmv6: read block meta: %w", err)
		}
		// meta: unknown, min_version, current_version, block_type
		currentVersion := meta[2]
		blockType := meta[3]

		content := make([]byte, size)
		if size > 0 {
			if _, err := io.ReadFull(r, content); err != nil {
				return nil, fmt.Errorf("rmv6: read block content (type=0x%02x size=%d): %w", blockType, size, err)
			}
		}

		if blockType != blockTypeSceneLineItem {
			continue // skip RootText and other scene blocks for HWR stroke path
		}

		stroke, keep, err := parseSceneLineItem(content, currentVersion)
		if err != nil {
			return nil, fmt.Errorf("rmv6: SceneLineItem: %w", err)
		}
		if keep {
			page.Layers[0].Strokes = append(page.Layers[0].Strokes, stroke)
		}
	}

	return page, nil
}

func parseSceneLineItem(content []byte, pointVersion uint8) (rmv5.Stroke, bool, error) {
	tr := &tagReader{b: content}
	// Common SceneItem header.
	if err := tr.expectID(1); err != nil {
		return rmv5.Stroke{}, false, fmt.Errorf("parent_id: %w", err)
	}
	if err := tr.expectID(2); err != nil {
		return rmv5.Stroke{}, false, fmt.Errorf("item_id: %w", err)
	}
	if err := tr.expectID(3); err != nil {
		return rmv5.Stroke{}, false, fmt.Errorf("left_id: %w", err)
	}
	if err := tr.expectID(4); err != nil {
		return rmv5.Stroke{}, false, fmt.Errorf("right_id: %w", err)
	}
	deleted, err := tr.readU32(5)
	if err != nil {
		return rmv5.Stroke{}, false, fmt.Errorf("deleted_length: %w", err)
	}
	if deleted != 0 {
		return rmv5.Stroke{}, false, nil // tombstoned
	}

	val, err := tr.expectSubblock(6)
	if err != nil {
		// No value subblock ? nothing to emit.
		if err == errMissingTag {
			return rmv5.Stroke{}, false, nil
		}
		return rmv5.Stroke{}, false, fmt.Errorf("value: %w", err)
	}
	if len(val) == 0 {
		return rmv5.Stroke{}, false, nil
	}

	itemType := val[0]
	if itemType != 0x03 {
		return rmv5.Stroke{}, false, nil
	}
	return parseLineValue(val[1:], pointVersion)
}

func parseLineValue(content []byte, pointVersion uint8) (rmv5.Stroke, bool, error) {
	tr := &tagReader{b: content}

	pen, err := tr.readU32(1)
	if err != nil {
		return rmv5.Stroke{}, false, fmt.Errorf("pen_type_id: %w", err)
	}
	color, err := tr.readU32(2)
	if err != nil {
		return rmv5.Stroke{}, false, fmt.Errorf("colour_id: %w", err)
	}
	thickness, err := tr.readF64(3)
	if err != nil {
		return rmv5.Stroke{}, false, fmt.Errorf("thickness_scale: %w", err)
	}
	// starting_length is float32 tagged as Byte4
	if _, err := tr.readF32(4); err != nil {
		return rmv5.Stroke{}, false, fmt.Errorf("starting_length: %w", err)
	}
	pointsBlob, err := tr.readSubblock(5)
	if err != nil {
		return rmv5.Stroke{}, false, fmt.Errorf("points_data: %w", err)
	}

	// Remaining tags (timestamp, move_id, rgba) optional ? skip robustly.
	_ = tr.skipRest()

	if !shouldKeepPen(pen) {
		if !isKnownDropPen(pen) {
			log.Printf("rmv6: skipping unknown pen id %d", pen)
		}
		return rmv5.Stroke{}, false, nil
	}

	pts, err := parsePoints(pointsBlob, pointVersion)
	if err != nil {
		return rmv5.Stroke{}, false, err
	}
	pts = resample(pts)
	if len(pts) < 2 {
		return rmv5.Stroke{}, false, nil
	}

	return rmv5.Stroke{
		Brush:  pen,
		Color:  color,
		Width:  float32(thickness),
		Points: pts,
	}, true, nil
}

func parsePoints(blob []byte, version uint8) ([]rmv5.Point, error) {
	var pointSize int
	switch version {
	case 1:
		pointSize = 24
	case 2:
		pointSize = 14
	default:
		// Firmware 3+ uses v2; treat unknown as v2 if divisible by 14, else v1.
		if len(blob)%14 == 0 {
			version = 2
			pointSize = 14
		} else if len(blob)%24 == 0 {
			version = 1
			pointSize = 24
		} else {
			return nil, fmt.Errorf("unsupported point version %d (blob %d bytes)", version, len(blob))
		}
	}
	if pointSize == 0 || len(blob)%pointSize != 0 {
		return nil, fmt.Errorf("points blob length %d not multiple of %d (version %d)", len(blob), pointSize, version)
	}
	n := len(blob) / pointSize
	out := make([]rmv5.Point, 0, n)
	for i := 0; i < n; i++ {
		off := i * pointSize
		p, err := decodePoint(blob[off:off+pointSize], version)
		if err != nil {
			return nil, fmt.Errorf("point %d: %w", i, err)
		}
		out = append(out, p)
	}
	return out, nil
}

func decodePoint(b []byte, version uint8) (rmv5.Point, error) {
	x := math.Float32frombits(binary.LittleEndian.Uint32(b[0:4]))
	y := math.Float32frombits(binary.LittleEndian.Uint32(b[4:8]))
	// Convert v6 centre-x / top-y ? top-left origin (same as v5 / MyScript).
	xOut := x + xOriginShift
	yOut := y

	var speed, tilt, width, pressure float32
	switch version {
	case 1:
		// On disk: raw-ish floats; pressure already ~0?1 (see rmscene write path).
		speed = math.Float32frombits(binary.LittleEndian.Uint32(b[8:12]))
		tilt = math.Float32frombits(binary.LittleEndian.Uint32(b[12:16]))
		width = math.Float32frombits(binary.LittleEndian.Uint32(b[16:20]))
		pressure = math.Float32frombits(binary.LittleEndian.Uint32(b[20:24]))
		// If pressure looks like 0?255 scale, normalize.
		if pressure > 1.5 {
			pressure = pressure / 255
		}
	case 2:
		speed = float32(binary.LittleEndian.Uint16(b[8:10]))
		width = float32(binary.LittleEndian.Uint16(b[10:12]))
		tilt = float32(b[12])
		pressure = float32(b[13]) / 255 // u8 0?255 ? ~0?1
	default:
		return rmv5.Point{}, fmt.Errorf("bad point version %d", version)
	}
	return rmv5.Point{
		X:        xOut,
		Y:        yOut,
		Speed:    speed,
		Tilt:     tilt,
		Width:    width,
		Pressure: pressure,
	}, nil
}

func shouldKeepPen(pen uint32) bool {
	switch pen {
	case PenPaintbrushV1, PenPencilV1, PenBallpointV1, PenMarkerV1, PenFinelinerV1, PenMechPencilV1,
		PenPaintbrushV2, PenMechPencilV2, PenPencilV2, PenBallpointV2, PenMarkerV2, PenFinelinerV2,
		PenCalligraphy: // optional keep
		return true
	default:
		return false
	}
}

func isKnownDropPen(pen uint32) bool {
	switch pen {
	case PenHighlighterV1, PenHighlighterV2, PenEraser, PenEraserArea, PenShader:
		return true
	default:
		return false
	}
}

// resample keeps first/last and every 2nd point when n > 400 (same as rmv5).
func resample(pts []rmv5.Point) []rmv5.Point {
	n := len(pts)
	if n <= maxPointsKeep {
		return pts
	}
	out := make([]rmv5.Point, 0, (n/2)+2)
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
	if len(out) < 2 && n >= 2 {
		return []rmv5.Point{pts[0], pts[n-1]}
	}
	return out
}
