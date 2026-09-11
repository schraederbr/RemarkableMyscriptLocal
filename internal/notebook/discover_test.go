package notebook

import (
	"encoding/json"
	"os"
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

func TestContentPageIDsLegacyFirmware2(t *testing.T) {
	var content Content
	if err := json.Unmarshal([]byte(`{"fileType":"notebook","pages":["page-a","page-b"]}`), &content); err != nil {
		t.Fatal(err)
	}
	assertPageIDs(t, content.PageIDs(), []string{"page-a", "page-b"})
}

func TestContentPageIDsCPagesFirmware3(t *testing.T) {
	var content Content
	if err := json.Unmarshal([]byte(`{"fileType":"notebook","formatVersion":2,"cPages":{"pages":[{"id":"page-c"},{"id":"page-d"}]}}`), &content); err != nil {
		t.Fatal(err)
	}
	assertPageIDs(t, content.PageIDs(), []string{"page-c", "page-d"})
}

func TestFindFirmware3Content(t *testing.T) {
	dir := t.TempDir()
	id := "firmware-3-document"
	if err := os.WriteFile(filepath.Join(dir, id+".metadata"), []byte(`{"type":"DocumentType","visibleName":"New format"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, id+".content"), []byte(`{"fileType":"notebook","formatVersion":2,"cPages":{"pages":[{"id":"new-page"}]}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	docs, err := Find(dir, false, "", id)
	if err != nil {
		t.Fatal(err)
	}
	pages := docs[0].Pages("")
	if len(pages) != 1 || pages[0].PageUUID != "new-page" {
		t.Fatalf("pages=%+v", pages)
	}
}

func assertPageIDs(t *testing.T, got, want []string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("page ids=%v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("page ids=%v, want %v", got, want)
		}
	}
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
