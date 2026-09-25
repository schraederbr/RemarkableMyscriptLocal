#!/bin/sh
set -eu

i=0
while [ "$i" -lt 60 ]; do
  if (netstat -lnt 2>/dev/null || ss -lnt 2>/dev/null) | grep -q ':26637[[:space:]]'; then
    exit 0
  fi
  i=$((i + 1))
  sleep 2
done

echo "jonobones API did not listen on 127.0.0.1:26637 within 120 seconds" >&2
exit 1
