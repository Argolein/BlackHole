#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_FILE="$SCRIPT_DIR/blackholectl.swift"
OUTPUT_FILE="$SCRIPT_DIR/blackholectl"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found in PATH" >&2
  exit 1
fi

swiftc -O "$SOURCE_FILE" -o "$OUTPUT_FILE"
chmod +x "$OUTPUT_FILE"

echo "Built: $OUTPUT_FILE"
