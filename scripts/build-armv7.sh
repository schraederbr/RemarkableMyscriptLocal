#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 \
  go build -trimpath -ldflags "-s -w" -o dist/rm2hwr-linux-armv7 ./cmd/rm2hwr
echo "built dist/rm2hwr-linux-armv7"
echo "scp dist/rm2hwr-linux-armv7 root@10.11.99.1:/home/root/hwr/bin/rm2hwr"
