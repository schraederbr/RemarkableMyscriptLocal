package rmv5

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseRealFixture(t *testing.T) {
	path := filepath.Join("..", "..", "testdata", "fixtures", "d94c0b46-d3e2-4f3b-a8ef-e0fb836ad705.rm")
	page, err := ParseFile(path)
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}
	if !strings.Contains(page.Header, "version=5") {
		t.Fatalf("header = %q", page.Header)
	}
	if len(page.Layers) != 1 {
		t.Fatalf("layers = %d, want 1", len(page.Layers))
	}
	strokes := page.InkStrokes()
	if len(strokes) != 111 {
		t.Fatalf("ink strokes = %d, want 111", len(strokes))
	}
	for i, s := range strokes {
		if s.Brush != BrushBallpointV5 {
			t.Fatalf("stroke %d brush = %d, want %d", i, s.Brush, BrushBallpointV5)
		}
		if len(s.Points) < 2 {
			t.Fatalf("stroke %d has %d points", i, len(s.Points))
		}
	}
	if page.Empty() {
		t.Fatal("page should not be empty")
	}
}

func TestRejectV3(t *testing.T) {
	hdr := make([]byte, 43)
	copy(hdr, []byte("reMarkable .lines file, version=3          "))
	_, err := Parse(bytes.NewReader(hdr))
	if err == nil || !strings.Contains(err.Error(), "version") {
		t.Fatalf("expected version error, got %v", err)
	}
}

func TestRejectV6(t *testing.T) {
	hdr := make([]byte, 43)
	copy(hdr, []byte("reMarkable .lines file, version=6          "))
	_, err := Parse(bytes.NewReader(hdr))
	if err == nil || !strings.Contains(err.Error(), "version") {
		t.Fatalf("expected version error, got %v", err)
	}
}

func TestSyntheticV5(t *testing.T) {
	raw := buildSyntheticV5(t)
	page, err := Parse(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	strokes := page.InkStrokes()
	if len(strokes) != 1 {
		t.Fatalf("strokes = %d, want 1 (highlighter+eraser dropped)", len(strokes))
	}
	if len(strokes[0].Points) != 3 {
		t.Fatalf("points = %d, want 3", len(strokes[0].Points))
	}
}

func TestResample(t *testing.T) {
	pts := make([]Point, 500)
	for i := range pts {
		pts[i] = Point{X: float32(i), Y: float32(i)}
	}
	out := resample(pts)
	if len(out) > 400 {
		t.Fatalf("resampled len = %d, want <= 400-ish", len(out))
	}
	if out[0].X != 0 || out[len(out)-1].X != 499 {
		t.Fatalf("first/last not preserved: %#v ... %#v", out[0], out[len(out)-1])
	}
	if len(out) < 2 {
		t.Fatal("resample produced <2 points")
	}
}

func TestClampPressure(t *testing.T) {
	cases := []struct {
		in, want float32
	}{
		{0, 0.01},
		{-1, 0.01},
		{0.005, 0.01},
		{0.5, 0.5},
		{1, 0.99},
		{2, 0.99},
	}
	for _, c := range cases {
		if got := ClampPressure(c.in); got != c.want {
			t.Errorf("ClampPressure(%v) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestDropShortStroke(t *testing.T) {
	var buf bytes.Buffer
	writeHeaderV5(&buf)
	_ = binary.Write(&buf, binary.LittleEndian, uint32(1))                    // layers
	_ = binary.Write(&buf, binary.LittleEndian, uint32(1))                    // strokes
	writeStroke(&buf, BrushBallpointV5, []Point{{X: 1, Y: 1, Pressure: 0.5}}) // 1 point → drop
	page, err := Parse(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if !page.Empty() {
		t.Fatal("expected empty after dropping 1-point stroke")
	}
}

func buildSyntheticV5(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	writeHeaderV5(&buf)
	_ = binary.Write(&buf, binary.LittleEndian, uint32(1))
	// 3 strokes: ballpoint (keep), highlighter (drop), eraser (drop)
	_ = binary.Write(&buf, binary.LittleEndian, uint32(3))
	writeStroke(&buf, BrushBallpointV5, []Point{
		{X: 10, Y: 20, Pressure: 0.4},
		{X: 11, Y: 21, Pressure: 0.5},
		{X: 12, Y: 22, Pressure: 0.6},
	})
	writeStroke(&buf, BrushHighlighterV5, []Point{
		{X: 1, Y: 1, Pressure: 0.2},
		{X: 2, Y: 2, Pressure: 0.2},
	})
	writeStroke(&buf, BrushEraserV3, []Point{
		{X: 3, Y: 3, Pressure: 0.2},
		{X: 4, Y: 4, Pressure: 0.2},
	})
	return buf.Bytes()
}

func writeHeaderV5(buf *bytes.Buffer) {
	hdr := make([]byte, 43)
	copy(hdr, []byte("reMarkable .lines file, version=5          "))
	buf.Write(hdr)
}

func writeStroke(buf *bytes.Buffer, brush uint32, pts []Point) {
	_ = binary.Write(buf, binary.LittleEndian, brush)
	_ = binary.Write(buf, binary.LittleEndian, uint32(0)) // color
	_ = binary.Write(buf, binary.LittleEndian, uint32(0)) // padding
	_ = binary.Write(buf, binary.LittleEndian, float32(2.0))
	_ = binary.Write(buf, binary.LittleEndian, uint32(0)) // unknown v5
	_ = binary.Write(buf, binary.LittleEndian, uint32(len(pts)))
	for _, p := range pts {
		_ = binary.Write(buf, binary.LittleEndian, p.X)
		_ = binary.Write(buf, binary.LittleEndian, p.Y)
		_ = binary.Write(buf, binary.LittleEndian, p.Speed)
		_ = binary.Write(buf, binary.LittleEndian, p.Tilt)
		_ = binary.Write(buf, binary.LittleEndian, p.Width)
		_ = binary.Write(buf, binary.LittleEndian, p.Pressure)
	}
}

func TestWriteSyntheticFixtureFile(t *testing.T) {
	// Ensures testdata/fixtures/synthetic_v5.rm stays in sync if regenerated.
	path := filepath.Join("..", "..", "testdata", "fixtures", "synthetic_v5.rm")
	if _, err := os.Stat(path); err != nil {
		t.Skip("synthetic fixture not present yet")
	}
	page, err := ParseFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.InkStrokes()) != 1 {
		t.Fatalf("synthetic ink strokes = %d", len(page.InkStrokes()))
	}
}
