#!/usr/bin/env bash
set -euo pipefail

print() { printf '%s\n' "$*"; }

download() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --progress-bar -o "$dest" "$url"
    return $?
  elif command -v wget >/dev/null 2>&1; then
    wget -q --show-progress -O "$dest" "$url"
    return $?
  else
    print "Error: curl or wget is required to download files." >&2
    return 2
  fi
}

read -p "Model directory name (will create models/<name>/): " MODEL_DIR_NAME
MODEL_DIR_NAME="${MODEL_DIR_NAME%%/}"
if [ -z "$MODEL_DIR_NAME" ]; then
  print "Model directory name is required." >&2; exit 1
fi

read -p "Model GGUF URL: " MODEL_URL
if [ -z "$MODEL_URL" ]; then
  print "Model GGUF URL is required." >&2; exit 1
fi

read -p "Projection GGUF URL (leave empty if none): " PROJ_URL

TARGET_DIR="models/$MODEL_DIR_NAME"
mkdir -p "$TARGET_DIR"

MODEL_DEST="$TARGET_DIR/${MODEL_DIR_NAME}.gguf"
if [ -f "$MODEL_DEST" ]; then
  read -p "$MODEL_DEST exists. Overwrite? (y/N): " o
  o=${o:-N}
  if [[ ! "$o" =~ ^[Yy]$ ]]; then
    print "Aborting: model file exists."; exit 1
  fi
  rm -f "$MODEL_DEST"
fi

PROJ_DEST=""
if [ -n "$PROJ_URL" ]; then
  base=$(basename "$PROJ_URL")
  lname=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  if [[ "$lname" =~ (mmproj(-[^.]*)?) ]]; then
    tag="${BASH_REMATCH[1]}"
    PROJ_NAME="${MODEL_DIR_NAME}_${tag}.gguf"
  else
    PROJ_NAME="${MODEL_DIR_NAME}_mmproj.gguf"
  fi
  PROJ_DEST="$TARGET_DIR/$PROJ_NAME"
  if [ -f "$PROJ_DEST" ]; then
    read -p "$PROJ_DEST exists. Overwrite? (y/N): " o2
    o2=${o2:-N}
    if [[ ! "$o2" =~ ^[Yy]$ ]]; then
      print "Skipping projection download (file exists)."; PROJ_URL=""; PROJ_DEST=""
    else
      rm -f "$PROJ_DEST"
    fi
  fi
fi

print "Starting downloads..."
PIDS=()

download "$MODEL_URL" "$MODEL_DEST" &
PIDS+=("$!")

if [ -n "$PROJ_URL" ]; then
  download "$PROJ_URL" "$PROJ_DEST" &
  PIDS+=("$!")
fi

FAIL=0
for p in "${PIDS[@]:-}"; do
  if ! wait "$p"; then
    print "A download failed (pid $p)." >&2
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  print "One or more downloads failed." >&2
  exit 1
fi

print "Downloads complete. Saved to:"
ls -1 "$TARGET_DIR"

exit 0
