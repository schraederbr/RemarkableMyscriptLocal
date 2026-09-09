package rm

import (
	"bytes"
	"encoding/binary"
	"math"
	"path/filepath"
	"strings"
	"testing"

	"github.com/schraederbr/RemarkableMyscriptLocal/internal/rmv6"
)

func TestParseFileV5Fixture(t *testing.T) {
	path := filepath.Join("..", "..", "testdata", "fixtures", "d94c0b46-d3e2-4f3b-a8ef-e0fb836ad705.rm")
	page, err := ParseFile(path)
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}
	if !strings.Contains(page.Header, "version=5") {
		t.Fatalf("header = %q", page.Header)
	}
	if n := len(page.InkStrokes()); n != 111 {
		t.Fatalf("ink strokes = %d, want 111", n)
	}
}

func TestParseSyntheticV5(t *testing.T) {
	path := filepath.Join("..", "..", "testdata", "fixtures", "synthetic_v5.rm")
	page, err := ParseFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.InkStrokes()) != 1 {
		t.Fatalf("strokes = %d", len(page.InkStrokes()))
	}
}

func TestParseSyntheticV6(t *testing.T) {
	raw := buildMinimalV6()
	page, err := Parse(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(page.Header, "version=6") {
		t.Fatalf("header = %q", page.Header)
	}
	strokes := page.InkStrokes()
	if len(strokes) != 1 || len(strokes[0].Points) != 3 {
		t.Fatalf("strokes=%d points=%v", len(strokes), strokes)
	}
	// centre x=0 -> 702
	if math.Abs(float64(strokes[0].Points[0].X-702)) > 0.01 {
		t.Fatalf("x = %v, want 702", strokes[0].Points[0].X)
	}
	if strokes[0].Brush != rmv6.PenBallpointV2 {
		t.Fatalf("brush = %d", strokes[0].Brush)
	}
}

func TestRejectUnsupportedVersion(t *testing.T) {
	hdr := make([]byte, 43)
	copy(hdr, []byte("reMarkable .lines file, version=3          "))
	_, err := Parse(bytes.NewReader(hdr))
	if err == nil || !strings.Contains(err.Error(), "unsupported") {
		t.Fatalf("got %v", err)
	}
}

func TestRejectGarbageHeader(t *testing.T) {
	hdr := bytes.Repeat([]byte("x"), 43)
	_, err := Parse(bytes.NewReader(hdr))
	if err == nil {
		t.Fatal("expected error")
	}
}

func buildMinimalV6() []byte {
	var buf bytes.Buffer
	hdr := make([]byte, 43)
	copy(hdr, []byte("reMarkable .lines file, version=6          "))
	buf.Write(hdr)

	content := encodeOneLine()
	_ = binary.Write(&buf, binary.LittleEndian, uint32(len(content)))
	buf.WriteByte(0)
	buf.WriteByte(2)
	buf.WriteByte(2)
	buf.WriteByte(0x05)
	buf.Write(content)
	return buf.Bytes()
}

func encodeOneLine() []byte {
	var content bytes.Buffer
	writeID(&content, 1, 1, 1)
	writeID(&content, 2, 1, 2)
	writeID(&content, 3, 0, 0)
	writeID(&content, 4, 0, 0)
	writeTaggedU32(&content, 5, 0) // deleted_length

	var val bytes.Buffer
	val.WriteByte(0x03)
	writeTaggedU32(&val, 1, rmv6.PenBallpointV2)
	writeTaggedU32(&val, 2, 0)
	writeTaggedF64(&val, 3, 1.0)
	writeTaggedF32(&val, 4, 0)
	var pts bytes.Buffer
	for _, y := range []float32{10, 20, 30} {
		_ = binary.Write(&pts, binary.LittleEndian, float32(0))
		_ = binary.Write(&pts, binary.LittleEndian, y)
		_ = binary.Write(&pts, binary.LittleEndian, uint16(1))
		_ = binary.Write(&pts, binary.LittleEndian, uint16(2))
		pts.WriteByte(0)
		pts.WriteByte(200)
	}
	writeSubblock(&val, 5, pts.Bytes())
	writeID(&val, 6, 1, 1)
	writeSubblock(&content, 6, val.Bytes())
	return content.Bytes()
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
	writeTag(buf, index, 0xF)
	buf.WriteByte(part1)
	writeVaruint(buf, part2)
}

func writeTaggedU32(buf *bytes.Buffer, index int, v uint32) {
	writeTag(buf, index, 0x4)
	_ = binary.Write(buf, binary.LittleEndian, v)
}

func writeTaggedF32(buf *bytes.Buffer, index int, v float32) {
	writeTag(buf, index, 0x4)
	_ = binary.Write(buf, binary.LittleEndian, v)
}

func writeTaggedF64(buf *bytes.Buffer, index int, v float64) {
	writeTag(buf, index, 0x8)
	_ = binary.Write(buf, binary.LittleEndian, v)
}

func writeSubblock(buf *bytes.Buffer, index int, payload []byte) {
	writeTag(buf, index, 0xC)
	_ = binary.Write(buf, binary.LittleEndian, uint32(len(payload)))
	buf.Write(payload)
}
