package rmv6

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
)

var errMissingTag = errors.New("missing expected tag")

// tagReader walks TLV fields inside a v6 block/subblock.
type tagReader struct {
	b   []byte
	off int
}

func (t *tagReader) remaining() int { return len(t.b) - t.off }

func (t *tagReader) readVaruint() (uint64, error) {
	var val uint64
	var shift uint
	for {
		if t.off >= len(t.b) {
			return 0, fmt.Errorf("varuint: EOF at %d", t.off)
		}
		b := t.b[t.off]
		t.off++
		val |= uint64(b&0x7f) << shift
		if b&0x80 == 0 {
			return val, nil
		}
		shift += 7
		if shift > 63 {
			return 0, fmt.Errorf("varuint: overflow")
		}
	}
}

func (t *tagReader) peekTag() (index int, typ byte, ok bool) {
	if t.off >= len(t.b) {
		return 0, 0, false
	}
	save := t.off
	v, err := t.readVaruint()
	t.off = save
	if err != nil {
		return 0, 0, false
	}
	return int(v >> 4), byte(v & 0x0f), true
}

func (t *tagReader) readTag() (index int, typ byte, err error) {
	v, err := t.readVaruint()
	if err != nil {
		return 0, 0, err
	}
	return int(v >> 4), byte(v & 0x0f), nil
}

func (t *tagReader) expectTag(wantIndex int, wantType byte) error {
	idx, typ, err := t.readTag()
	if err != nil {
		return err
	}
	if idx != wantIndex || typ != wantType {
		return fmt.Errorf("expected tag index=%d type=0x%X, got index=%d type=0x%X", wantIndex, wantType, idx, typ)
	}
	return nil
}

func (t *tagReader) readBytes(n int) ([]byte, error) {
	if n < 0 || t.off+n > len(t.b) {
		return nil, fmt.Errorf("need %d bytes at offset %d remaining %d", n, t.off, t.remaining())
	}
	out := t.b[t.off : t.off+n]
	t.off += n
	return out, nil
}

func (t *tagReader) skipPayload(typ byte) error {
	switch typ {
	case tagTypeByte1:
		_, err := t.readBytes(1)
		return err
	case tagTypeByte4:
		_, err := t.readBytes(4)
		return err
	case tagTypeByte8:
		_, err := t.readBytes(8)
		return err
	case tagTypeLength4:
		raw, err := t.readBytes(4)
		if err != nil {
			return err
		}
		n := int(binary.LittleEndian.Uint32(raw))
		_, err = t.readBytes(n)
		return err
	case tagTypeID:
		if _, err := t.readBytes(1); err != nil {
			return err
		}
		_, err := t.readVaruint()
		return err
	default:
		return fmt.Errorf("unknown tag type 0x%X", typ)
	}
}

func (t *tagReader) skipRest() error {
	for t.remaining() > 0 {
		_, typ, ok := t.peekTag()
		if !ok {
			return nil
		}
		if _, _, err := t.readTag(); err != nil {
			return err
		}
		if err := t.skipPayload(typ); err != nil {
			return err
		}
	}
	return nil
}

func (t *tagReader) expectID(index int) error {
	if err := t.expectTag(index, tagTypeID); err != nil {
		return err
	}
	if _, err := t.readBytes(1); err != nil {
		return err
	}
	_, err := t.readVaruint()
	return err
}

func (t *tagReader) readU32(index int) (uint32, error) {
	if err := t.expectTag(index, tagTypeByte4); err != nil {
		return 0, err
	}
	raw, err := t.readBytes(4)
	if err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint32(raw), nil
}

func (t *tagReader) readF32(index int) (float32, error) {
	u, err := t.readU32(index)
	if err != nil {
		return 0, err
	}
	return math.Float32frombits(u), nil
}

func (t *tagReader) readF64(index int) (float64, error) {
	if err := t.expectTag(index, tagTypeByte8); err != nil {
		return 0, err
	}
	raw, err := t.readBytes(8)
	if err != nil {
		return 0, err
	}
	return math.Float64frombits(binary.LittleEndian.Uint64(raw)), nil
}

func (t *tagReader) readSubblock(index int) ([]byte, error) {
	if err := t.expectTag(index, tagTypeLength4); err != nil {
		return nil, err
	}
	raw, err := t.readBytes(4)
	if err != nil {
		return nil, err
	}
	n := int(binary.LittleEndian.Uint32(raw))
	return t.readBytes(n)
}

func (t *tagReader) expectSubblock(index int) ([]byte, error) {
	idx, typ, ok := t.peekTag()
	if !ok || idx != index || typ != tagTypeLength4 {
		return nil, errMissingTag
	}
	return t.readSubblock(index)
}
