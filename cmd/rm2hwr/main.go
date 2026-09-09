// Command rm2hwr recognizes reMarkable 2 handwriting via MyScript cloud
// and writes plaintext under /home/root/hwr/out/.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/schraederbr/RemarkableMyscriptLocal/internal/handoff"
	"github.com/schraederbr/RemarkableMyscriptLocal/internal/myscript"
	"github.com/schraederbr/RemarkableMyscriptLocal/internal/notebook"
	"github.com/schraederbr/RemarkableMyscriptLocal/internal/rmv5"
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("rm2hwr: ")

	var (
		all          = flag.Bool("all", false, "process all notebooks")
		name         = flag.String("name", "", "substring match on visibleName")
		uuid         = flag.String("uuid", "", "document UUID")
		page         = flag.String("page", "", "single page UUID")
		dryRun       = flag.Bool("dry-run", false, "write MyScript JSON only; skip HTTP")
		xochitl      = flag.String("xochitl", notebook.DefaultXochitl, "xochitl documents directory")
		outdir       = flag.String("outdir", "/home/root/hwr/out", "output root directory")
		envFile      = flag.String("env", "/home/root/hwr/conf/hwr.env", "hwr.env path")
		joplinUpsert = flag.Bool("joplin-upsert", false, "after HWR, upsert NOTE.md into jonobones by title")
		upsertBin    = flag.String("joplin-upsert-bin", "/home/root/hwr/scripts/joplin-upsert.js", "path to joplin-upsert.js")
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
		fmt.Fprintf(os.Stderr, "usage: rm2hwr --all | --name SUBSTR | --uuid DOC [--page PAGE] [--dry-run] [--joplin-upsert] [--xochitl DIR] [--outdir DIR] [--env FILE]\n")
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
		docOut, err := processDoc(doc, *page, *outdir, *dryRun, env, client)
		if err != nil {
			log.Printf("document %s (%s): %v", doc.UUID, doc.Meta.VisibleName, err)
			continue
		}
		if *joplinUpsert && !*dryRun && docOut != "" {
			if err := runJoplinUpsert(*upsertBin, docOut); err != nil {
				log.Printf("document %s: joplin-upsert: %v", doc.UUID, err)
			}
		}
	}
}

