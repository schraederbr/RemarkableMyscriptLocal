# Cross-compile helpers for reMarkable 2 (linux/arm, GOARM=7, static).

APP      := rm2hwr
MODULE   := github.com/schraederbr/RemarkableMyscriptLocal
OUTDIR   := dist
GOFLAGS  := -trimpath
LDFLAGS  := -s -w

.PHONY: all build test build-armv7 clean

all: test build

build:
	go build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $(OUTDIR)/$(APP) ./cmd/rm2hwr

# reMarkable 2: ARMv7 hard-float, no CGO → single static-ish binary.
build-armv7:
	mkdir -p $(OUTDIR)
	CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 \
		go build $(GOFLAGS) -ldflags "$(LDFLAGS)" \
		-o $(OUTDIR)/$(APP)-linux-armv7 ./cmd/rm2hwr
	@echo "built $(OUTDIR)/$(APP)-linux-armv7"
	@echo "scp to tablet: scp $(OUTDIR)/$(APP)-linux-armv7 root@10.11.99.1:/home/root/hwr/bin/rm2hwr"

test:
	go test ./...

clean:
	rm -rf $(OUTDIR)
