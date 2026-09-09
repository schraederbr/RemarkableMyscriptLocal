package rmv6

import (
	"bytes"
	"encoding/binary"
	"math"
	"strings"
	"testing"
)

func TestSyntheticV6RoundTrip(t *testing.T) {
	raw := buildSyntheticV6(t, PenBallpointV2, 0, [][2]float32{
		{-100, 50}, // centre-relative → x_out = 602
		{-90, 60},
		{-80, 70},
	}, 128) // pressure mid
	page, err := Parse(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	strokes := page.InkStrokes()
	if len(strokes) != 1 {
		t.Fatalf("strokes = %d, want 1", len(strokes))
	}
	pts := strokes[0].Points
	if len(pts) != 3 {
		t.Fatalf("points = %d, want 3", len(pts))
	}
	// x_out = x + 702
	wantX0 := float32(-100) + 702
	if math.Abs(float64(pts[0].X-wantX0)) > 0.01 {
		t.Fatalf("x[0] = %v, want %v", pts[0].X, wantX0)
	}
	if math.Abs(float64(pts[0].Y-50)) > 0.01 {
		t.Fatalf("y[0] = %v, want 50", pts[0].Y)
	}
	wantP := float32(128) / 255
	if math.Abs(float64(pts[0].Pressure-wantP)) > 0.01 {
		t.Fatalf("pressure = %v, want ~%v", pts[0].Pressure, wantP)
	}
	if strokes[0].Brush != PenBallpointV2 {
		t.Fatalf("brush = %d", strokes[0].Brush)
	}
}

func TestDropHighlighterAndEraser(t *testing.T) {
	var buf bytes.Buffer
	writeHeaderV6(&buf)
	writeSceneLine(&buf, 2, PenBallpointV2, 0, [][2]float32{{0, 1}, {1, 2}}, 200)
	writeSceneLine(&buf, 2, PenHighlighterV2, 0, [][2]float32{{0, 1}, {1, 2}}, 200)
	writeSceneLine(&buf, 2, PenEraser, 0, [][2]float32{{0, 1}, {1, 2}}, 200)
	page, err := Parse(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if n := len(page.InkStrokes()); n != 1 {
		t.Fatalf("kept %d strokes, want 1", n)
	}
}

func TestSkipDeleted(t *testing.T) {
	var buf bytes.Buffer
	writeHeaderV6(&buf)
	writeSceneLineDeleted(&buf, 2, PenBallpointV2, [][2]float32{{0, 1}, {1, 2}})
	page, err := Parse(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if !page.Empty() {
		t.Fatal("deleted line should be skipped")
	}
}

func TestRejectNonV6(t *testing.T) {
	hdr := make([]byte, 43)
	copy(hdr, []byte("reMarkable .lines file, version=5          "))
	_, err := Parse(bytes.NewReader(hdr))
	if err == nil || !strings.Contains(err.Error(), "version") {
		t.Fatalf("got %v", err)
	}
}

func buildSyntheticV6(t *testing.T, pen uint32, color uint32, pts [][2]float32, pressureU8 byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	writeHeaderV6(&buf)
	writeSceneLine(&buf, 2, pen, color, pts, pressureU8)
	return buf.Bytes()
}

func writeHeaderV6(buf *bytes.Buffer) {
	hdr := make([]byte, 43)
	copy(hdr, []byte("reMarkable .lines file, version=6          "))
	buf.Write(hdr)
}

func writeVaruint(buf *bytes.Buffer, v uint64) {
	for v >= 0x80 {
		buf.WriteByte(byte(v) | 0x80)
		v >>= 7
	}
	buf.WriteByte(byte(v))
}

func writeTag(buf *bytes.Buffer, index int, typ byte) {
	writeVaruint(buf, uint64(index<<4)|uint64(typ))
}

func writeID(buf *bytes.Buffer, index int, part1 byte, part2 uint64) {
	writeTag(buf, index, tagTypeID)
	buf.WriteByte(part1)
	writeVaruint(buf, part2)
}

func writeU32(buf *bytes.Buffer, index int, v uint32) {
	writeTag(buf, index, tagTypeByte4)
	_ = binary.Write(buf, binary.LittleEndian, v)
}

func writeF32(buf *bytes.Buffer, index int, v float32) {
	writeTag(buf, index, tagTypeByte4)
	_ = binary.Write(buf, binary.LittleEndian, v)
}

func writeF64(buf *bytes.Buffer, index int, v float64) {
	writeTag(buf, index, tagTypeByte8)
	_ = binary.Write(buf, binary.LittleEndian, v)
}

func writeSubblock(buf *bytes.Buffer, index int, payload []byte) {
	writeTag(buf, index, tagTypeLength4)
	_ = binary.Write(buf, binary.LittleEndian, uint32(len(payload)))
	buf.Write(payload)
}

func writePointV2(buf *bytes.Buffer, x, y float32, pressureU8 byte) {
	_ = binary.Write(buf, binary.LittleEndian, x)
	_ = binary.Write(buf, binary.LittleEndian, y)
	_ = binary.Write(buf, binary.LittleEndian, uint16(10)) // speed
	_ = binary.Write(buf, binary.LittleEndian, uint16(20)) // width
	buf.WriteByte(0)                                       // direction
	buf.WriteByte(pressureU8)
}

func lineValuePayload(pen, color uint32, pts [][2]float32, pressureU8 byte) []byte {
	var val bytes.Buffer
	val.WriteByte(0x03) // item_type SceneLine
	writeU32(&val, 1, pen)
	writeU32(&val, 2, color)
	writeF64(&val, 3, 1.0)
	writeF32(&val, 4, 0)
	var ptsBuf bytes.Buffer
	for _, p := range pts {
		writePointV2(&ptsBuf, p[0], p[1], pressureU8)
	}
	writeSubblock(&val, 5, ptsBuf.Bytes())
	writeID(&val, 6, 1, 1) // timestamp
	return val.Bytes()
}

func writeSceneLine(buf *bytes.Buffer, pointVer byte, pen, color uint32, pts [][2]float32, pressureU8 byte) {
	writeSceneLineEx(buf, pointVer, pen, color, pts, pressureU8, 0)
}

func writeSceneLineDeleted(buf *bytes.Buffer, pointVer byte, pen uint32, pts [][2]float32) {
	writeSceneLineEx(buf, pointVer, pen, 0, pts, 100, 1)
}

func writeSceneLineEx(buf *bytes.Buffer, pointVer byte, pen, color uint32, pts [][2]float32, pressureU8 byte, deleted uint32) {
	var content bytes.Buffer
	writeID(&content, 1, 1, 1) // parent
	writeID(&content, 2, 1, 2) // item
	writeID(&content, 3, 0, 0) // left
	writeID(&content, 4, 0, 0) // right
	writeU32(&content, 5, deleted)
	writeSubblock(&content, 6, lineValuePayload(pen, color, pts, pressureU8))

	body := content.Bytes()
	_ = binary.Write(buf, binary.LittleEndian, uint32(len(body)))
	buf.WriteByte(0)        // unknown
	buf.WriteByte(pointVer) // min_version
	buf.WriteByte(pointVer) // current_version
	buf.WriteByte(blockTypeSceneLineItem)
	buf.Write(body)
}
