#!/usr/bin/env bash
# Extract the performance reference WAV from its tracked zip archive.
# The PCM is bit-identical to the original file (verified by SHA-256).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
if [[ ! -f D07B53F5.wav ]]; then
  echo "==> Extracting D07B53F5.wav.zip"
  unzip -o -q D07B53F5.wav.zip -d "$REPO_ROOT"
fi
printf '%s  %s\n' "e5975e82cf8cef0da8571de2a5da72d7d7b8bd6836637e14a879955ef2e4a529" "D07B53F5.wav" \
  | shasum -a 256 -c -
