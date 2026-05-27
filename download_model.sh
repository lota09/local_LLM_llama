#!/usr/bin/env bash
set -euo pipefail

print() { printf '%s\n' "$*"; }

download() {
  local url="$1" dest="$2" max_retries=3 attempt=1

  print "Downloading: $url"
  print "Destination: $dest"

  while [ $attempt -le $max_retries ]; do
    if command -v curl >/dev/null 2>&1; then
      # curl with resume capability (-C -)
      if [ -f "$dest" ]; then
        print "Resume 모드로 다운로드 재개 중... (시도 $attempt/$max_retries)"
        curl -L --fail --progress-bar -C - -o "$dest" "$url"
      else
        curl -L --fail --progress-bar -o "$dest" "$url"
      fi
      if [ $? -eq 0 ]; then
        print "✓ 다운로드 완료"
        return 0
      fi
    elif command -v wget >/dev/null 2>&1; then
      # wget with resume capability (-c)
      if [ -f "$dest" ]; then
        print "Resume 모드로 다운로드 재개 중... (시도 $attempt/$max_retries)"
        wget -q --show-progress -c -O "$dest" "$url"
      else
        wget -q --show-progress -O "$dest" "$url"
      fi
      if [ $? -eq 0 ]; then
        print "✓ 다운로드 완료"
        return 0
      fi
    else
      print "Error: curl or wget is required to download files." >&2
      return 2
    fi

    if [ $attempt -lt $max_retries ]; then
      wait_time=$((attempt * 10))
      print "⚠ 다운로드 실패. ${wait_time}초 후 재시도..."
      sleep "$wait_time"
    fi
    ((attempt++))
  done

  print "Error: 다운로드 최대 시도 횟수 초과" >&2
  [ -f "$dest" ] && rm -f "$dest"
  return 1
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
