// Command rm2hwr recognizes reMarkable 2 handwriting via MyScript cloud
// and writes plaintext under /home/root/hwr/out/.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/schraederbr/RemarkableMyscriptLocal/internal/myscript"
	"github.com/schraederbr/RemarkableMyscriptLocal/internal/notebook"
	"github.com/schraederbr/RemarkableMyscriptLocal/internal/rmv5"
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("rm2hwr: ")

	var (
		all       = flag.Bool("all", false, "process all notebooks")
		name      = flag.String("name", "", "substring match on visibleName")
		uuid      = flag.String("uuid", "", "document UUID")
		page      = flag.String("page", "", "single page UUID")
		dryRun    = flag.Bool("dry-run", false, "write MyScript JSON only; skip HTTP")
		xochitl   = flag.String("xochitl", notebook.DefaultXochitl, "xochitl documents directory")
		outdir    = flag.String("outdir", "/home/root/hwr/out", "output root directory")
		envFile   = flag.String("env", "/home/root/hwr/conf/hwr.env", "hwr.env path")
	)
	flag.Parse()

	selectors := 0
	if *all {
		selectors++
	}
	if *name != "" {
		selectors++
	}
	if *uuid != "" {
		selectors++
	}
	if selectors != 1 {
		fmt.Fprintf(os.Stderr, "usage: rm2hwr --all | --name SUBSTR | --uuid DOC [--page PAGE] [--dry-run] [--xochitl DIR] [--outdir DIR] [--env FILE]\n")
		fmt.Fprintf(os.Stderr, "require exactly one of --all / --name / --uuid\n")
		os.Exit(2)
	}

	var env *myscript.Env
	var client *myscript.Client
	if !*dryRun {
		var err error
		env, err = myscript.LoadEnv(*envFile)
		if err != nil {
			log.Fatalf("load env: %v", err)
		}
		client = myscript.NewClient(env)
	} else {
		// Dry-run still needs lang/contentType defaults.
		env = &myscript.Env{Lang: "en_US", ContentType: "Text"}
		if st, err := os.Stat(*envFile); err == nil && !st.IsDir() {
			if e, err := myscript.LoadEnv(*envFile); err == nil {
				env = e
			}
		}
	}

	docs, err := notebook.Find(*xochitl, *all, *name, *uuid)
	if err != nil {
		log.Fatal(err)
	}
	if len(docs) == 0 {
		log.Print("no documents matched")
		return
	}

	for _, doc := range docs {
		if err := processDoc(doc, *page, *outdir, *dryRun, env, client); err != nil {
			log.Printf("document %s (%s): %v", doc.UUID, doc.Meta.VisibleName, err)
		}
	}
}

func processDoc(doc *notebook.Document, pageFilter, outdir string, dryRun bool, env *myscript.Env, client *myscript.Client) error {
	pages := doc.Pages(pageFilter)
	if len(pages) == 0 {
		return fmt.Errorf("no pages matched")
	}
	docOut := filepath.Join(outdir, doc.UUID)
	if err := os.MkdirAll(docOut, 0o755); err != nil {
		return err
	}

	var indexLines []string
	indexLines = append(indexLines, fmt.Sprintf("# %s (%s)", doc.Meta.VisibleName, doc.UUID))
	indexLines = append(indexLines, fmt.Sprintf("# generated %s", time.Now().UTC().Format(time.RFC3339)))

	cfg := myscript.Config{
		Lang:        env.Lang,
		ContentType: env.ContentType,
		Landscape:   doc.Landscape(),
	}

	for _, pref := range pages {
		txtPath, jsonPath, _ := notebook.OutPaths(outdir, doc.UUID, pref.PageUUID)
		linePrefix := fmt.Sprintf("page %d %s", pref.Index, pref.PageUUID)

		if _, err := os.Stat(pref.RMPath); err != nil {
			log.Printf("%s: missing .rm, skip", linePrefix)
			indexLines = append(indexLines, fmt.Sprintf("%d\t%s\tMISSING", pref.Index, pref.PageUUID))
			continue
		}

		if !dryRun && notebook.ShouldSkip(pref.RMPath, txtPath) {
			log.Printf("%s: out txt newer than .rm, skip", linePrefix)
			indexLines = append(indexLines, fmt.Sprintf("%d\t%s\tSKIP", pref.Index, pref.PageUUID))
			continue
		}

		page, err := rmv5.ParseFile(pref.RMPath)
		if err != nil {
			log.Printf("%s: parse: %v", linePrefix, err)
			indexLines = append(indexLines, fmt.Sprintf("%d\t%s\tERROR", pref.Index, pref.PageUUID))
			continue
		}

		body, ok, err := myscript.BuildBatchJSON(page, cfg)
		if err != nil {
			return fmt.Errorf("%s: build json: %w", linePrefix, err)
		}
		if !ok {
			// Empty page → empty txt, skip HTTP.
			if err := os.WriteFile(txtPath, []byte{}, 0o644); err != nil {
				return err
			}
			log.Printf("%s: empty page → empty txt", linePrefix)
			indexLines = append(indexLines, fmt.Sprintf("%d\t%s\tEMPTY", pref.Index, pref.PageUUID))
			continue
		}

		if dryRun {
			if err := os.WriteFile(jsonPath, body, 0o644); err != nil {
				return err
			}
			log.Printf("%s: dry-run wrote %s", linePrefix, jsonPath)
			indexLines = append(indexLines, fmt.Sprintf("%d\t%s\tDRY-RUN", pref.Index, pref.PageUUID))
			continue
		}

		// Also keep JSON alongside plaintext for debugging (optional).
		_ = os.WriteFile(jsonPath, body, 0o644)

		text, err := client.Recognize(body)
		if err != nil {
			log.Printf("%s: recognize: %v", linePrefix, err)
			indexLines = append(indexLines, fmt.Sprintf("%d\t%s\tERROR", pref.Index, pref.PageUUID))
			continue
		}
		if !strings.HasSuffix(text, "\n") {
			text += "\n"
		}
		if err := os.WriteFile(txtPath, []byte(text), 0o644); err != nil {
			return err
		}
		log.Printf("%s: wrote %s (%d bytes)", linePrefix, txtPath, len(text))
		indexLines = append(indexLines, fmt.Sprintf("%d\t%s\tOK", pref.Index, pref.PageUUID))
	}

	_, _, indexPath := notebook.OutPaths(outdir, doc.UUID, "")
	return os.WriteFile(indexPath, []byte(strings.Join(indexLines, "\n")+"\n"), 0o644)
}
