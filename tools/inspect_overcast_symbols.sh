#!/bin/sh
set -eu
IPA_PATH="${1:-}"
if [ -z "$IPA_PATH" ]; then
  echo "usage: $0 /path/to/Overcast.ipa" >&2
  exit 1
fi
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
unzip -q "$IPA_PATH" -d "$TMP_DIR"
BIN="$TMP_DIR/Payload/Overcast.app/Overcast"
if [ ! -f "$BIN" ]; then
  echo "Overcast binary not found" >&2
  exit 1
fi
strings -a "$BIN" | grep -iE 'silence|smart.?speed|skip|peak|amplitude|audio|playbackSpeed|signature|voice.?boost|music' | sort -u
