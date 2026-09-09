package notebook

import (
	"path/filepath"
	"runtime"
	"testing"
)

func testdataXochitl(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("no caller")
	}
	return filepath.Join(filepath.Dir(file), "..", "..", "testdata", "xochitl")
}

func TestFindByName(t *testing.T) {
	docs, err := Find(testdataXochitl(t), false, "9-8", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(docs) != 1 {
		t.Fatalf("docs=%d", len(docs))
	}
	if docs[0].Meta.VisibleName != "9-8-26" {
		t.Fatalf("name=%q", docs[0].Meta.VisibleName)
	}
	pages := docs[0].Pages("")
	if len(pages) != 2 {
		t.Fatalf("pages=%d", len(pages))
	}
	// First page fixture exists.
	if _, err := filepath.Glob(pages[0].RMPath); err != nil {
		t.Fatal(err)
	}
}

func TestFindByUUID(t *testing.T) {
	id := "9b01e5c7-3a46-47d1-9bfd-cbf232ac8c9d"
	docs, err := Find(testdataXochitl(t), false, "", id)
	if err != nil {
		t.Fatal(err)
	}
	if len(docs) != 1 || docs[0].UUID != id {
		t.Fatalf("%+v", docs)
	}
	if docs[0].Landscape() {
		t.Fatal("fixture is portrait")
	}
}
