#!/usr/bin/env bash
set -euo pipefail
# Build and install script for `llama_server/llama-server`
# Uses cmake (current llama.cpp build system).
# Fully automatic: resolves cmake/nvcc from conda or system paths.

REPO_URL=${REPO_URL:-https://github.com/ggerganov/llama.cpp.git}
BUILD_DIR=${BUILD_DIR:-/tmp/llama_build}
INSTALL_DIR=${INSTALL_DIR:-$(pwd)/llama_server}
BACKUP_DIR=${BACKUP_DIR:-$(pwd)/llama_server_backup_$(date +%s)}

# ─────────────────────────────────────────────
# 유틸: 섹션 헤더 출력
# ─────────────────────────────────────────────
section() { echo ""; echo "── $* ──"; }

# ─────────────────────────────────────────────
# 1. 최신 릴리즈 태그 자동 감지
# ─────────────────────────────────────────────
section "1. 최신 릴리즈 태그 확인"
LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/ggerganov/llama.cpp/releases/latest" \
  | grep '"tag_name"' | head -n1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/' || true)

if [ -z "$LATEST_TAG" ]; then
  echo "Warning: GitHub API 응답 실패 → 'master' 브랜치로 폴백"
  CLONE_REF="master"
else
  echo "Latest release: $LATEST_TAG"
  CLONE_REF="$LATEST_TAG"
fi

echo "Repo     : $REPO_URL (ref: $CLONE_REF)"
echo "Build dir: $BUILD_DIR"
echo "Install  : $INSTALL_DIR"

# ─────────────────────────────────────────────
# 2. cmake 자동 탐색 (conda 우선 → 시스템)
#    libstdc++ 버전 불일치 문제를 conda cmake로 우회
# ─────────────────────────────────────────────
section "2. cmake 탐색"

CMAKE_BIN=""

# conda 환경 후보 목록 (활성 env → base → 이름 지정 envs)
CONDA_ROOTS=()
[ -n "${CONDA_PREFIX:-}" ]       && CONDA_ROOTS+=("$CONDA_PREFIX")
[ -n "${CONDA_ROOT:-}" ]         && CONDA_ROOTS+=("$CONDA_ROOT")
[ -d "$HOME/miniconda3" ]        && CONDA_ROOTS+=("$HOME/miniconda3")
[ -d "$HOME/anaconda3" ]         && CONDA_ROOTS+=("$HOME/anaconda3")
[ -d "/opt/conda" ]              && CONDA_ROOTS+=("/opt/conda")

for root in "${CONDA_ROOTS[@]}"; do
  for subdir in "" "/envs/llama_env" "/envs/base"; do
    candidate="$root$subdir/bin/cmake"
    if [ -x "$candidate" ]; then
      CMAKE_BIN="$candidate"
      echo "conda cmake 발견: $CMAKE_BIN"
      break 2
    fi
  done
done

# conda에 없으면 시스템 cmake 시도
if [ -z "$CMAKE_BIN" ]; then
  if command -v cmake >/dev/null 2>&1; then
    CMAKE_BIN="cmake"
    echo "시스템 cmake 사용: $(cmake --version | head -n1)"
  fi
fi

# 그래도 없으면 conda로 설치 시도
if [ -z "$CMAKE_BIN" ]; then
  echo "cmake를 찾을 수 없습니다. conda로 설치 시도..."
  CONDA_CMD=""
  for root in "${CONDA_ROOTS[@]}"; do
    [ -x "$root/bin/conda" ] && CONDA_CMD="$root/bin/conda" && break
  done
  if [ -n "$CONDA_CMD" ]; then
    "$CONDA_CMD" install -y -c conda-forge cmake 2>&1 | tail -5
    # 재탐색
    for root in "${CONDA_ROOTS[@]}"; do
      for subdir in "" "/envs/llama_env"; do
        candidate="$root$subdir/bin/cmake"
        if [ -x "$candidate" ]; then
          CMAKE_BIN="$candidate"
          break 2
        fi
      done
    done
  fi
fi

if [ -z "$CMAKE_BIN" ]; then
  echo "Error: cmake를 설치하거나 찾을 수 없습니다. 수동으로 설치 후 재실행하세요." >&2
  exit 1
fi

echo "사용할 cmake: $CMAKE_BIN"

# cmake가 conda 환경 소속이면 해당 lib를 LD_LIBRARY_PATH에 추가
CMAKE_REALPATH=$(realpath "$CMAKE_BIN" 2>/dev/null || echo "$CMAKE_BIN")
CMAKE_DIR=$(dirname "$CMAKE_REALPATH")
CONDA_ENV_LIB="${CMAKE_DIR%/bin}/lib"
if [ -d "$CONDA_ENV_LIB" ]; then
  export LD_LIBRARY_PATH="$CONDA_ENV_LIB:${LD_LIBRARY_PATH:-}"
  echo "LD_LIBRARY_PATH 앞에 추가: $CONDA_ENV_LIB"
fi

# ─────────────────────────────────────────────
# 3. nvcc (CUDA 컴파일러) 자동 탐색
# ─────────────────────────────────────────────
section "3. CUDA / nvcc 탐색"

NVCC_BIN=""
USE_CUDA=0

# 일반적인 CUDA Toolkit 설치 경로들
CUDA_CANDIDATES=(
  "/usr/local/cuda/bin/nvcc"
  "/usr/local/cuda-12/bin/nvcc"
  "/usr/local/cuda-12.6/bin/nvcc"
  "/usr/local/cuda-12.4/bin/nvcc"
  "/usr/local/cuda-11/bin/nvcc"
  "/usr/cuda/bin/nvcc"
)
# PATH에 있는 nvcc도 후보에 추가
command -v nvcc >/dev/null 2>&1 && CUDA_CANDIDATES+=("$(command -v nvcc)")

for c in "${CUDA_CANDIDATES[@]}"; do
  if [ -x "$c" ]; then
    NVCC_BIN="$c"
    break
  fi
done

# nvcc 못 찾았지만 nvidia-smi는 있는 경우 → 더 넓게 탐색
if [ -z "$NVCC_BIN" ] && command -v nvidia-smi >/dev/null 2>&1; then
  NVCC_BIN=$(find /usr/local -name nvcc -type f 2>/dev/null | head -n1 || true)
fi

if [ -n "$NVCC_BIN" ]; then
  USE_CUDA=1
  CUDA_BIN_DIR=$(dirname "$NVCC_BIN")
  export PATH="$CUDA_BIN_DIR:$PATH"
  export CUDACXX="$NVCC_BIN"
  echo "nvcc 발견: $NVCC_BIN"
  echo "CUDACXX=$CUDACXX"
else
  echo "nvcc를 찾을 수 없습니다 → CPU-only 빌드로 진행"
fi

# ─────────────────────────────────────────────
# 4. cmake 플래그 결정
# ─────────────────────────────────────────────
section "4. 빌드 플래그 결정"

CMAKE_EXTRA_FLAGS=""

if [ "$USE_CUDA" -eq 1 ]; then
  echo "CUDA 빌드 활성화: -DGGML_CUDA=ON"
  CMAKE_EXTRA_FLAGS="$CMAKE_EXTRA_FLAGS -DGGML_CUDA=ON"
else
  echo "CPU-only 빌드"
fi

if [[ "$(uname)" == "Darwin" ]]; then
  echo "macOS 감지 → -DGGML_METAL=ON"
  CMAKE_EXTRA_FLAGS="$CMAKE_EXTRA_FLAGS -DGGML_METAL=ON"
fi

if grep -q avx512f /proc/cpuinfo 2>/dev/null; then
  echo "AVX-512 감지 → -DGGML_AVX512=ON"
  CMAKE_EXTRA_FLAGS="$CMAKE_EXTRA_FLAGS -DGGML_AVX512=ON"
elif grep -q avx2 /proc/cpuinfo 2>/dev/null; then
  echo "AVX2 감지 → -DGGML_AVX2=ON"
  CMAKE_EXTRA_FLAGS="$CMAKE_EXTRA_FLAGS -DGGML_AVX2=ON"
fi

JOBS=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
echo "병렬 빌드 잡: $JOBS"
echo "cmake 추가 플래그:$CMAKE_EXTRA_FLAGS"

# Detect host GCC version and add nvcc override if needed
if [ "$USE_CUDA" -eq 1 ] && command -v gcc >/dev/null 2>&1; then
  GCC_VER=$(gcc -dumpfullversion 2>/dev/null || gcc -dumpversion 2>/dev/null || true)
  GCC_MAJOR=$(echo "$GCC_VER" | cut -d. -f1)
  if [ -n "$GCC_MAJOR" ] && [ "$GCC_MAJOR" -gt 13 ]; then
    echo "Host GCC version $GCC_VER > 13: adding --allow-unsupported-compiler for nvcc"
    # Create an nvcc wrapper that injects --allow-unsupported-compiler so that
    # CMake's CUDA compiler detection compiles test sources successfully.
    WRAPPER_DIR="$BUILD_DIR/nvcc-wrapper"
    mkdir -p "$WRAPPER_DIR"
    REAL_NVCC="$NVCC_BIN"
    if [ -z "$REAL_NVCC" ]; then
      REAL_NVCC=$(command -v nvcc 2>/dev/null || true)
    fi
    if [ -n "$REAL_NVCC" ] && [ -x "$REAL_NVCC" ]; then
      cat > "$WRAPPER_DIR/nvcc" <<'NVCC_WRAPPER'
#!/usr/bin/env bash
# nvcc wrapper to add --allow-unsupported-compiler
REAL_NVCC="__REAL_NVCC__"
args=("$@")
exec "$REAL_NVCC" --allow-unsupported-compiler "${args[@]}"
NVCC_WRAPPER
      sed -i "s|__REAL_NVCC__|$REAL_NVCC|g" "$WRAPPER_DIR/nvcc"
      chmod +x "$WRAPPER_DIR/nvcc"
      export PATH="$WRAPPER_DIR:$PATH"
      echo "Created nvcc wrapper at $WRAPPER_DIR/nvcc -> $REAL_NVCC"
    else
      echo "Warning: nvcc not found to create wrapper; CMake CUDA detection may still fail." >&2
    fi
    # also keep a CMake flag just in case
    CMAKE_EXTRA_FLAGS="$CMAKE_EXTRA_FLAGS -DCMAKE_CUDA_FLAGS=--allow-unsupported-compiler"
  fi
fi

# Try to find a suitable system host gcc for nvcc (prefer <=13). If found,
# pass it to CMake via -DCMAKE_CUDA_HOST_COMPILER so nvcc uses it instead of
# the conda-provided wrappers which can inject incompatible headers.
if [ "$USE_CUDA" -eq 1 ]; then
  echo "Searching for a suitable system host gcc for nvcc..."
  HOST_GCC_CANDIDATES=(/usr/bin/gcc-13 /usr/bin/gcc-12 /usr/bin/gcc-11 /usr/bin/gcc)
  HOST_GCC=""
  for cand in "${HOST_GCC_CANDIDATES[@]}"; do
    if [ -x "$cand" ]; then
      ver=$($cand -dumpfullversion 2>/dev/null || $cand -dumpversion 2>/dev/null || true)
      maj=$(echo "$ver" | cut -d. -f1)
      if [ -n "$maj" ] && [ "$maj" -le 13 ]; then
        HOST_GCC="$cand"
        echo "Selected host gcc: $HOST_GCC (version $ver)"
        break
      fi
    fi
  done
  if [ -z "$HOST_GCC" ]; then
    echo "Warning: No suitable host gcc <=13 found under /usr/bin; CUDA build may fail. Falling back to CPU-only build." >&2
    # disable CUDA to avoid CMake failing
    CMAKE_EXTRA_FLAGS=$(echo "$CMAKE_EXTRA_FLAGS" | sed 's/-DGGML_CUDA=ON//g')
    USE_CUDA=0
  else
    CMAKE_EXTRA_FLAGS="$CMAKE_EXTRA_FLAGS -DCMAKE_CUDA_HOST_COMPILER=$HOST_GCC"
    # Also ensure nvcc wrapper (if created) uses -ccbin to point to chosen host compiler
    if [ -n "${WRAPPER_DIR:-}" ] && [ -x "${WRAPPER_DIR}/nvcc" ]; then
      sed -i "s|exec \"\$REAL_NVCC\" --allow-unsupported-compiler \"\$\{args\[@\]\}\"|exec \"\$REAL_NVCC\" --allow-unsupported-compiler -ccbin=$HOST_GCC \"\$\{args\[@\]\}\"|" "$WRAPPER_DIR/nvcc" 2>/dev/null || true
      echo "Updated nvcc wrapper to pass -ccbin=$HOST_GCC"
    fi
  fi
fi

# ─────────────────────────────────────────────
# 5. 클론
# ─────────────────────────────────────────────
section "5. 소스 클론"

if [ -d "$BUILD_DIR" ]; then
  echo "기존 빌드 디렉터리 삭제: $BUILD_DIR"
  rm -rf "$BUILD_DIR"
fi

echo "Cloning (depth=1, ref=$CLONE_REF)..."
git clone --depth 1 --branch "$CLONE_REF" "$REPO_URL" "$BUILD_DIR"

# ─────────────────────────────────────────────
# 6. cmake 빌드
# ─────────────────────────────────────────────
section "6. cmake 빌드"

pushd "$BUILD_DIR" >/dev/null

CUDA_COMPILER_FLAG=""
[ -n "$NVCC_BIN" ] && CUDA_COMPILER_FLAG="-DCMAKE_CUDA_COMPILER=$NVCC_BIN"

echo "Configuring..."
"$CMAKE_BIN" -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_SERVER=ON \
  $CUDA_COMPILER_FLAG \
  $CMAKE_EXTRA_FLAGS

echo ""
echo "Building..."
"$CMAKE_BIN" --build build --config Release -j"$JOBS"

popd >/dev/null

# ─────────────────────────────────────────────
# 7. 바이너리 탐색
# ─────────────────────────────────────────────
section "7. 바이너리 탐색"

FOUND_BIN=""
for b in \
  "$BUILD_DIR/build/bin/llama-server" \
  "$BUILD_DIR/build/bin/Release/llama-server" \
  "$BUILD_DIR/build/llama-server"; do
  [ -x "$b" ] && FOUND_BIN="$b" && break
done

# fallback: find
[ -z "$FOUND_BIN" ] && \
  FOUND_BIN=$(find "$BUILD_DIR/build" -type f -name "llama-server" -executable 2>/dev/null | head -n1 || true)

if [ -z "$FOUND_BIN" ]; then
  echo "Error: 빌드된 바이너리를 찾을 수 없습니다. $BUILD_DIR 의 빌드 로그를 확인하세요." >&2
  exit 1
fi

echo "발견: $FOUND_BIN"

# ─────────────────────────────────────────────
# 8. 기존 설치 백업 후 설치
# ─────────────────────────────────────────────
section "8. 설치"

mkdir -p "$INSTALL_DIR"

if [ -f "$INSTALL_DIR/llama-server" ]; then
  echo "기존 바이너리 백업: $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  cp -a "$INSTALL_DIR"/. "$BACKUP_DIR/" || true
fi

TARGET_BIN="$INSTALL_DIR/llama-server"
cp "$FOUND_BIN" "$TARGET_BIN"
chmod +x "$TARGET_BIN"
echo "설치 완료: $TARGET_BIN"

# ─────────────────────────────────────────────
# 9. 공유 라이브러리 복사
# ─────────────────────────────────────────────
section "9. 공유 라이브러리 복사"

find "$BUILD_DIR/build" -maxdepth 4 -type f \( \
    -name 'libllama*.so*' \
    -o -name 'libggml*.so*' \
    -o -name 'libllama*.dylib' \
    -o -name 'libggml*.dylib' \
  \) | while read -r lib; do
  echo "  -> $(basename "$lib")"
  cp -a "$lib" "$INSTALL_DIR/" || true
done

# ─────────────────────────────────────────────
# 10. 완료
# ─────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Build & install complete!"
echo "  Binary  : $TARGET_BIN"
echo "  Version : $CLONE_REF"
echo "  CUDA    : $([ $USE_CUDA -eq 1 ] && echo "ON ($NVCC_BIN)" || echo "OFF (CPU-only)")"
echo ""
echo " 런타임 시 LD_LIBRARY_PATH 필요:"
echo "  export LD_LIBRARY_PATH=$INSTALL_DIR:\$LD_LIBRARY_PATH"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit 0