func runJoplinUpsert(bin, docOut string) error {
	node, err := exec.LookPath("node")
	if err != nil {
		return fmt.Errorf("node not in PATH (need jonobones Node install): %w", err)
	}
	if _, err := os.Stat(bin); err != nil {
		return fmt.Errorf("upsert script: %w", err)
	}
	cmd := exec.Command(node, bin, docOut)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func processDoc(doc *notebook.Document, pageFilter, outdir string, dryRun bool, env *myscript.Env, client *myscript.Client) (string, error) {
	pages := doc.Pages(pageFilter)
	if len(pages) == 0 {
		return "", fmt.Errorf("no pages matched")
	}
	docOut := filepath.Join(outdir, doc.UUID)
	if err := os.MkdirAll(docOut, 0o755); err != nil {
		return "", err
	}

	var indexLines []string
	indexLines = append(indexLines, fmt.Sprintf("# %s (%s)", doc.Meta.VisibleName, doc.UUID))
	indexLines = append(indexLines, fmt.Sprintf("# generated %s", time.Now().UTC().Format(time.RFC3339)))

	cfg := myscript.Config{
		Lang:        env.Lang,
		ContentType: env.ContentType,
		Landscape:   doc.Landscape(),
	}

	var handoffPages []handoff.Page

	for _, pref := range pages {
		txtPath, jsonPath, _ := notebook.OutPaths(outdir, doc.UUID, pref.PageUUID)
		linePrefix := fmt.Sprintf("page %d %s", pref.Index, pref.PageUUID)

		if _, err := os.Stat(pref.RMPath); err != nil {
			log.Printf("%s: missing .rm, skip", linePrefix)
			indexLines = append(indexLines, fmt.Sprintf("%d\t%s\tMISSING", pref.Index, pref.PageUUID))
			handoffPages = append(handoffPages, handoff.Page{Index: pref.Index, PageUUID: pref.PageUUID, Status: "MISSING"})
			continue
		}

		if !dryRun && notebook.ShouldSkip(pref.RMPath, txtPath) {
			log.Printf("%s: out txt newer than .rm, skip", linePrefix)
			indexLines = append(indexLines, fmt.Sprintf("%d\t%s\tSKIP", pref.Index, pref.PageUUID))
			text := ""
			if b, err := os.ReadFile(txtPath); err == nil {
				text = string(b)
			}
			handoffPages = append(handoffPages, handoff.Page{Index: pref.Index, PageUUID: pref.PageUUID, Status: "SKIP", Text: text})
			continue
		}

		page, err := rmv5.ParseFile(pref.RMPath)
		if err != nil {
			log.Printf("%s: parse: %v", linePrefix, err)
			indexLines = append(indexLines, fmt.Sprintf("%d\t%s\tERROR", pref.Index, pref.PageUUID))
			handoffPages = append(handoffPages, handoff.Page{Index: pref.Index, PageUUID: pref.PageUUID, Status: "ERROR"})
			continue
		}

		body, ok, err := myscript.BuildBatchJSON(page, cfg)
		if err != nil {
			return "", fmt.Errorf("%s: build json: %w", linePrefix, err)
		}
		if !ok {
			// Empty page → empty txt, skip HTTP.
			if err := os.WriteFile(txtPath, []byte{}, 0o644); err != nil {
				return "", err
			}
			log.Printf("%s: empty page → empty txt", linePrefix)
			indexLines = append(indexLines, fmt.Sprintf("%d\t%s\tEMPTY", pref.Index, pref.PageUUID))
			handoffPages = append(handoffPages, handoff.Page{Index: pref.Index, PageUUID: pref.PageUUID, Status: "EMPTY"})
			continue
		}

		if dryRun {
			if err := os.WriteFile(jsonPath, body, 0o644); err != nil {
				return "", err
			}
			log.Printf("%s: dry-run wrote %s", linePrefix, jsonPath)
			indexLines = append(indexLines, fmt.Sprintf("%d\t%s\tDRY-RUN", pref.Index, pref.PageUUID))
			handoffPages = append(handoffPages, handoff.Page{Index: pref.Index, PageUUID: pref.PageUUID, Status: "DRY-RUN"})
			continue
		}

		// Also keep JSON alongside plaintext for debugging (optional).
		_ = os.WriteFile(jsonPath, body, 0o644)

		text, err := client.Recognize(body)
		if err != nil {
			log.Printf("%s: recognize: %v", linePrefix, err)
			indexLines = append(indexLines, fmt.Sprintf("%d\t%s\tERROR", pref.Index, pref.PageUUID))
			handoffPages = append(handoffPages, handoff.Page{Index: pref.Index, PageUUID: pref.PageUUID, Status: "ERROR"})
			continue
		}
		if !strings.HasSuffix(text, "\n") {
			text += "\n"
		}
		if err := os.WriteFile(txtPath, []byte(text), 0o644); err != nil {
			return "", err
		}
		log.Printf("%s: wrote %s (%d bytes)", linePrefix, txtPath, len(text))
		indexLines = append(indexLines, fmt.Sprintf("%d\t%s\tOK", pref.Index, pref.PageUUID))
		handoffPages = append(handoffPages, handoff.Page{Index: pref.Index, PageUUID: pref.PageUUID, Status: "OK", Text: text})
	}

	_, _, indexPath := notebook.OutPaths(outdir, doc.UUID, "")
	if err := os.WriteFile(indexPath, []byte(strings.Join(indexLines, "\n")+"\n"), 0o644); err != nil {
		return "", err
	}

	// For SKIP pages we already loaded text; for dry-run leave FullText thin.
	if err := handoff.WriteArtifacts(docOut, doc.Meta.VisibleName, doc.UUID, handoffPages); err != nil {
		return docOut, fmt.Errorf("handoff artifacts: %w", err)
	}
	log.Printf("document %s: wrote NOTE.md + HANDOFF.json", doc.UUID)
	return docOut, nil
}
