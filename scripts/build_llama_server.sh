#!/usr/bin/env bash
set -euo pipefail
# Build and install script for `llama_server/llama-server`
# Defaults to cloning ggerganov/llama.cpp and building; configurable via env vars.

REPO_URL=${REPO_URL:-https://github.com/ggerganov/llama.cpp.git}
BRANCH=${BRANCH:-main}
BUILD_DIR=${BUILD_DIR:-/tmp/llama_build}
INSTALL_DIR=${INSTALL_DIR:-$(pwd)/llama_server}
BACKUP_DIR=${BACKUP_DIR:-$(pwd)/llama_server_backup_$(date +%s)}

echo "Repo: $REPO_URL (branch: $BRANCH)"
echo "Build dir: $BUILD_DIR"
echo "Install dir: $INSTALL_DIR"

if [ -d "$BUILD_DIR" ]; then
  echo "Removing existing build dir $BUILD_DIR"
  rm -rf "$BUILD_DIR"
fi

echo "Cloning..."
git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$BUILD_DIR"

pushd "$BUILD_DIR" >/dev/null

# Detect CUDA / cuBLAS availability
USE_CUBLAS=0
if command -v nvcc >/dev/null 2>&1 || command -v nvidia-smi >/dev/null 2>&1; then
  echo "CUDA toolchain detected — enabling cuBLAS build where supported"
  USE_CUBLAS=1
fi

export MAKEFLAGS="-j$(nproc)"

echo "Running build (USE_CUBLAS=$USE_CUBLAS)..."
if [ "$USE_CUBLAS" -eq 1 ]; then
  make clean >/dev/null 2>&1 || true
  make USE_CUBLAS=1
else
  make clean >/dev/null 2>&1 || true
  make
fi

# Find best candidate binary
echo "Finding built executable..."
BIN_CANDIDATES=("./llama-server" "./build/bin/llama-server" "./main" "./build/main" "./server" "./build/server")
FOUND_BIN=""
for b in "${BIN_CANDIDATES[@]}"; do
  if [ -x "$b" ]; then
    FOUND_BIN="$b"
    break
  fi
done

if [ -z "$FOUND_BIN" ]; then
  # fallback: search for any large executable
  FOUND_BIN=$(find . -type f -executable -printf "%p\n" 2>/dev/null | xargs -r ls -S | head -n1 || true)
fi

if [ -z "$FOUND_BIN" ]; then
  echo "Error: could not find built executable. Inspect build output in $BUILD_DIR" >&2
  popd >/dev/null
  exit 1
fi

echo "Built executable: $FOUND_BIN"

# Prepare install dir
mkdir -p "$INSTALL_DIR"
if [ -f "$INSTALL_DIR/llama-server" ] || [ -f "$INSTALL_DIR/main" ]; then
  echo "Backing up existing install to $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  cp -a "$INSTALL_DIR"/* "$BACKUP_DIR/" || true
fi

TARGET_BIN="$INSTALL_DIR/llama-server"
echo "Installing $FOUND_BIN -> $TARGET_BIN"
cp "$FOUND_BIN" "$TARGET_BIN"
chmod +x "$TARGET_BIN"

# Copy shared libs if present in build output (libllama, libggml)
echo "Copying any built shared libraries (libllama/libggml) to $INSTALL_DIR (if found)"
find . -maxdepth 3 -type f -name 'libllama*.so*' -or -name 'libggml*.so*' | while read -r lib; do
  echo "  -> $lib"
  cp -a "$lib" "$INSTALL_DIR/" || true
done

popd >/dev/null

echo "Build & install complete. Installed binary: $TARGET_BIN"
echo "You can now run: $TARGET_BIN --help"
echo "If the server requires additional libs at runtime, ensure LD_LIBRARY_PATH includes $INSTALL_DIR"

exit 0
