#!/bin/sh
set -eu

logger -t hwr-sync-shortcut "Sync Joplin shortcut tapped"
systemctl start --no-block hwr-sync-recent.service
