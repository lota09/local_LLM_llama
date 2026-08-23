#!/usr/bin/env bash
set -euo pipefail
# Build and install script for `llama_server/llama-server`
# Uses cmake (current llama.cpp build system).
# Fully automatic: resolves cmake/nvcc from conda or system paths.
#
# 설계 목표: 어떤 시스템에서든 최적 빌드
#   - CPU 아키텍처 무관 (x86_64 / ARM64 등)
#   - 가속 백엔드 자동 감지: CUDA(NVIDIA) / ROCm(AMD) / Metal(macOS) / CPU-only
#   - 빌드 플래그를 "문자열"이 아닌 "배열"로 누적하여 공백/이식성 문제 원천 차단
#   - [FIX] 런타임에 필요한 공유 라이브러리를 사람이 이름으로 나열하지 않고
#           ldd로 자동 탐지 → libmtmd.so 같은 신규 라이브러리가 업스트림에
#           추가돼도 스크립트 수정 없이 자동으로 따라간다.

REPO_URL=${REPO_URL:-https://github.com/ggerganov/llama.cpp.git}
BUILD_DIR=${BUILD_DIR:-/tmp/llama_build}

# [FIX] 설치 디렉터리를 백엔드별로 분리한다 (llama_server_rocm, llama_server_vulkan, ...).
#
# 예전에는 백엔드와 무관하게 항상 'llama_server' 하나에 덮어썼다. 그래서
#   - Vulkan 으로 빌드했다가 ROCm 으로 다시 빌드하면 앞의 것이 사라져 비교가 불가능했고
#   - 두 백엔드를 같이 쓰려면 프로젝트 디렉터리 자체를 통째로 복제해야 했으며
#   - 정리 로직이 조금이라도 어긋나면 서로 다른 백엔드의 .so 가 한 디렉터리에 섞였다
#     (실제로 libggml-vulkan.so.0 가 HIP 설치본에 남아 있던 사고가 있었다)
#
# 이름은 백엔드가 정해진 뒤(3번 섹션) 확정되므로, 여기서는 사용자가 INSTALL_DIR 을
# 직접 지정했는지만 기억해 둔다. 지정하지 않았다면 나중에 백엔드 태그를 붙여 만든다.
INSTALL_DIR_EXPLICIT=0
[ -n "${INSTALL_DIR:-}" ] && INSTALL_DIR_EXPLICIT=1

# 스크립트가 있는 디렉터리를 기준으로 삼는다. 어디서 실행하든 결과 위치가 같아진다.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────
# 유틸: 섹션 헤더 출력
# ─────────────────────────────────────────────
section() { echo ""; echo "── $* ──"; }

# URL 을 stdout 으로 받아온다. curl 이 없는 최소 설치(Ubuntu 26.04 서버 이미지 등)에서도
# 동작하도록 wget 폴백을 둔다. 둘 다 없으면 1 을 돌려주고, 호출부가 알아서 폴백한다.
fetch_stdout() {
  if   command -v curl >/dev/null 2>&1; then curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then wget -qO- "$1"
  else return 1
  fi
}

# sudo 래퍼. 터미널에서 실행 중이면 평소처럼 비밀번호를 물어보고,
# 파이프/CI 처럼 입력이 없는 환경에서는 -n 을 붙여 "프롬프트에서 영원히 멈추는" 사고를 막는다.
# (비대화형에서 sudo 가 실패하면 호출부가 무권한 대안으로 넘어가면 된다)
_sudo() {
  if [ -t 0 ] && [ "${NONINTERACTIVE:-0}" != "1" ]; then sudo "$@"
  else sudo -n "$@"
  fi
}

# 플랫폼 식별 (여러 곳에서 재사용)
OS_NAME="$(uname -s)"          # Linux / Darwin
ARCH_NAME="$(uname -m)"        # x86_64 / aarch64 / arm64 ...
echo "Platform: OS=$OS_NAME ARCH=$ARCH_NAME"

# ─────────────────────────────────────────────
# 1. 최신 릴리즈 태그 자동 감지
# ─────────────────────────────────────────────
section "1. 최신 릴리즈 태그 확인"
LATEST_TAG=$(fetch_stdout "https://api.github.com/repos/ggerganov/llama.cpp/releases/latest" \
  | grep '"tag_name"' | head -n1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/' || true)

if [ -z "$LATEST_TAG" ]; then
  echo "Warning: GitHub API 응답 실패(또는 curl/wget 없음) → 'master' 브랜치로 폴백"
  CLONE_REF="master"
else
  echo "Latest release: $LATEST_TAG"
  CLONE_REF="$LATEST_TAG"
fi

echo "Repo     : $REPO_URL (ref: $CLONE_REF)"
echo "Build dir: $BUILD_DIR"
# INSTALL_DIR 은 백엔드가 정해진 뒤(3d-4)에 확정되므로 여기서는 아직 비어 있을 수 있다.
if [ "$INSTALL_DIR_EXPLICIT" -eq 1 ]; then
  echo "Install  : $INSTALL_DIR"
else
  echo "Install  : ${SCRIPT_DIR}/llama_server_<백엔드>  (백엔드 확정 후 결정)"
fi

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

# CONDA_ROOTS가 비어 있어도 'set -u'에서 안전하게 순회
for root in "${CONDA_ROOTS[@]:-}"; do
  [ -n "$root" ] || continue
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
  for root in "${CONDA_ROOTS[@]:-}"; do
    [ -n "$root" ] || continue
    [ -x "$root/bin/conda" ] && CONDA_CMD="$root/bin/conda" && break
  done
  if [ -n "$CONDA_CMD" ]; then
    "$CONDA_CMD" install -y -c conda-forge cmake 2>&1 | tail -5
    # 재탐색
    for root in "${CONDA_ROOTS[@]:-}"; do
      [ -n "$root" ] || continue
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

# 마지막 수단: OS별 패키지 매니저 자동 설치
if [ -z "$CMAKE_BIN" ]; then
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt-get로 cmake 설치 중..."
    _sudo apt-get update >/dev/null 2>&1 && _sudo apt-get install -y cmake 2>&1 | grep -E "^(Setting|Processing|Reading|Building|Get|Unpacking)" || true
    command -v cmake >/dev/null 2>&1 && CMAKE_BIN="cmake"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf로 cmake 설치 중..."
    _sudo dnf install -y cmake 2>&1 | tail -5
    command -v cmake >/dev/null 2>&1 && CMAKE_BIN="cmake"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum으로 cmake 설치 중..."
    _sudo yum install -y cmake 2>&1 | tail -5
    command -v cmake >/dev/null 2>&1 && CMAKE_BIN="cmake"
  elif command -v brew >/dev/null 2>&1; then
    echo "brew로 cmake 설치 중..."
    brew install cmake 2>&1 | tail -5
    command -v cmake >/dev/null 2>&1 && CMAKE_BIN="cmake"
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman으로 cmake 설치 중..."
    _sudo pacman -S --noconfirm cmake 2>&1 | tail -5
    command -v cmake >/dev/null 2>&1 && CMAKE_BIN="cmake"
  fi
  [ -n "$CMAKE_BIN" ] && echo "cmake 설치 성공: $(cmake --version | head -n1)"
fi

if [ -z "$CMAKE_BIN" ]; then
  echo "Error: cmake를 자동 설치할 수 없습니다. 다음 중 하나를 수행하세요:" >&2
  echo "  1. _sudo apt-get install cmake  (Debian/Ubuntu)" >&2
  echo "  2. conda install -c conda-forge cmake" >&2
  echo "  3. brew install cmake  (macOS)" >&2
  exit 1
fi

echo "사용할 cmake: $CMAKE_BIN"

# conda CMake는 자체 RPATH($ORIGIN/../lib)를 가지므로 런타임 경로를 전역으로
# 주입하지 않는다. 전역 LD_LIBRARY_PATH는 make가 실행하는 bash까지 conda
# libtinfo를 로드하게 만들어 불필요한 경고와 ABI 혼용을 일으킨다.
CMAKE_REALPATH=$(realpath "$CMAKE_BIN" 2>/dev/null || echo "$CMAKE_BIN")
CMAKE_DIR=$(dirname "$CMAKE_REALPATH")
CONDA_ENV_LIB="${CMAKE_DIR%/bin}/lib"
if [ -d "$CONDA_ENV_LIB" ]; then
  echo "conda CMake 자체 RPATH 사용: $CONDA_ENV_LIB"
fi

# ─────────────────────────────────────────────
# 3. 가속 백엔드 자동 탐색 (CUDA → ROCm → Metal → CPU)
# ─────────────────────────────────────────────
section "3. 가속 백엔드 탐색"

# 빌드 플래그를 배열로 누적 (공백/이식성 안전)
CMAKE_ARGS=()

NVCC_BIN=""
USE_CUDA=0
USE_ROCM=0
USE_METAL=0

# --- 3a. macOS면 Metal 우선 (Apple Silicon/Intel 공통) ---
if [ "$OS_NAME" = "Darwin" ]; then
  USE_METAL=1
  echo "macOS 감지 → Metal 백엔드 사용 (-DGGML_METAL=ON)"
fi

# --- 3b. NVIDIA CUDA 탐색 (Linux) ---
# CUDA toolkit은 필수 의존성이므로, GPU가 있더라도 nvcc가 없으면 자동 설치를 시도한다.
_ensure_cuda_toolkit() {
  if command -v nvcc >/dev/null 2>&1; then
    return 0
  fi

  local conda_cmd=""
  for root in "${CONDA_ROOTS[@]:-}"; do
    [ -n "$root" ] || continue
    if [ -x "$root/bin/conda" ]; then
      conda_cmd="$root/bin/conda"
      break
    fi
  done

  if [ -z "$conda_cmd" ] && command -v conda >/dev/null 2>&1; then
    conda_cmd="conda"
  fi

  if [ -n "$conda_cmd" ]; then
    echo "NVIDIA GPU가 감지됐지만 nvcc가 없습니다. conda에서 CUDA Toolkit을 설치합니다: conda install -c nvidia cuda-toolkit"
    "$conda_cmd" install -y -c nvidia cuda-toolkit 2>&1 | tail -20 || true
  else
    echo "conda를 찾지 못해 CUDA Toolkit 자동 설치를 건너뜁니다."
  fi

  # 설치 후 재탐색
  for c in \
    "/usr/local/cuda/bin/nvcc" \
    "/usr/local/cuda-12/bin/nvcc" \
    "/usr/local/cuda-12.6/bin/nvcc" \
    "/usr/local/cuda-12.4/bin/nvcc" \
    "/usr/local/cuda-11/bin/nvcc" \
    "/usr/cuda/bin/nvcc" \
    "$(command -v nvcc 2>/dev/null || true)" \
    $(find /usr/local -name nvcc -type f 2>/dev/null | head -n10 || true) \
    "${CONDA_ROOTS[@]:-}"/bin/nvcc ; do
    [ -n "$c" ] || continue
    if [ -x "$c" ]; then
      NVCC_BIN="$c"
      break
    fi
  done

  # conda CUDA는 보통 $PREFIX/targets/<arch>/include 에 헤더가 있고,
  # $PREFIX/include/ 에는 없는 패키지가 많다. nvcc는 $PREFIX/include 를 기본 포함 경로로
  # 보므로, 실제 헤더들이 있는 targets 경로를 루트 include 로 연결해 준다.
  if [ -n "$NVCC_BIN" ]; then
    local conda_prefix="$(dirname "$(dirname "$NVCC_BIN")")"
    local cuda_targets_include=""
    for d in \
      "$conda_prefix/targets/x86_64-linux/include" \
      "$conda_prefix/targets/aarch64-linux/include" \
      "$conda_prefix/targets/sbsa-linux/include" \
      "$conda_prefix/targets/ppc64le-linux/include"; do
      if [ -f "$d/cuda_runtime.h" ]; then
        cuda_targets_include="$d"
        break
      fi
    done

    if [ -n "$cuda_targets_include" ] && [ ! -f "$conda_prefix/include/cuda_runtime.h" ]; then
      mkdir -p "$conda_prefix/include"
      for header in "$cuda_targets_include"/*.h; do
        [ -e "$header" ] || continue
        ln -sf "$header" "$conda_prefix/include/$(basename "$header")"
      done
      for header in "$cuda_targets_include"/crt/*.h; do
        [ -e "$header" ] || continue
        mkdir -p "$conda_prefix/include/crt"
        ln -sf "$header" "$conda_prefix/include/crt/$(basename "$header")"
      done
      echo "conda CUDA include 경로 보정: $cuda_targets_include -> $conda_prefix/include"
    fi
  fi

  [ -n "$NVCC_BIN" ] && return 0
  return 1
}

if [ "$USE_METAL" -eq 0 ]; then
  CUDA_CANDIDATES=(
    "/usr/local/cuda/bin/nvcc"
    "/usr/local/cuda-12/bin/nvcc"
    "/usr/local/cuda-12.6/bin/nvcc"
    "/usr/local/cuda-12.4/bin/nvcc"
    "/usr/local/cuda-11/bin/nvcc"
    "/usr/cuda/bin/nvcc"
  )
  command -v nvcc >/dev/null 2>&1 && CUDA_CANDIDATES+=("$(command -v nvcc)")

  for c in "${CUDA_CANDIDATES[@]}"; do
    if [ -x "$c" ]; then
      NVCC_BIN="$c"
      break
    fi
  done
  # nvcc는 없지만 nvidia-smi가 있으면 더 넓게 탐색하고, 그래도 없으면 conda로 자동 설치
  if [ -z "$NVCC_BIN" ] && command -v nvidia-smi >/dev/null 2>&1; then
    NVCC_BIN=$(find /usr/local -name nvcc -type f 2>/dev/null | head -n1 || true)
    if [ -z "$NVCC_BIN" ]; then
      _ensure_cuda_toolkit || true
    fi
  fi

  if [ -n "$NVCC_BIN" ]; then
    USE_CUDA=1
    CUDA_BIN_DIR=$(dirname "$NVCC_BIN")
    export PATH="$CUDA_BIN_DIR:$PATH"
    export CUDACXX="$NVCC_BIN"
    echo "nvcc 발견: $NVCC_BIN → CUDA 백엔드 사용"
  fi
fi

# --- 3c. CUDA가 없으면 AMD ROCm/HIP 탐색 (Linux) ---
# [FIX] 예전에는 /opt/rocm/bin/hipcc 존재 여부만 봤는데, 그것만으로는 빌드가 되지 않는다.
# llama.cpp의 HIP 백엔드는 hipcc 말고도 (1) hipBLAS/rocBLAS의 cmake 패키지와
# (2) 내 GPU 아키텍처(gfx…)용으로 실제 컴파일된 rocBLAS 커널을 필요로 한다.
# 그래서 "hipcc가 있냐"가 아니라 "내 GPU 아키텍처를 실제로 지원하는 ROCm 설치가 어디냐"를
# 기준으로 고른다.
#
# [FIX] ROCm 설치 형태가 두 가지로 늘어나서 경로를 고정할 수 없다.
#
#   (A) AMD 공식 저장소(repo.radeon.com) → /opt/rocm-6.4.1 같은 버전별 디렉터리
#         cmake 패키지 : <root>/lib/cmake/{hip,hip-lang,hipblas,rocblas}
#         rocBLAS 커널 : <root>/lib/rocblas/library/
#         HIP 컴파일러 : <root>/llvm/bin/clang++
#
#   (B) 배포판 패키지 → 접두사가 /usr. Ubuntu 26.04 LTS(resolute) 는 ROCm 7.1.0 을
#       universe 에 담고 있어 apt 만으로 설치된다:
#         sudo apt install libamdhip64-dev librocblas-dev libhipblas-dev hipcc rocminfo
#         cmake 패키지 : /usr/lib/x86_64-linux-gnu/cmake/{hip,hip-lang,hipblas,rocblas}
#         rocBLAS 커널 : /usr/lib/x86_64-linux-gnu/rocblas/<ver>/library/   ← 버전 디렉터리가 하나 더 끼어든다
#         HIP 컴파일러 : /usr/lib/rocm/llvm/bin/clang++  또는  /usr/lib/llvm-21/bin/clang++
#
#   llama.cpp 자신도 두 레이아웃을 모두 안다(ggml-hip/CMakeLists.txt 는 /opt/rocm 이 없으면
#   ROCM_PATH 를 /usr 로 잡는다). 그래서 아래 후보 목록에 /usr 을 넣는다.
#
# [주의] "배포판이 ROCm 을 패키징했다" ≠ "내 GPU 가 지원된다".
# Ubuntu 26.04 의 librocblas5(7.1.0) 안에 들어 있는 아키텍처는
#   gfx908 gfx90a gfx942 gfx1030 gfx1100 gfx1101 gfx1151 gfx1200 gfx1201
# 뿐이고 gfx906(MI50 / Radeon Pro VII / Radeon VII)용 Tensile 커널은 0개다
# (Canonical 이 CI 로 검증한다고 밝힌 아키텍처 목록도 이와 같고 gfx906 은 없다).
# 반면 컴파일러 쪽은 gfx906 을 그대로 지원한다 — rocm-device-libs 에
# oclc_isa_version_906.bc 가 들어 있어 빌드는 깔끔하게 통과한다.
# 그래서 커널 확인을 건너뛰면 "빌드는 성공 → 첫 추론에서 사망" 이 된다:
#     rocBLAS error: Cannot read .../TensileLibrary.dat for GPU arch : gfx906
# 아래 루프가 "내 gfx 커널이 실제로 들어있는" 설치만 채택하는 이유다.
# 사용자가 ROCM_ROOT 로 특정 설치를 지정했다면 그걸 최우선 후보로 삼는다.
# (아래에서 ROCM_ROOT 를 "채택 결과" 변수로 재사용하므로 먼저 따로 보관해 둔다)
ROCM_ROOT_HINT="${ROCM_ROOT:-}"
ROCM_ROOT=""
ROCM_CMAKE_DIR=""     # hip/hipblas/rocblas cmake 패키지들의 부모 디렉터리
ROCM_ROCBLAS_DIR=""   # rocBLAS Tensile 커널 데이터 루트 (아래에 library/ 가 있음)
ROCM_CLANGXX=""       # HIP 를 컴파일할 수 있는 clang++
GPU_ARCH=""

# [FIX] "커널 파일 이름에 gfx906 이 있느냐"만으로 지원 여부를 판정하면 안 된다.
# ROCm 7.x 에 generic 코드 오브젝트가 생겼기 때문이다. gfx9-generic 하나가
# gfx900/902/904/906/909/90c 를 전부 커버하므로, gfx906 이라는 이름의 파일이
# 하나도 없어도 MI50 에서 정상 동작한다(아키텍처 전용 최적화를 포기하는 대신).
# 실제로 gfx9-generic 을 넣어 빌드한 rocBLAS 7.2.x 배포판 패키지가 존재한다.
# 파일명만 보면 그런 설치를 "지원 안 됨"으로 잘못 튕겨낸다.
_rocm_generic_for() {
  case "$1" in
    gfx900|gfx902|gfx904|gfx906|gfx909|gfx90c) echo "gfx9-generic"    ;;
    gfx942|gfx950)                             echo "gfx9-4-generic"  ;;
    gfx1010|gfx1011|gfx1012|gfx1013)           echo "gfx10-1-generic" ;;
    gfx103*)                                   echo "gfx10-3-generic" ;;
    gfx11*)                                    echo "gfx11-generic"   ;;
    gfx12*)                                    echo "gfx12-generic"   ;;
    *)                                         echo ""                ;;
  esac
}

# 이 rocBLAS 설치가 내 아키텍처를 지원하는가.
#
# [FIX] 한때 dpkg 의 X-ROCm-GPU-Architecture 필드를 "정답지"로 먼저 봤는데, 그건 틀렸다.
# 그 필드는 **패키지가 빌드된 시점의 선언**이라 나중에 디스크에 채워 넣은 커널을 모른다.
# 실제로 setup_rocm_tensile.sh 로 gfx906 커널 156개를 넣은 뒤에도 필드는 여전히
# "gfx908 gfx90a …" 였고, 그 탓에 멀쩡히 동작하는 설치가 거부됐다(실측으로 확인).
# rocBLAS 는 런타임에 디렉터리를 뒤져 파일을 읽으므로 **디스크의 파일이 곧 진실**이다.
# 그래서 파일을 먼저 보고, dpkg 필드는 진단 메시지용 참고값으로만 읽는다.
ROCM_VIA_GENERIC=""
ROCM_DECL_ARCHES=""
_rocm_arch_supported() {
  local blasdir="$1" arch="$2" generic pkg
  [ -n "$arch" ] || return 0            # 아키텍처를 모르면 걸러내지 않는다
  generic="$(_rocm_generic_for "$arch")"

  # (1) 참고용: 패키지가 원래 어떤 아키텍처로 빌드됐는지 (판정에는 쓰지 않는다)
  if command -v dpkg-query >/dev/null 2>&1; then
    pkg=$(dpkg -S "$blasdir" 2>/dev/null | head -n1 | cut -d: -f1 || true)
    [ -n "$pkg" ] && ROCM_DECL_ARCHES=$(dpkg-query -W -f='${X-ROCm-GPU-Architecture}' "$pkg" 2>/dev/null || true)
  fi

  # (2) 판정: 실제로 그 아키텍처의 커널 파일이 디스크에 있는가
  [ -n "$(find "$blasdir" -name "*$arch*" -print -quit 2>/dev/null)" ] && return 0

  # (3) 전용 커널이 없어도 generic 코드 오브젝트가 계열 전체를 커버한다
  if [ -n "$generic" ] && \
     [ -n "$(find "$blasdir" -name "*$generic*" -print -quit 2>/dev/null)" ]; then
    ROCM_VIA_GENERIC="$generic"; return 0
  fi
  return 1
}

# ROCm 설치 루트 하나를 조사해 위 세 경로를 _P_* 에 채운다.
# 세 가지가 모두 갖춰졌을 때만 0 을 돌려준다 — 하나라도 없으면 빌드가 못 되므로
# 후보에서 조용히 제외하는 것이 맞다.
_rocm_probe() {
  local root="$1" d c llvmroot
  _P_CMAKE=""; _P_ROCBLAS=""; _P_CLANGXX=""

  # (1) hip / hipblas / rocblas cmake 패키지가 한 디렉터리에 모두 있어야 한다.
  #     glob 이 안 맞으면 '*' 가 그대로 남지만 -f 검사에서 걸러진다.
  for d in "$root/lib/cmake" "$root"/lib/*-linux-gnu/cmake "$root/lib64/cmake"; do
    [ -f "$d/hip/hip-config.cmake" ]         || continue
    [ -f "$d/hipblas/hipblas-config.cmake" ] || continue
    [ -f "$d/rocblas/rocblas-config.cmake" ] || continue
    _P_CMAKE="$d"; break
  done
  [ -n "$_P_CMAKE" ] || return 1

  # (2) rocBLAS Tensile 커널 데이터 루트.
  #     공식 설치는 <root>/lib/rocblas/library, 배포판은 <multiarch>/rocblas/<ver>/library
  #     처럼 깊이가 달라서, 여기서는 'rocblas' 디렉터리까지만 잡고 실제 검색은 find 로 한다.
  for d in "$root/lib/rocblas" "$root"/lib/*-linux-gnu/rocblas "$root/lib64/rocblas"; do
    [ -d "$d" ] && { _P_ROCBLAS="$d"; break; }
  done
  [ -n "$_P_ROCBLAS" ] || return 1

  # (3) amdgcn 비트코드를 갖춘 clang++ = HIP 를 실제로 컴파일할 수 있는 것.
  #     비트코드(rocm-device-libs) 없이 clang++ 만 있으면 device 코드 링크에서 깨지므로,
  #     "clang++ 가 있냐"가 아니라 "옆에 비트코드가 있냐"로 판정한다.
  for c in "$root/llvm/bin/clang++" "$root/lib/rocm/llvm/bin/clang++" \
           $(ls -d "$root"/lib/llvm-*/bin/clang++ 2>/dev/null | sort -Vr) \
           "$root/bin/clang++"; do
    [ -x "$c" ] || continue
    llvmroot="${c%/bin/clang++}"
    ls "$llvmroot"/lib/clang/*/amdgcn/bitcode/oclc_isa_version_*.bc >/dev/null 2>&1 || continue
    _P_CLANGXX="$c"; break
  done
  [ -n "$_P_CLANGXX" ] || return 1
  return 0
}

if [ "$USE_METAL" -eq 0 ] && [ "$USE_CUDA" -eq 0 ] && [ "$OS_NAME" = "Linux" ]; then
  # (a) 내 GPU 아키텍처 알아내기 (rocminfo)
  #     주의: rocminfo 는 /dev/kfd 를 열어야 하므로 render 그룹 권한이 필요하다.
  #     usermod 로 그룹에 넣었어도 "재로그인 전"에는 현재 셸에 반영되지 않아 실패한다.
  #     그래서 직접 실행이 실패하면 sg 로 그룹을 적용해 한 번 더 시도한다.
  #
  # [FIX] 정규식이 'gfx[0-9a-f]+' 였는데, ROCm 7.x 의 rocminfo 는 한 에이전트에
  # ISA 이름을 여러 개 보고한다. 실제 MI50 출력:
  #     Name:  amdgcn-amd-amdhsa--gfx906:sramecc+:xnack-
  #     Name:  amdgcn-amd-amdhsa--gfx9-generic:xnack-      ← generic 타겟도 광고한다
  # 옛 정규식은 'gfx9-generic' 을 'gfx9' 로 잘라 쓰레기 값을 만들어 냈다
  # (실측에서 "감지된 gfx: gfx9 gfx906" 로 확인). 지금은 출력 순서 덕에
  # head -n1 이 우연히 gfx906 을 먼저 집었을 뿐, 순서가 바뀌면 gfx9 로 빌드를 시도한다.
  # 그래서 두 겹으로 막는다:
  #   (1) '-generic' 이 들어간 ISA 줄은 통째로 버린다
  #       (숫자 2자리 필터만으로는 gfx10-3-generic 이 'gfx10' 으로 잘려 빠져나간다)
  #   (2) 남은 줄에서 숫자 2자리 이상 + 선택적 letter 를 뽑는다
  #       → gfx906 / gfx90a / gfx1030 / gfx1201 모두 정상, 잘린 값은 나오지 않는다
  GFX_RE='gfx[0-9]{2,}[a-z]?'
  _gfx_of() { grep -v -- '-generic' | grep -oE "$GFX_RE" | head -n1; }

  # (i) rocminfo — 가장 상세하지만 /dev/kfd 를 열어야 해서 render 그룹이 현재 셸에
  #     반영돼 있어야 한다(usermod 직후 재로그인 전에는 실패한다).
  for ri in /opt/rocm*/bin/rocminfo "$(command -v rocminfo 2>/dev/null || true)"; do
    [ -n "$ri" ] && [ -x "$ri" ] || continue
    GPU_ARCH=$("$ri" 2>/dev/null | _gfx_of || true)
    # sg 로 그룹을 미리 적용해 한 번 더. sg 는 없는 시스템도 있으므로 존재를 먼저 본다
    # (예전엔 무조건 호출해서 'sg: command not found' 로 조용히 실패했다).
    if [ -z "$GPU_ARCH" ] && command -v sg >/dev/null 2>&1 \
       && id -nG "$USER" 2>/dev/null | grep -qw render; then
      GPU_ARCH=$(sg render -c "$ri" 2>/dev/null | _gfx_of || true)
    fi
    [ -n "$GPU_ARCH" ] && break
  done

  # (ii) [FIX] rocminfo 가 막혀도 아키텍처를 알아낼 수 있다. amdgpu-arch(LLVM)와
  #      rocm_agent_enumerator 는 /dev/kfd 없이 /sys 만으로 답한다. 실제로 이 경로
  #      덕분에 cmake 는 gfx906 을 맞췄는데 정작 이 스크립트만 "감지 실패" 로 넘어가
  #      -DGPU_TARGETS 를 안 넘기고 있었다(운 좋게 결과는 같았지만 근거가 없었다).
  if [ -z "$GPU_ARCH" ]; then
    for ae in "$(command -v amdgpu-arch 2>/dev/null || true)" \
              "$(command -v rocm_agent_enumerator 2>/dev/null || true)" \
              $(ls /usr/lib/llvm-*/bin/amdgpu-arch /opt/rocm*/llvm/bin/amdgpu-arch 2>/dev/null | sort -Vr); do
      [ -n "$ae" ] && [ -x "$ae" ] || continue
      GPU_ARCH=$("$ae" 2>/dev/null | _gfx_of || true)
      [ -n "$GPU_ARCH" ] && { echo "  ($(basename "$ae") 로 감지 — rocminfo 없이)"; break; }
    done
  fi

  # (iii) 마지막 수단: PCI ID → gfx 매핑 (ROCm 유저스페이스가 아예 없어도 동작)
  if [ -z "$GPU_ARCH" ]; then
    PCI_ID=$(lspci -nn 2>/dev/null \
      | grep -iE 'VGA|Display|3D' \
      | grep -i 'AMD/ATI' \
      | grep -oE '\[1002:[0-9a-f]{4}\]' \
      | head -1 \
      | tr -d '[]' \
      | cut -d: -f2 || true)
    case "$PCI_ID" in
      66a0|66a1|66a3|66a7|66af) GPU_ARCH=gfx906 ;;   # Vega 20 / MI50, MI60, Radeon VII
      6860|6861|6862|6863|687f) GPU_ARCH=gfx900 ;;   # Vega 10 / MI25
      738c|7388|738e|7390)      GPU_ARCH=gfx908 ;;   # MI100
      7408|740c|740f)           GPU_ARCH=gfx90a ;;   # MI200
      73bf|73df|73ff)           GPU_ARCH=gfx1030 ;;  # RDNA2
      744c|7448)                GPU_ARCH=gfx1100 ;;  # RDNA3
      *)                       GPU_ARCH="" ;;
    esac
    [ -n "$GPU_ARCH" ] && echo "  (PCI 1002:$PCI_ID 로 추정)"
  fi
  if [ -n "$GPU_ARCH" ]; then
    echo "GPU 아키텍처 감지: $GPU_ARCH"
  else
    echo "GPU 아키텍처를 감지하지 못했습니다 (rocminfo 실패). 아키텍처 필터 없이 진행합니다."
  fi

  # (b) ROCm 루트 후보: AMD 공식 설치를 버전 내림차순으로 먼저, 배포판 설치(/usr)를 마지막에.
  #     -V 정렬로 rocm-6.2.0 < rocm-7.14 처럼 버전 순서를 올바르게 잡는다.
  #     /usr 을 뒤에 두는 이유: 구형 GPU 는 공식 6.x 계열에만 커널이 남아 있는 경우가 있어
  #     명시적으로 깔아 둔 공식 설치가 우선권을 갖는 게 맞다. /usr 은 항상 폴백으로 남는다.
  #     ROCM_ROOT 환경변수로 특정 루트를 맨 앞에 끼워 넣을 수도 있다.
  ROCM_CANDIDATES="$ROCM_ROOT_HINT $(ls -d /opt/rocm /opt/rocm-* 2>/dev/null | sort -Vr || true) /usr"

  ROCM_NOARCH_ROOTS=""     # cmake/컴파일러는 갖췄지만 내 gfx 커널이 없던 루트들
  ROCM_NOARCH_LIBDIR=""    # 그 중 첫 번째의 실제 library/ 경로 (커널을 심어 넣을 자리)
  for root in $ROCM_CANDIDATES; do
    [ -d "$root" ] || continue
    _rocm_probe "$root" || continue

    # 내 GPU를 이 rocBLAS 가 실제로 지원하는지 확인 (아키텍처를 아는 경우에만).
    # 아키텍처 전용 커널 / generic 타겟 / dpkg 선언 세 가지를 모두 본다.
    ROCM_VIA_GENERIC=""; ROCM_DECL_ARCHES=""
    if ! _rocm_arch_supported "$_P_ROCBLAS" "$GPU_ARCH"; then
      echo "  $root: rocBLAS가 $GPU_ARCH 를 지원하지 않음 → 건너뜀"
      [ -n "$ROCM_DECL_ARCHES" ] && echo "      (빌드된 아키텍처: $ROCM_DECL_ARCHES)"
      ROCM_NOARCH_ROOTS="$ROCM_NOARCH_ROOTS $root"
      [ -n "$ROCM_NOARCH_LIBDIR" ] || \
        ROCM_NOARCH_LIBDIR=$(find "$_P_ROCBLAS" -type d -name library -print -quit 2>/dev/null || true)
      continue
    fi
    ROCM_ROOT="$root"
    ROCM_CMAKE_DIR="$_P_CMAKE"
    ROCM_ROCBLAS_DIR="$_P_ROCBLAS"
    ROCM_CLANGXX="$_P_CLANGXX"
    break
  done

  if [ -n "$ROCM_ROOT" ]; then
    USE_ROCM=1
    if [ -n "$ROCM_VIA_GENERIC" ]; then
      echo "ROCm 루트 채택: $ROCM_ROOT ($GPU_ARCH 전용 커널은 없지만 $ROCM_VIA_GENERIC 이 커버) → ROCm(HIP) 백엔드 사용"
      echo "  참고: generic 코드 오브젝트는 아키텍처 전용 최적화를 포기한 것이라 동작은 하되 최고 성능은 아닙니다."
    else
      echo "ROCm 루트 채택: $ROCM_ROOT${GPU_ARCH:+ ($GPU_ARCH 커널 확인됨)} → ROCm(HIP) 백엔드 사용"
    fi
    echo "  cmake 패키지 : $ROCM_CMAKE_DIR"
    echo "  rocBLAS 커널 : $ROCM_ROCBLAS_DIR"
    echo "  HIP 컴파일러 : $ROCM_CLANGXX"
  elif [ -n "$ROCM_NOARCH_ROOTS" ]; then
    # 이 경우가 Ubuntu 26.04 + MI50 의 정확한 상황이다. "ROCm 이 없다"가 아니라
    # "ROCm 은 있는데 내 아키텍처 커널만 빠져 있다"이므로 구분해서 안내한다.
    echo ""
    echo "ROCm 은 설치되어 있지만 ${GPU_ARCH:-내 GPU} 용 rocBLAS 커널이 없습니다:${ROCM_NOARCH_ROOTS}"
    echo "  이대로 -DGGML_HIP=ON 으로 빌드하면 컴파일은 통과하고 모델 로드까지도 끝난 뒤,"
    echo "  첫 추론 요청에서 죽습니다. (Ubuntu 26.04 + MI50 에서 실측한 실제 동작:"
    echo "   컴파일러/HIP 런타임은 gfx906 정상 동작 → rocBLAS 만 아래처럼 폴백 없이 abort)"
    echo "     rocBLAS error: Cannot read .../TensileLibrary.dat for GPU arch : ${GPU_ARCH:-gfx…}"
    echo "     Aborted (core dumped)   ← SIGABRT, 소프트 폴백 없음"
    echo ""
    echo "  선택지 1) Tensile 커널 이식 — 배포판 ROCm 을 그대로 두고 빠진 데이터 파일만 채웁니다."
    echo "       컴파일러·HIP 런타임·cmake 패키지는 배포판 것으로 충분하다는 게 실측으로 확인됐고,"
    echo "       부족한 것은 rocBLAS Tensile 데이터뿐입니다. 아래 스크립트가 전부 자동으로 합니다:"
    echo "         sudo bash ${SCRIPT_DIR}/setup_rocm_tensile.sh"
    echo "       (커널이 남아 있는 가장 최신 AMD ROCm 을 찾아 해당 아키텍처 파일만 추출·설치하고,"
    echo "        실제 rocBLAS sgemm 을 돌려 검증합니다. --uninstall 로 정확히 되돌릴 수 있습니다)"
    echo "  선택지 2) Vulkan 백엔드 — 추가 설치 없이 바로 됩니다."
    echo "       GGML_BACKEND=vulkan bash $(basename "${BASH_SOURCE[0]}")"

    # 대화형이면 그 자리에서 이식을 제안한다. 안내만 하고 끝내면 사용자가 스크립트를
    # 두 번 실행해야 하는데, 이미 필요한 정보(아키텍처·설치 경로)를 다 알고 있는 시점이라
    # 여기서 처리하는 편이 자연스럽다.
    # 기본값은 '아니오' — sudo 로 시스템 디렉터리에 파일을 넣는 작업이라 명시적 동의를 받는다.
    # 비대화형(CI/파이프)에서는 절대 실행하지 않고 안내만 하고 넘어간다.
    if [ -t 0 ] && [ "${NONINTERACTIVE:-0}" != "1" ] && [ -x "${SCRIPT_DIR}/setup_rocm_tensile.sh" ]; then
      echo ""
      _graft=""
      read -r -p "지금 Tensile 커널 이식을 실행할까요? (sudo 필요) [y/N]: " _graft || true
      case "$_graft" in
        [Yy]*)
          echo ""
          if sudo bash "${SCRIPT_DIR}/setup_rocm_tensile.sh"; then
            echo ""
            echo "이식 성공 → ROCm 재탐색"
            # 방금 채워진 커널로 다시 판정한다. 스크립트를 다시 실행할 필요가 없다.
            for root in $ROCM_CANDIDATES; do
              [ -d "$root" ] || continue
              _rocm_probe "$root" || continue
              ROCM_VIA_GENERIC=""; ROCM_DECL_ARCHES=""
              _rocm_arch_supported "$_P_ROCBLAS" "$GPU_ARCH" || continue
              ROCM_ROOT="$root"; ROCM_CMAKE_DIR="$_P_CMAKE"
              ROCM_ROCBLAS_DIR="$_P_ROCBLAS"; ROCM_CLANGXX="$_P_CLANGXX"
              USE_ROCM=1
              echo "ROCm 루트 채택: $ROCM_ROOT ($GPU_ARCH 커널 확인됨) → ROCm(HIP) 백엔드 사용"
              break
            done
            [ "$USE_ROCM" -eq 1 ] || echo "⚠️  이식 후에도 쓸 만한 ROCm 을 찾지 못했습니다."
          else
            echo "이식이 실패했습니다 — Vulkan 으로 진행하거나 로그를 확인하세요."
          fi
          ;;
        *) echo "건너뜁니다. 나중에 직접 실행하셔도 됩니다." ;;
      esac
    fi
  else
    echo "쓸 만한 ROCm 설치를 찾지 못함 (cmake 패키지 / amdgcn 비트코드가 없는 경우 포함)"
    # [주의] 'apt-cache policy … | grep -q' 로 쓰면 안 된다. grep -q 는 첫 매치에서
    # 즉시 끝나므로 apt-cache 가 SIGPIPE(141)로 죽고, 이 스크립트의 'set -o pipefail'
    # 때문에 파이프라인 전체가 실패로 잡힌다. 출력 크기와 타이밍에 따라 됐다 안 됐다
    # 하는 성질이라 더 나쁘다. 값을 먼저 변수로 받아 두면 이 경합이 사라진다.
    APT_ROCBLAS_CAND=""
    if command -v apt-cache >/dev/null 2>&1; then
      # awk 에 exit 를 쓰면 그것도 조기 종료라 같은 SIGPIPE 를 유발한다 — 끝까지 읽는다.
      APT_ROCBLAS_CAND=$(apt-cache policy librocblas-dev 2>/dev/null \
                         | awk '/Candidate:/{c=$2} END{print c}' || true)
    fi
    if [ -n "$APT_ROCBLAS_CAND" ] && [ "$APT_ROCBLAS_CAND" != "(none)" ]; then
      echo "  배포판 저장소에 ROCm $APT_ROCBLAS_CAND 이 있습니다 (Ubuntu 24.04+ universe). 설치:"
      echo "    sudo apt install libamdhip64-dev librocblas-dev libhipblas-dev hipcc rocminfo"
    else
      echo "  AMD 공식 저장소에서 설치하려면: bash setup_rocm.sh"
    fi
  fi
fi

# --- 3d. CUDA/ROCm 둘 다 없으면 Vulkan 탐색 (Linux) ---
# Vulkan은 NVIDIA/AMD/Intel 어떤 GPU든 벤더 SDK(CUDA/ROCm) 없이 Mesa(RADV/ANV/Lavapipe)나
# 벤더 드라이버만으로 동작하는 범용 가속 경로다. 특히 구형 AMD GPU(gfx906/MI50 등)처럼
# ROCm이 공식 지원을 끊었거나 설치가 무거운 경우에 가장 이식성 높은 선택지가 된다.
# 판정 기준: (1) libvulkan 로더 존재 (2) 실제 GPU 디바이스가 최소 1개 열거되는지 vulkaninfo로 확인.
#   → 헤더/glslc가 없어도 "탐지"는 통과시키고, 부족한 도구는 아래에서 자동 설치를 시도한다.
# [FIX] "Vulkan 을 쓸 수 있는가"(VULKAN_AVAILABLE)와 "Vulkan 을 쓸 것인가"(USE_VULKAN)를
# 분리한다. 예전에는 둘을 한 덩어리로 묶어 CUDA/ROCm 이 감지되면 Vulkan 탐지 자체를
# 건너뛰었다. 그래서 3d-3 의 백엔드 선택 목록에 Vulkan 이 아예 나타나지 않았고
# (ROCm 이 잡힌 기기에서는 GGML_BACKEND=vulkan 을 손으로 줘야만 빌드할 수 있었다),
# 두 백엔드를 만들어 비교하려는 이 프로젝트의 사용 방식과 어긋났다.
VULKAN_AVAILABLE=0
if [ "$OS_NAME" = "Linux" ]; then
  # [FIX] 'ldconfig -p | grep -q' 처럼 출력이 큰 명령을 grep -q 로 받으면 grep 이 첫 매치에서
  # 끝나면서 앞 명령이 SIGPIPE(141)로 죽고, 'set -o pipefail' 탓에 파이프라인이 실패로 잡힌다.
  # 버퍼 크기/타이밍에 따라 간헐적으로만 재현되므로 "왜 Vulkan 이 어떤 날은 안 잡히지"가 된다.
  # 출력을 먼저 변수로 받아 두면 조기 종료가 없어 경합이 사라진다.
  # 변수에 받아 둔 다음에는 grep 대신 bash 패턴 매칭으로 검사한다. 'echo … | grep -q' 로
  # 되돌리면 파이프가 다시 생겨 같은 문제가 되살아난다(builtin 도 파이프에서는 서브셸이다).
  LDCONFIG_OUT=$(ldconfig -p 2>/dev/null || true)
  if [[ "$LDCONFIG_OUT" == *libvulkan.so* ]] || ls /usr/lib/*/libvulkan.so.1 >/dev/null 2>&1 || command -v vulkaninfo >/dev/null 2>&1; then
    if command -v vulkaninfo >/dev/null 2>&1; then
      # PHYSICAL_DEVICE_TYPE_CPU(llvmpipe)만 있는 경우는 실가속이 아니므로 제외
      VKINFO_OUT=$(vulkaninfo --summary 2>/dev/null || true)
      if [[ "$VKINFO_OUT" == *PHYSICAL_DEVICE_TYPE_DISCRETE_GPU* || \
            "$VKINFO_OUT" == *PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU* ]]; then
        VULKAN_AVAILABLE=1
      fi
    else
      # vulkaninfo가 아직 없으면(패키지 미설치) 로더 존재만으로 일단 후보로 채택.
      # 실제 GPU가 없으면 뒤의 cmake 빌드는 성공해도 런타임에 디바이스가 안 잡힐 뿐이라 안전하다.
      VULKAN_AVAILABLE=1
    fi
  fi
fi

# 자동 감지: CUDA/ROCm/Metal 이 없을 때만 Vulkan 을 "기본 선택"으로 삼는다.
# (있으면 그쪽이 보통 더 빠르므로 기본값은 그대로 두고, Vulkan 은 선택지로만 제시한다)
USE_VULKAN=0
if [ "$USE_METAL" -eq 0 ] && [ "$USE_CUDA" -eq 0 ] && [ "$USE_ROCM" -eq 0 ] && [ "$VULKAN_AVAILABLE" -eq 1 ]; then
  USE_VULKAN=1
  echo "Vulkan 로더/디바이스 감지 → Vulkan 백엔드 사용 (CUDA/ROCm 미탐지 시 범용 폴백)"
elif [ "$VULKAN_AVAILABLE" -eq 1 ]; then
  echo "Vulkan 도 사용 가능합니다 (선택 목록에 포함됩니다)"
fi

if [ "$USE_CUDA" -eq 0 ] && [ "$USE_ROCM" -eq 0 ] && [ "$USE_METAL" -eq 0 ] && [ "$USE_VULKAN" -eq 0 ]; then
  echo "가속기를 찾지 못함 → CPU-only 빌드로 진행"
fi

# --- 3d-2. 자동 감지 결과를 GGML_BACKEND 환경변수로 강제 override 가능 ---
#     예: GGML_BACKEND=vulkan bash build_llama_server.sh   (ROCm이 있어도 Vulkan으로 강제)
#         GGML_BACKEND=cpu    bash build_llama_server.sh   (문제 있는 가속기 우회, 트러블슈팅용)
FORCE_BACKEND="${GGML_BACKEND:-auto}"

# --- 3d-3. 대화형 백엔드 선택 ---
# 백엔드를 지정하지 않았고 터미널에서 실행 중이면, 이 기기에서 실제로 빌드 가능한
# 백엔드를 나열해 고르게 한다. 설치 디렉터리가 백엔드별로 분리되므로
# (llama_server_rocm / llama_server_vulkan / ...) 여러 개를 만들어 두고
# run_llama_server.sh 에서 골라 쓸 수 있다.
# --backend <name> 인자로도 지정 가능하며, 비대화형(파이프/CI)에서는 자동 감지를 따른다.
# read 는 EOF 에서 실패해 기본값(자동 감지 결과)으로 떨어지므로 [ -t 0 ] 가드가 없어도
# 비대화형에서 멈추지 않는다. 오히려 가드를 두면 파이프로 넘긴 선택값이 무시되어
# run_llama_server.sh 및 이 스크립트의 다른 프롬프트와 동작이 어긋난다.
if [ "$FORCE_BACKEND" = "auto" ] && [ "${NONINTERACTIVE:-0}" != "1" ]; then
  AVAIL_TAGS=(); AVAIL_DESC=()
  [ "$USE_CUDA"   -eq 1 ] && { AVAIL_TAGS+=("cuda");   AVAIL_DESC+=("CUDA (NVIDIA)"); }
  [ "$USE_ROCM"   -eq 1 ] && { AVAIL_TAGS+=("rocm");   AVAIL_DESC+=("ROCm/HIP (AMD)"); }
  [ "$USE_VULKAN" -eq 1 ] && { AVAIL_TAGS+=("vulkan"); AVAIL_DESC+=("Vulkan (벤더 무관)"); }
  [ "$USE_METAL"  -eq 1 ] && { AVAIL_TAGS+=("metal");  AVAIL_DESC+=("Metal (Apple)"); }

  # 자동 감지가 고른 것 외에 다른 선택지도 제시한다.
  # (예: ROCm 이 감지돼도 Vulkan 으로 빌드해 두고 비교하고 싶을 수 있다)
  # [FIX] 예전에는 -n "${VULKAN_AVAILABLE:-}" 로 검사했는데 그 변수가 어디에도 정의되지
  # 않아 조건이 항상 거짓이었고, 결국 Vulkan 이 목록에 절대 나타나지 않았다.
  # 이제 3d 에서 VULKAN_AVAILABLE 을 실제로 계산하므로 값으로 비교한다.
  if [ "$USE_VULKAN" -eq 0 ] && [ "${VULKAN_AVAILABLE:-0}" -eq 1 ]; then
    AVAIL_TAGS+=("vulkan"); AVAIL_DESC+=("Vulkan (벤더 무관)")
  fi
  AVAIL_TAGS+=("cpu"); AVAIL_DESC+=("CPU 전용 (가속 없음)")

  if [ ${#AVAIL_TAGS[@]} -gt 1 ]; then
    echo ""
    echo "빌드할 백엔드를 선택하세요 (설치 위치: ${SCRIPT_DIR}/llama_server_<백엔드>):"
    for i in "${!AVAIL_TAGS[@]}"; do
      mark=""
      [ "$i" -eq 0 ] && mark="  ← 자동 감지 결과"
      existing=""
      [ -d "${SCRIPT_DIR}/llama_server_${AVAIL_TAGS[$i]}" ] && existing="  [이미 설치됨 — 덮어씀]"
      printf "  [%d] %-22s %s%s\n" "$i" "${AVAIL_DESC[$i]}" "$mark" "$existing"
    done
    _bsel=""
    read -r -p "번호 선택 [기본값 0: ${AVAIL_DESC[0]}]: " _bsel || true
    if [[ "$_bsel" =~ ^[0-9]+$ ]] && [ "$_bsel" -lt "${#AVAIL_TAGS[@]}" ]; then
      FORCE_BACKEND="${AVAIL_TAGS[$_bsel]}"
    else
      FORCE_BACKEND="${AVAIL_TAGS[0]}"
    fi
    echo "선택됨: $FORCE_BACKEND"
  fi
fi

if [ "$FORCE_BACKEND" != "auto" ]; then
  echo "빌드 백엔드: $FORCE_BACKEND (자동 감지 결과보다 우선 적용)"
  USE_CUDA=0; USE_ROCM=0; USE_METAL=0; USE_VULKAN=0
  case "$FORCE_BACKEND" in
    cuda)   [ -z "$NVCC_BIN" ] && { echo "Error: nvcc를 찾을 수 없어 GGML_BACKEND=cuda 강제 적용 불가" >&2; exit 1; }; USE_CUDA=1 ;;
    hip|rocm) USE_ROCM=1 ;;
    vulkan) USE_VULKAN=1 ;;
    metal)  USE_METAL=1 ;;
    cpu)    : ;;  # 전부 0으로 CPU-only
    *) echo "Error: 알 수 없는 GGML_BACKEND=$FORCE_BACKEND (cuda|hip|vulkan|metal|cpu 중 하나)" >&2; exit 1 ;;
  esac
fi

# --- 3d-4. 백엔드가 확정됐으므로 설치 디렉터리 이름을 정한다 ---
# GPU 백엔드는 백엔드 이름으로, CPU 전용은 아키텍처로 구분한다
# (CPU 빌드는 -march=native 등 아키텍처 의존 최적화가 들어가므로 x86_64/aarch64 구분이 의미 있다).
if   [ "$USE_CUDA"   -eq 1 ]; then BACKEND_TAG="cuda"
elif [ "$USE_ROCM"   -eq 1 ]; then BACKEND_TAG="rocm"
elif [ "$USE_VULKAN" -eq 1 ]; then BACKEND_TAG="vulkan"
elif [ "$USE_METAL"  -eq 1 ]; then BACKEND_TAG="metal"
else                               BACKEND_TAG="$ARCH_NAME"   # 예: x86_64, aarch64
fi

if [ "$INSTALL_DIR_EXPLICIT" -eq 0 ]; then
  INSTALL_DIR="${SCRIPT_DIR}/llama_server_${BACKEND_TAG}"
fi
BACKUP_DIR=${BACKUP_DIR:-${INSTALL_DIR}_backup_$(date +%s)}
echo "설치 위치: $INSTALL_DIR"

# ─────────────────────────────────────────────
# 3e. Vulkan 빌드 의존성 자동 설치 (libvulkan-dev, glslc, spirv-headers)
#     cmake 탐색(2번 섹션)과 동일한 우선순위로 처리: 이미 있으면 스킵 → 패키지 매니저로 설치.
#     glslc(셰이더 컴파일러)는 Ubuntu/Debian에서 별도 패키지로 분리되어 있어
#     libvulkan-dev/glslang-tools만 깔면 놓치기 쉬우므로 명시적으로 확인한다.
# ─────────────────────────────────────────────
if [ "$USE_VULKAN" -eq 1 ]; then
  section "3e. Vulkan 빌드 의존성 확인"

  NEED_PKGS=()
  [ -f /usr/include/vulkan/vulkan.h ] || NEED_PKGS+=("vulkan-headers-or-dev")
  command -v glslc >/dev/null 2>&1 || NEED_PKGS+=("glslc")
  # SPIRV-Headers는 헤더 전용 패키지라 파일 존재로만 확인 가능한 표준 경로가 없어
  # cmake find_package 실패 여부로 사실상 판단되지만, 미리 설치 시도는 해둔다.

  if [ ${#NEED_PKGS[@]} -gt 0 ]; then
    echo "부족한 Vulkan 빌드 도구: ${NEED_PKGS[*]}"
    if command -v apt-get >/dev/null 2>&1; then
      echo "apt-get로 설치 중: libvulkan-dev glslang-tools glslc spirv-headers"
      _sudo apt-get update >/dev/null 2>&1 || true
      _sudo apt-get install -y libvulkan-dev glslang-tools glslc spirv-headers 2>&1 \
        | grep -E "^(Setting|Processing|Unpacking|E:)" || true
    elif command -v dnf >/dev/null 2>&1; then
      echo "dnf로 설치 중: vulkan-loader-devel vulkan-headers glslang spirv-headers-devel"
      _sudo dnf install -y vulkan-loader-devel vulkan-headers glslang spirv-headers-devel 2>&1 | tail -5
    elif command -v pacman >/dev/null 2>&1; then
      echo "pacman으로 설치 중: vulkan-headers vulkan-icd-loader shaderc spirv-headers"
      _sudo pacman -S --noconfirm vulkan-headers vulkan-icd-loader shaderc spirv-headers 2>&1 | tail -5
    elif command -v brew >/dev/null 2>&1; then
      echo "brew로 설치 중: shaderc molten-vk"
      brew install shaderc molten-vk 2>&1 | tail -5
    else
      echo "Warning: 알려진 패키지 매니저가 없어 Vulkan 의존성을 자동 설치하지 못했습니다." >&2
    fi
  fi

  if ! command -v glslc >/dev/null 2>&1; then
    echo "Warning: glslc 를 여전히 찾을 수 없습니다. Vulkan 빌드가 실패하면 CPU-only로 폴백하세요:" >&2
    echo "  GGML_BACKEND=cpu bash build_llama_server.sh" >&2
  fi
fi

# ─────────────────────────────────────────────
# 3f. GPU 디바이스 노드 접근 권한 확인 (ROCm/HIP, Vulkan 공통)
#     /dev/kfd(ROCm 컴퓨트), /dev/dri/renderD*(DRM render node)는 보통
#     root:render 소유라서, 사용자가 render(및 GUI 세션 카드 접근용 video) 그룹에
#     속해 있지 않으면 빌드는 성공해도 런타임에 "권한 거부"로 GPU를 못 잡는다.
#     빌드 시점에 미리 알려주면 나중에 원인 모를 실패로 헤매는 걸 방지할 수 있다.
# ─────────────────────────────────────────────
if [ "$OS_NAME" = "Linux" ] && { [ "$USE_ROCM" -eq 1 ] || [ "$USE_VULKAN" -eq 1 ]; } && [ -e /dev/dri/renderD128 ]; then
  section "3f. GPU 디바이스 권한 확인"

  # [FIX] 예전엔 'id -nG "$USER" | grep -qw render' 로만 판정했다. 그런데 id 에 사용자
  # 이름을 주면 **현재 프로세스의 그룹이 아니라 /etc/group 을 조회**한다. 그래서
  # usermod 직후(재로그인 전)에는 파일에는 render 가 있지만 현재 셸에는 반영되지 않은
  # 상태인데도 "접근 가능" 이라고 보고했다. 실제로 이 상황에서 그렇게 출력해 놓고
  # 정작 rocminfo 와 llama-server 는 권한 거부로 GPU 를 못 잡았다.
  # 판정은 그룹 목록이 아니라 "정말 열리는가" 로 한다.
  _can_open() { (exec 3<>"$1") 2>/dev/null && exec 3>&-; }

  KFD_OK=1; DRI_OK=1
  [ "$USE_ROCM" -eq 1 ] && { _can_open /dev/kfd || KFD_OK=0; }
  _can_open /dev/dri/renderD128 || DRI_OK=0

  if [ "$KFD_OK" -eq 1 ] && [ "$DRI_OK" -eq 1 ]; then
    echo "GPU 디바이스 접근 확인됨 (실제로 열어서 확인)."
  else
    echo "⚠️  GPU 디바이스를 열 수 없습니다:$( [ "$KFD_OK" -eq 0 ] && echo ' /dev/kfd')$( [ "$DRI_OK" -eq 0 ] && echo ' /dev/dri/renderD128')"
    echo "    빌드는 계속되지만, 이대로면 런타임에 GPU 를 못 잡습니다."
    if id -nG "$USER" 2>/dev/null | grep -qw render; then
      # /etc/group 에는 있는데 못 여는 경우 = 재로그인만 하면 되는 상태
      echo "    /etc/group 에는 render 가 있습니다 → 현재 세션에만 미반영입니다."
      echo "    해결: 로그아웃 후 다시 로그인 (또는 newgrp render)"
    else
      echo "    해결: sudo usermod -aG render,video $USER   그 뒤 재로그인"
    fi
  fi
fi

# ─────────────────────────────────────────────
# 4. cmake 플래그 결정 (배열에 누적)
# ─────────────────────────────────────────────
section "4. 빌드 플래그 결정"

# 공통: 항상 Release + C++17
# (구버전 llama.cpp cmake의 -DLLAMA_BUILD_SERVER=ON 은 현재 빌드시스템에서 인식되지
#  않는 죽은 변수라 제거함 — llama-server는 기본 타겟으로 항상 함께 빌드된다.)
CMAKE_ARGS+=(-DCMAKE_BUILD_TYPE=Release)
CMAKE_ARGS+=(-DCMAKE_CXX_STANDARD=17)

# ─────────────────────────────────────────────
# SSL(OpenSSL) 지원 — 두 가지 이유로 필요:
#   1) 서버 자체 HTTPS 서빙(--ssl-key/--ssl-cert)
#   2) cors-proxy 가 외부 HTTPS(MCP 서버 등)로 아웃바운드 요청 (CPPHTTPLIB_OPENSSL_SUPPORT)
# OpenSSL 개발 헤더가 없으면 --ui-mcp-proxy 사용 시
#   "HTTPS requested but CPPHTTPLIB_OPENSSL_SUPPORT is not defined" 로 실패한다.
#
# 탐색 우선순위(권한 부담이 적은 순): 시스템 헤더 → conda → conda 설치(무권한) → sudo(best-effort).
# 끝까지 못 구하면 '경고만' 내고 SSL 없이 빌드(빌드 자체는 성공)한다.
# 런타임 libssl/libcrypto 는 더 이상 여기서 직접 챙기지 않는다 — 9번 섹션의
# ldd 기반 자동 탐지가 실제로 링크된 libssl/libcrypto를 알아서 찾아 복사한다.
USE_SSL=0

# (a) 시스템 헤더가 있으면 그대로 사용 (root dir 지정 불필요)
if [ -f /usr/include/openssl/ssl.h ]; then
  echo "시스템 OpenSSL 헤더 사용: /usr/include/openssl"
  USE_SSL=1
fi

# (b) 없으면 conda(활성 env → llama_env → base 등)에서 탐색 (무권한)
if [ "$USE_SSL" -eq 0 ]; then
  OSSL_SEARCH=()
  [ -n "${CONDA_PREFIX:-}" ] && OSSL_SEARCH+=("$CONDA_PREFIX")
  OSSL_SEARCH+=("$HOME/miniconda3/envs/llama_env" "$HOME/miniconda3" \
               "$HOME/anaconda3/envs/llama_env" "$HOME/anaconda3" "/opt/conda")
  for root in "${OSSL_SEARCH[@]}"; do
    if [ -f "$root/include/openssl/ssl.h" ] && ls "$root"/lib/libssl.so* >/dev/null 2>&1; then
      echo "conda OpenSSL 사용: $root"
      CMAKE_ARGS+=(-DOPENSSL_ROOT_DIR="$root")
      USE_SSL=1
      break
    fi
  done
fi

# (c) 그래도 없으면 conda 로 설치 시도 (무권한)
if [ "$USE_SSL" -eq 0 ] && [ -n "$CMAKE_BIN" ]; then
  CONDA_CMD=""
  for root in "${CONDA_ROOTS[@]:-}"; do
    [ -n "$root" ] && [ -x "$root/bin/conda" ] && CONDA_CMD="$root/bin/conda" && break
  done
  if [ -n "$CONDA_CMD" ]; then
    echo "conda 로 OpenSSL 설치 시도 (무권한)..."
    "$CONDA_CMD" install -y -c conda-forge openssl 2>&1 | tail -3 || true
    for root in "${CONDA_ROOTS[@]:-}"; do
      if [ -f "$root/include/openssl/ssl.h" ] && ls "$root"/lib/libssl.so* >/dev/null 2>&1; then
        CMAKE_ARGS+=(-DOPENSSL_ROOT_DIR="$root"); USE_SSL=1; break
      fi
    done
  fi
fi

# (d) 최후의 수단: 시스템 패키지(best-effort). 실패해도 빌드는 계속.
if [ "$USE_SSL" -eq 0 ]; then
  echo "무권한 경로 실패 → 시스템 패키지(sudo) best-effort 시도"
  if   command -v apt-get >/dev/null 2>&1; then _sudo apt-get install -y libssl-dev    2>&1 | tail -2 || true
  elif command -v dnf     >/dev/null 2>&1; then _sudo dnf     install -y openssl-devel 2>&1 | tail -2 || true
  elif command -v yum     >/dev/null 2>&1; then _sudo yum     install -y openssl-devel 2>&1 | tail -2 || true
  elif command -v pacman  >/dev/null 2>&1; then _sudo pacman  -S --noconfirm openssl   2>&1 | tail -2 || true
  fi
  [ -f /usr/include/openssl/ssl.h ] && USE_SSL=1
fi

# 결과 반영
if [ "$USE_SSL" -eq 1 ]; then
  echo "SSL 활성화: -DLLAMA_SERVER_SSL=ON"
  CMAKE_ARGS+=(-DLLAMA_SERVER_SSL=ON)
else
  echo "⚠️  OpenSSL 을 확보하지 못했습니다 → SSL 없이 빌드합니다."
  echo "    이 경우 --ui-mcp-proxy 로 외부 HTTPS MCP(예: Tavily) 연결이 동작하지 않습니다."
  echo "    무권한 해결: conda install -c conda-forge openssl  (또는 관리자에게 libssl-dev 요청)"
fi

# 백엔드별 플래그
if [ "$USE_CUDA" -eq 1 ]; then
  echo "CUDA 빌드 활성화: -DGGML_CUDA=ON"
  CMAKE_ARGS+=(-DGGML_CUDA=ON)
  [ -n "$NVCC_BIN" ] && CMAKE_ARGS+=(-DCMAKE_CUDA_COMPILER="$NVCC_BIN")

  CUDA_PREFIX="$(dirname "$(dirname "$NVCC_BIN")")"
  if [ -d "$CUDA_PREFIX/targets" ]; then
    CUDA_TARGET_INCLUDE="$(find "$CUDA_PREFIX/targets" -path '*/include' -type d 2>/dev/null | head -n1 || true)"
    if [ -n "$CUDA_TARGET_INCLUDE" ] && [ -f "$CUDA_TARGET_INCLUDE/cuda_runtime.h" ]; then
      # Newer CUDA packages place CUB/Thrust below the CCCL include directory.
      CUDA_CCCL_INCLUDE=""
      if [ -f "$CUDA_TARGET_INCLUDE/cccl/cub/cub.cuh" ]; then
        CUDA_CCCL_INCLUDE="$CUDA_TARGET_INCLUDE/cccl"
      fi
      export CUDA_HOME="$CUDA_PREFIX"
      export CUDA_PATH="$CUDA_PREFIX"
      export CUDAToolkit_ROOT="$CUDA_PREFIX"
      export CUDA_TOOLKIT_ROOT_DIR="$CUDA_PREFIX"
      export CPATH="$CUDA_TARGET_INCLUDE:${CPATH:-}"
      export CPLUS_INCLUDE_PATH="$CUDA_TARGET_INCLUDE:${CPLUS_INCLUDE_PATH:-}"
      if [ -n "$CUDA_CCCL_INCLUDE" ]; then
        export CPATH="$CUDA_CCCL_INCLUDE:$CPATH"
        export CPLUS_INCLUDE_PATH="$CUDA_CCCL_INCLUDE:$CPLUS_INCLUDE_PATH"
        echo "CUDA CCCL include 경로 추가: $CUDA_CCCL_INCLUDE"
      fi
      echo "CUDA include/root 강제 지정: CUDA_HOME=$CUDA_HOME CUDAToolkit_ROOT=$CUDAToolkit_ROOT"
      CMAKE_ARGS+=(-DCUDAToolkit_ROOT="$CUDA_PREFIX")
      CUDA_TOOLKIT_INCLUDES="$CUDA_TARGET_INCLUDE"
      [ -n "$CUDA_CCCL_INCLUDE" ] && CUDA_TOOLKIT_INCLUDES="$CUDA_TOOLKIT_INCLUDES;$CUDA_CCCL_INCLUDE"
      CMAKE_ARGS+=(-DCMAKE_CUDA_TOOLKIT_INCLUDE_DIRECTORIES="$CUDA_TOOLKIT_INCLUDES")
    fi
  fi
elif [ "$USE_ROCM" -eq 1 ]; then
  echo "ROCm(HIP) 빌드 활성화: -DGGML_HIP=ON"
  CMAKE_ARGS+=(-DGGML_HIP=ON)

  # [FIX] 3c에서 고른 ROCm 루트를 cmake에 "명시적으로" 못박는다.
  # 안 그러면 cmake가 /opt/rocm(최신, 내 GPU 미지원일 수 있음)이나 배포판이 설치한
  # 구버전 /usr 헤더를 섞어 잡아서, configure는 통과해도 컴파일에서 깨진다.
  # 3c 가 레이아웃을 이미 판별해 뒀으므로 경로를 다시 조립하지 않고 그대로 쓴다.
  # (공식 /opt/rocm-* 와 배포판 /usr 은 cmake 디렉터리·컴파일러 위치가 서로 다르다)
  if [ -n "${ROCM_ROOT:-}" ]; then
    # [FIX] ROCM_PATH 를 무조건 내보내면 배포판 설치에서 빌드가 깨진다.
    # clang 은 ROCM_PATH 가 있으면 "<ROCM_PATH>/amdgcn/bitcode" 에서 device library 를
    # 찾는다. AMD 공식 설치(/opt/rocm-*)에는 거기에 실제로 있으니 알려주는 게 맞다.
    # 그런데 배포판 설치는 device library 가 clang 의 resource dir
    # (/usr/lib/llvm-21/lib/clang/21/amdgcn/bitcode) 에 있고 /usr/amdgcn/bitcode 는 없다.
    # 이때 ROCM_PATH=/usr 를 내보내면 clang 이 없는 경로만 보고 이렇게 죽는다:
    #     clang++: error: cannot find ROCm device library
    # 실측: ROCM_PATH 설정 시 컴파일 실패, 해제 시 성공(resource dir 로 자동 폴백).
    # llama.cpp 의 cmake 도 ROCM_PATH 가 비어 있으면 알아서 /usr 을 잡고, 어차피
    # hip_DIR/hipblas_DIR/rocblas_DIR 을 아래에서 명시하므로 find_package 에도 지장이 없다.
    if [ -d "$ROCM_ROOT/amdgcn/bitcode" ]; then
      export HIP_PATH="$ROCM_ROOT"
      export ROCM_PATH="$ROCM_ROOT"
    else
      unset HIP_PATH ROCM_PATH 2>/dev/null || true
      echo "  ROCM_PATH 는 설정하지 않습니다 ($ROCM_ROOT/amdgcn/bitcode 없음 → clang resource dir 사용)"
    fi
    # hipcc 래퍼는 cmake가 HIP 컴파일러로 직접 받아주지 않으므로 실제 clang++를 지정
    [ -n "${ROCM_CLANGXX:-}" ] && CMAKE_ARGS+=(-DCMAKE_HIP_COMPILER="$ROCM_CLANGXX")
    if [ -n "${ROCM_CMAKE_DIR:-}" ]; then
      CMAKE_ARGS+=(-Dhip_DIR="$ROCM_CMAKE_DIR/hip")
      CMAKE_ARGS+=(-Dhipblas_DIR="$ROCM_CMAKE_DIR/hipblas")
      CMAKE_ARGS+=(-Drocblas_DIR="$ROCM_CMAKE_DIR/rocblas")
      [ -d "$ROCM_CMAKE_DIR/hip-lang" ] && CMAKE_ARGS+=(-Dhip-lang_DIR="$ROCM_CMAKE_DIR/hip-lang")
    fi
  fi

  # 내 GPU 아키텍처만 컴파일 → 빌드 시간이 크게 줄고, 지원 안 되는 아키텍처에서
  # 나는 컴파일 오류도 피할 수 있다.
  # [FIX] AMDGPU_TARGETS 는 ROCm 6.4 부터 GPU_TARGETS 로 이름이 바뀌며 deprecated 되어
  # cmake 경고를 뿜는다. llama.cpp 는 GPU_TARGETS → CMAKE_HIP_ARCHITECTURES 로 넘겨주고,
  # CMAKE_HIP_ARCHITECTURES 는 CMake 의 HIP 언어가 직접 해석하므로 둘만 주면 충분하다.
  if [ -n "${GPU_ARCH:-}" ]; then
    echo "  타겟 아키텍처 한정: $GPU_ARCH"
    CMAKE_ARGS+=(-DGPU_TARGETS="$GPU_ARCH")
    CMAKE_ARGS+=(-DCMAKE_HIP_ARCHITECTURES="$GPU_ARCH")

    # 컴파일러 쪽 지원 여부도 미리 본다. device-libs 는 아키텍처별 비트코드를
    #   oclc_isa_version_906.bc  (gfx906 → 906)
    # 로 담고 있어서, 없으면 device 링크 단계에서야 알 수 없는 오류로 터진다.
    if [ -n "${ROCM_CLANGXX:-}" ]; then
      _llvmroot="${ROCM_CLANGXX%/bin/clang++}"
      if ! ls "$_llvmroot"/lib/clang/*/amdgcn/bitcode/oclc_isa_version_"${GPU_ARCH#gfx}".bc \
             >/dev/null 2>&1; then
        echo "⚠️  $ROCM_CLANGXX 의 device-libs 에 ${GPU_ARCH} 비트코드가 없습니다."
        echo "    이 컴파일러는 ${GPU_ARCH} 코드를 생성하지 못합니다 → 빌드가 실패할 수 있습니다."
      fi
    fi
  fi

  # 배포판이 설치한 구버전 ROCm 헤더(/usr/include/hip 등)가 남아 있으면 위에서 지정한
  # ROCm 루트의 헤더보다 먼저 잡혀서 빌드가 깨진다. 자동으로 지우지는 않고 경고만 한다.
  for stale in /usr/include/hip /usr/include/hipblas /usr/include/rocblas; do
    if [ -d "$stale" ] && [ -n "${ROCM_ROOT:-}" ] && [ "$ROCM_ROOT" != "/usr" ]; then
      echo "⚠️  구버전 ROCm 헤더가 남아 있습니다: $stale"
      echo "    $ROCM_ROOT 의 헤더와 충돌해 빌드가 실패할 수 있습니다."
      echo "    해결(둘 중 하나): sudo mv $stale ${stale}.disabled"
      echo "                     또는 해당 dev 패키지 제거(libamdhip64-dev/libhipblas-dev/librocblas-dev)"
    fi
  done
elif [ "$USE_VULKAN" -eq 1 ]; then
  echo "Vulkan 빌드 활성화: -DGGML_VULKAN=ON"
  CMAKE_ARGS+=(-DGGML_VULKAN=ON)
elif [ "$USE_METAL" -eq 1 ]; then
  echo "Metal 빌드 활성화: -DGGML_METAL=ON"
  CMAKE_ARGS+=(-DGGML_METAL=ON)
else
  echo "CPU-only 빌드"
fi

# CPU SIMD 자동 감지 — x86 계열에서만 AVX 플래그가 의미 있음.
# ARM(aarch64/arm64)에서는 NEON이 기본이라 별도 플래그 불필요 (잘못된 AVX 플래그 주입 방지).
case "$ARCH_NAME" in
  x86_64|amd64|i?86)
    if grep -q avx512f /proc/cpuinfo 2>/dev/null; then
      echo "AVX-512 감지 → -DGGML_AVX512=ON"
      CMAKE_ARGS+=(-DGGML_AVX512=ON)
    elif grep -q avx2 /proc/cpuinfo 2>/dev/null; then
      echo "AVX2 감지 → -DGGML_AVX2=ON"
      CMAKE_ARGS+=(-DGGML_AVX2=ON)
    else
      echo "AVX2/512 미감지 → 기본 SIMD로 빌드"
    fi
    ;;
  aarch64|arm64)
    echo "ARM64 감지 → NEON 기본 사용 (AVX 플래그 생략)"
    ;;
  *)
    echo "알 수 없는 아키텍처($ARCH_NAME) → SIMD 플래그 cmake 자동 결정에 위임"
    ;;
esac

JOBS=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
echo "병렬 빌드 잡: $JOBS"

# 링커 플래그는 호스트 툴체인을 확정한 뒤 아래에서 추가한다.
# 주: -fPIC는 llama.cpp가 공유 라이브러리 빌드 시 cmake가 자동 부여하므로
#     직접 지정하지 않는다(이식성 + 중복 방지).

# ─────────────────────────────────────────────
# 4b. CUDA 전용: host gcc 호환성 처리
#     CUDA 12.x는 GCC<=13까지 공식 지원. host gcc가 14+면 nvcc가 거부하므로
#     (1) <=13 host gcc를 찾아 -DCMAKE_CUDA_HOST_COMPILER로 지정
#     (2) 못 찾으면 --allow-unsupported-compiler 래퍼로 강행
# ─────────────────────────────────────────────
if [ "$USE_CUDA" -eq 1 ]; then
  section "4b. CUDA host gcc 호환성"

  # 적합한 host gcc(<=13) 탐색
  HOST_GCC=""
  for cand in /usr/bin/gcc-13 /usr/bin/gcc-12 /usr/bin/gcc-11 /usr/bin/gcc; do
    if [ -x "$cand" ]; then
      ver=$("$cand" -dumpfullversion 2>/dev/null || "$cand" -dumpversion 2>/dev/null || true)
      maj=$(echo "$ver" | cut -d. -f1)
      if [ -n "$maj" ] && [ "$maj" -le 13 ]; then
        HOST_GCC="$cand"
        echo "host gcc 선택: $HOST_GCC (version $ver)"
        break
      fi
    fi
  done

  if [ -z "$HOST_GCC" ] && command -v apt-get >/dev/null 2>&1; then
    echo "CUDA 12.x 호환 GCC(<=13)가 없어 시스템 패키지를 설치합니다: gcc-13 g++-13"
    _sudo apt-get update >/dev/null 2>&1 || true
    _sudo apt-get install -y gcc-13 g++-13 2>&1 | tail -20 || true
    for cand in /usr/bin/gcc-13 /usr/bin/g++-13; do
      [ -x "$cand" ] || continue
      if [ "${cand##*/}" = "gcc-13" ]; then
        HOST_GCC="$cand"
      fi
    done
  fi

  if [ -n "$HOST_GCC" ]; then
    # nvcc는 실행 중 자체 CUDA bin 경로를 PATH 앞에 삽입한다. 그러면 host
    # GCC가 다시 conda ld를 선택하므로, 시스템 binutils를 보장하는 래퍼를 쓴다.
    CUDA_HOST_WRAPPER="/tmp/cuda-host-gcc-$$"
    printf '%s\n' '#!/usr/bin/env bash' 'export PATH=/usr/bin:/bin' "exec $HOST_GCC \"\$@\"" >"$CUDA_HOST_WRAPPER"
    chmod +x "$CUDA_HOST_WRAPPER"
    trap 'rm -f "$CUDA_HOST_WRAPPER"' EXIT
    CMAKE_ARGS+=(-DCMAKE_CUDA_HOST_COMPILER="$CUDA_HOST_WRAPPER")
  else
    # <=13 host gcc가 없음 → CUDA를 끄지 않고, 래퍼로 강행 시도
    echo "Warning: GCC<=13 미발견 → nvcc에 --allow-unsupported-compiler 래퍼 적용"
    REAL_NVCC="${NVCC_BIN:-$(command -v nvcc 2>/dev/null || true)}"
    if [ -n "$REAL_NVCC" ] && [ -x "$REAL_NVCC" ]; then
      WRAPPER_DIR="/tmp/nvcc-wrapper-$$"
      mkdir -p "$WRAPPER_DIR"
      trap 'rm -rf "$WRAPPER_DIR"' EXIT
      cat > "$WRAPPER_DIR/nvcc" <<NVCC_WRAPPER
#!/usr/bin/env bash
exec "$REAL_NVCC" --allow-unsupported-compiler "\$@"
NVCC_WRAPPER
      chmod +x "$WRAPPER_DIR/nvcc"
      export PATH="$WRAPPER_DIR:$PATH"
      # cmake가 래퍼를 쓰도록 컴파일러 경로를 래퍼로 덮어씀
      CMAKE_ARGS+=(-DCMAKE_CUDA_COMPILER="$WRAPPER_DIR/nvcc")
      CMAKE_ARGS+=(-DCMAKE_CUDA_FLAGS=--allow-unsupported-compiler)
      echo "nvcc 래퍼 생성: $WRAPPER_DIR/nvcc → $REAL_NVCC"
    else
      echo "Warning: nvcc 실체를 찾지 못해 래퍼 생성 불가. CUDA 빌드가 실패할 수 있음." >&2
    fi
  fi
fi

# ─────────────────────────────────────────────
# 4c. C/C++ 툴체인 확인 (컴파일러 + 빌드 프로그램)
# ─────────────────────────────────────────────
# cmake 는 "빌드 시스템을 만들어 주는 도구"일 뿐이다. 실제로 컴파일할 gcc/clang 과
# 그것을 굴릴 make/ninja 가 따로 있어야 한다. 최소 설치 이미지(서버 이미지, 컨테이너,
# 새로 민 데스크톱)에는 둘 다 없는 경우가 흔한데, 그러면 configure 에서 이렇게 죽는다:
#     CMake Error: unable to find a build program corresponding to "Unix Makefiles"
#     CMake Error: CMAKE_CXX_COMPILER not set, after EnableLanguage
# cmake·Vulkan 의존성·OpenSSL 은 자동 설치하면서 정작 이걸 안 챙기면 거기서 멈춘다.
# (실제로 Ubuntu 26.04 새 설치에서 이 지점에 걸렸다. hipcc 가 되니 컴파일러가 있는
#  줄 알기 쉬운데, hipcc 는 PATH 가 아니라 자기 안의 LLVM 을 쓰는 것이라 별개다.)
section "4c. C/C++ 툴체인 확인"

_find_first() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return 0; }; done; return 1; }

# [FIX] conda 툴체인은 일부러 뒤로 미룬다.
# 벤더 SDK(ROCm/CUDA)는 시스템 glibc 기준으로 빌드된 .so 를 내놓는데, 링크를 conda 의
# 구버전 sysroot/ld 가 맡으면 심볼 버전이 어긋나 실패한다. 그것도 컴파일이 전부 끝난
# 뒤 링크 단계에서야 터진다. 실제로 이렇게 68% 에서 빌드를 날렸다:
#     x86_64-conda-linux-gnu-ld: libggml-hip.so: undefined reference to `sqrtf@GLIBC_2.43'
# conda 가 PATH 앞에 있는 환경(conda base 활성화)이 흔하므로 순서에만 맡기면 안 된다.
_find_first_nonconda() {
  local c p
  for c in "$@"; do
    p=$(command -v "$c" 2>/dev/null) || continue
    case "$p" in *conda*) continue ;; esac
    printf '%s' "$p"; return 0
  done
  return 1
}

GEN_PROG=$(_find_first ninja make || true)
HOST_CC=$(_find_first_nonconda cc gcc clang || true)
HOST_CXX=$(_find_first_nonconda c++ g++ clang++ || true)

# 컴파일러와 링커는 서로 별도로 선택된다. conda 환경이 PATH 앞에 있으면
# /usr/bin/cc 를 골라도 GCC가 conda 의 ld 를 실행할 수 있다. conda ld 는
# 시스템 glibc 와 링크할 때 심볼 버전 충돌을 일으키므로, 시스템 링커를 명시한다.
HOST_LD=$(_find_first_nonconda ld || true)
if [ -z "$HOST_LD" ] && [ -x /usr/bin/ld ]; then
  HOST_LD=/usr/bin/ld
fi

# 시스템에 이미 깔린 LLVM 도 후보다. ROCm 을 설치하면 /usr/lib/llvm-21/bin/clang++ 가
# 딸려 오는데 PATH 에는 안 잡힌다. HIP 컴파일러와 같은 계열이라 링커/glibc 세대가
# 어긋나지 않는다. 설치가 전혀 필요 없는 선택지이므로 패키지 설치를 시도하기 **전에**
# 먼저 본다 — 안 그러면 이미 쓸 수 있는 컴파일러를 두고 괜히 sudo 를 물어보게 된다.
if [ -z "$HOST_CXX" ]; then
  for c in $(ls -d /usr/lib/rocm/llvm/bin/clang++ /usr/lib/llvm-*/bin/clang++ 2>/dev/null | sort -Vr); do
    [ -x "$c" ] || continue
    HOST_CXX="$c"; [ -x "${c%++}" ] && HOST_CC="${c%++}"
    echo "PATH 에 (conda 아닌) 컴파일러가 없어 시스템 LLVM 을 사용합니다: $HOST_CXX"
    break
  done
fi

if [ -z "$GEN_PROG" ] || [ -z "$HOST_CXX" ]; then
  # [FIX] 예전엔 '${GEN_PROG:-라벨}' 로 찍어서, 찾은 경우엔 그 경로가 그대로 나왔다.
  # 그래서 ninja 가 멀쩡히 있는데도 "부족한 것: /…/ninja" 처럼 반대로 읽히는 문구가 됐다.
  # 없는 것만 나열한다.
  MISSING=""
  [ -z "$GEN_PROG" ]  && MISSING="$MISSING 빌드프로그램(make|ninja)"
  [ -z "$HOST_CXX" ]  && MISSING="$MISSING C++컴파일러"
  echo "부족한 것:$MISSING"
  if   command -v apt-get >/dev/null 2>&1; then
    echo "apt-get 로 설치 중: build-essential"
    _sudo apt-get install -y build-essential 2>&1 | grep -E "^(Setting|Processing|E:)" || true
  elif command -v dnf >/dev/null 2>&1; then _sudo dnf install -y gcc gcc-c++ make 2>&1 | tail -3
  elif command -v yum >/dev/null 2>&1; then _sudo yum install -y gcc gcc-c++ make 2>&1 | tail -3
  elif command -v pacman >/dev/null 2>&1; then _sudo pacman -S --noconfirm base-devel 2>&1 | tail -3
  elif command -v brew >/dev/null 2>&1; then echo "macOS: xcode-select --install 이 필요할 수 있습니다"
  fi
  GEN_PROG=$(_find_first ninja make || true)
  [ -n "$HOST_CC" ]  || HOST_CC=$(_find_first_nonconda cc gcc clang || true)
  [ -n "$HOST_CXX" ] || HOST_CXX=$(_find_first_nonconda c++ g++ clang++ || true)
fi

if [ -n "$HOST_LD" ]; then
  echo "시스템 링커 사용: $HOST_LD"
  # GCC/nvcc는 PATH에서 ld를 찾으므로, 아래에서 시스템 경로를 우선시한다.
  # -B를 강제로 주면 GCC의 libgcc/libstdc++ 탐색까지 바뀔 수 있다.
  LD_FLAGS=""
  if [ "$OS_NAME" = "Linux" ] && "$HOST_LD" --version 2>/dev/null | grep -qi "GNU ld"; then
    echo "GNU ld 감지 → -Wl,--as-needed 링커 플래그 추가"
    LD_FLAGS="-Wl,--as-needed"
  fi
  [ -n "$LD_FLAGS" ] && CMAKE_ARGS+=("-DCMAKE_EXE_LINKER_FLAGS=$LD_FLAGS")
  [ -n "$LD_FLAGS" ] && CMAKE_ARGS+=("-DCMAKE_SHARED_LINKER_FLAGS=$LD_FLAGS")
  [ -n "$LD_FLAGS" ] && CMAKE_ARGS+=("-DCMAKE_MODULE_LINKER_FLAGS=$LD_FLAGS")
else
  echo "Warning: conda가 아닌 시스템 링커를 찾지 못했습니다."
fi

# 무권한 폴백 1: HIP 용으로 이미 찾아 둔 LLVM 을 호스트 컴파일러로 재사용한다.
# ROCm 이 깔려 있으면 clang++ 는 반드시 존재하므로, sudo 없이도 빌드가 성립한다.
if [ -z "$HOST_CXX" ] && [ -n "${ROCM_CLANGXX:-}" ] && [ -x "$ROCM_CLANGXX" ]; then
  HOST_CXX="$ROCM_CLANGXX"
  [ -x "${ROCM_CLANGXX%++}" ] && HOST_CC="${ROCM_CLANGXX%++}"
  echo "시스템 컴파일러가 없어 ROCm 의 LLVM 을 호스트 컴파일러로 사용합니다:"
  echo "  CC=$HOST_CC"
  echo "  CXX=$HOST_CXX"
  # cmake 인자 추가는 아래에서 한 곳으로 모아 처리한다(중복 -D 방지).
fi

# 무권한 폴백 2: 빌드 프로그램이 없으면 pip 로 ninja 를 받는다(휠 제공, 권한 불필요).
if [ -z "$GEN_PROG" ]; then
  for pip in "$(command -v pip3 2>/dev/null || true)" "$(command -v pip 2>/dev/null || true)"; do
    [ -n "$pip" ] || continue
    echo "make/ninja 가 없어 pip 로 ninja 설치를 시도합니다 (권한 불필요)"
    "$pip" install -q ninja 2>&1 | tail -2 || true
    GEN_PROG=$(_find_first ninja make || true)
    [ -n "$GEN_PROG" ] && break
  done
fi

# 여기까지 와도 없으면 마지막으로 conda 것이라도 받아들인다(그것 말고 선택지가 없으므로).
[ -n "$HOST_CC" ]  || HOST_CC=$(_find_first cc gcc clang || true)
[ -n "$HOST_CXX" ] || HOST_CXX=$(_find_first c++ g++ clang++ || true)

if [ -z "$GEN_PROG" ] || [ -z "$HOST_CXX" ]; then
  echo "Error: 빌드 툴체인을 갖추지 못했습니다." >&2
  echo "  빌드 프로그램: ${GEN_PROG:-없음}   C++ 컴파일러: ${HOST_CXX:-없음}" >&2
  echo "  해결: sudo apt install build-essential   (또는 배포판에 맞는 개발 도구 묶음)" >&2
  exit 1
fi

# 고른 컴파일러를 cmake 에 확실히 물려준다. PATH 순서에 맡기면 conda 것이 앞에 있을 때
# 조용히 그쪽으로 끌려간다. 단, 사용자가 CC/CXX 를 이미 지정했다면 그 뜻을 존중한다
# (libstdc++ 불일치 때문에 일부러 conda 툴체인을 지정하는 경우가 있고, 그건 아래
#  트러블슈팅에서 이 스크립트가 직접 안내하는 방법이기도 하다).
if [ "${KEEP_CONDA_TOOLCHAIN:-0}" != "1" ] && {
  case "${CC:-}:${CXX:-}" in *conda*) true ;; *) false ;; esac
} && { [ "$USE_CUDA" -eq 1 ] || [ "$USE_ROCM" -eq 1 ]; }; then
  echo "벤더 GPU 빌드에서 conda CC/CXX 자동 주입을 해제하고 시스템 툴체인을 사용합니다."
  unset CC CXX
fi
if [ -z "${CC:-}" ] && [ -z "${CXX:-}" ]; then
  [ -n "$HOST_CC" ] && CMAKE_ARGS+=(-DCMAKE_C_COMPILER="$HOST_CC")
  CMAKE_ARGS+=(-DCMAKE_CXX_COMPILER="$HOST_CXX")
else
  echo "환경변수 CC/CXX 가 지정되어 있어 그대로 씁니다: CC=${CC:-(미지정)} CXX=${CXX:-(미지정)}"
fi

# 벤더 SDK 가 있는데 호스트 컴파일러가 conda 것이면 링크 단계에서 터질 수 있다.
# 20 분짜리 빌드를 날리기 전에 미리 알려준다.
case "$HOST_CXX" in
  *conda*)
    if [ "$USE_ROCM" -eq 1 ] || [ "$USE_CUDA" -eq 1 ]; then
      echo "⚠️  호스트 컴파일러가 conda 것인데 벤더 SDK(ROCm/CUDA) 빌드입니다: $HOST_CXX"
      echo "    링크 단계에서 이렇게 실패할 수 있습니다:"
      echo "      undefined reference to \`sqrtf@GLIBC_2.xx'"
      echo "    권장: sudo apt install build-essential   (설치 후 자동으로 그쪽을 씁니다)"
    fi
    ;;
esac

# make 가 없고 ninja 만 있으면 생성기를 명시해야 한다(cmake 기본값은 Unix Makefiles).
case "$GEN_PROG" in
  */ninja) command -v make >/dev/null 2>&1 || { CMAKE_ARGS+=(-GNinja); echo "make 없음 → Ninja 생성기 사용"; } ;;
esac
echo "빌드 프로그램: $GEN_PROG"
echo "C 컴파일러  : ${HOST_CC:-(cmake 자동 탐색)}"
echo "C++ 컴파일러: $HOST_CXX"

# conda의 cmake/nvcc는 절대 경로로 사용하되, 그 하위 프로세스가 선택하는
# binutils와 시스템 런타임은 배포판 쪽을 사용하게 한다. 이 순서가 없으면
# conda의 ld가 시스템 libc와 섞여 CMake의 첫 링크 테스트부터 실패한다.
export PATH="/usr/bin:/bin:${PATH}"
echo "링커 탐색 PATH 우선순위: /usr/bin:/bin"

echo "최종 cmake 인자:"
printf '  %s\n' "${CMAKE_ARGS[@]}"

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
# 5b. ROCm 6.2 FP8 타입 불일치 자동 패치
# ─────────────────────────────────────────────
# llama.cpp 는 "HIP_VERSION >= 6.2.0 이면 __hip_fp8_e4m3 타입이 있다"고 가정하는데,
# 실제로 ROCm 6.2 헤더에는 fnuz 변형(__hip_fp8_e4m3_fnuz)만 있고 표준 이름의
# __hip_fp8_e4m3 는 6.3 부터 추가됐다. 그래서 ROCm 6.2 로 빌드하면
#   error: unknown type name '__hip_fp8_e4m3'
# 로 깨진다. (gfx906/MI50 처럼 최신 ROCm이 지원을 끊어 6.2를 써야만 하는 경우 직격탄)
#
# 헤더에 실제로 그 타입이 있는지 검사해서, 없을 때만 가드를 6.3 으로 올려 이 블록을
# 통째로 비활성화한다. FP8 경로는 #ifdef FP8_AVAILABLE 로 감싸져 있어 꺼도 안전하며,
# 어차피 gfx906 은 FP8 하드웨어 지원이 없다.
if [ "$USE_ROCM" -eq 1 ] && [ -n "${ROCM_ROOT:-}" ]; then
  HIP_VENDOR_H="$BUILD_DIR/ggml/src/ggml-cuda/vendors/hip.h"
  FP8_HDR="$ROCM_ROOT/include/hip/amd_detail/amd_hip_fp8.h"
  if [ -f "$HIP_VENDOR_H" ] && [ -f "$FP8_HDR" ]; then
    # 'fnuz' 가 안 붙은 진짜 __hip_fp8_e4m3 정의가 있는지 확인
    if ! grep -qE '(struct|class)[[:space:]]+__hip_fp8_e4m3[^_a-zA-Z]' "$FP8_HDR"; then
      section "5b. ROCm FP8 타입 호환 패치"
      echo "$ROCM_ROOT 헤더에 __hip_fp8_e4m3 (비-fnuz) 타입이 없습니다."
      echo "  → vendors/hip.h 의 FP8 가드를 6.2 → 6.3 으로 올려 비활성화합니다."
      sed -i 's/HIP_VERSION >= 60200000/HIP_VERSION >= 60300000/g' "$HIP_VENDOR_H"
      grep -n "HIP_VERSION >= 603" "$HIP_VENDOR_H" | head -2
    fi
  fi
fi

# ─────────────────────────────────────────────
# 6. cmake 빌드
# ─────────────────────────────────────────────
section "6. cmake 빌드"

pushd "$BUILD_DIR" >/dev/null

echo "Configuring..."
# 배열 전개("${CMAKE_ARGS[@]}")로 각 인자가 공백을 포함해도 안전하게 전달됨
"$CMAKE_BIN" -B build "${CMAKE_ARGS[@]}"

echo ""
echo "Building..."
if ! "$CMAKE_BIN" --build build --config Release -j"$JOBS" 2>&1 | tee "$BUILD_DIR/build.log"; then
  echo ""
  echo "ERROR: 빌드 실패" >&2
  echo ""
  echo "📋 일반적인 해결 방법:"
  echo ""
  echo "1. 'undefined reference to \`xxx@GLIBC_2.xx'' 링크 오류:"
  echo "   - 원인: 호스트 툴체인(conda)과 벤더 SDK(ROCm/CUDA)의 glibc 세대 불일치."
  echo "           벤더 .so 는 시스템 glibc 로 빌드됐는데 conda 의 구버전 ld/sysroot 가 링크를 맡은 경우."
  echo "   - 해결: 시스템 툴체인을 설치하고 다시 실행 (스크립트가 자동으로 그쪽을 씁니다)"
  echo "   $ sudo apt install build-essential"
  echo ""
  echo "1b. C++ 표준 라이브러리 링킹 오류 (std::__throw_bad_array_new_length):"
  echo "   - 원인: libstdc++ 버전 불일치"
  echo "   - 해결: conda 환경에서 컴파일러 재설치"
  echo "   $ conda install -y -c conda-forge gxx=13 libstdcxx"
  echo ""
  echo "2. CUDA 컴파일 오류:"
  echo "   - 원인: CUDA 버전 vs GCC 호환성 문제"
  echo "   - 해결: CPU-only 빌드 재시도"
  echo "   $ BUILD_DIR=/tmp/llama_build_cpu bash build_llama_server.sh"
  echo ""
  echo "3. CMake 구성 오류:"
  echo "   - 빌드 디렉터리 초기화 후 재시도"
  echo "   $ rm -rf /tmp/llama_build && bash build_llama_server.sh"
  echo ""
  echo "빌드 로그: $BUILD_DIR/build.log"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi

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

# 설치 전 실행 중인 llama-server 종료.
#   - 실행 중이면 바이너리 파일을 잡고 있어 덮어쓰기가 "Text file busy"(ETXTBSY)로 실패한다.
#   - 종료해 두면 설치가 확실해지고, 다음 기동(run_llama_server.sh) 때 새 바이너리가 반영된다.
#   (run_llama_server.sh 도 기동 시 pkill 하지만, 빌드 단계에서 미리 정리해 설치 실패를 원천 차단)
if pgrep -f "$INSTALL_DIR/llama-server" >/dev/null 2>&1 || pgrep -x llama-server >/dev/null 2>&1; then
  echo "실행 중인 llama-server 종료 (설치 충돌 방지)"
  pkill -9 -f "llama-server" 2>/dev/null || true
fi

mkdir -p "$INSTALL_DIR"

if [ -f "$INSTALL_DIR/llama-server" ]; then
  echo "기존 바이너리 백업: $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  cp -a "$INSTALL_DIR"/. "$BACKUP_DIR/" || true
fi

TARGET_BIN="$INSTALL_DIR/llama-server"
# 주의: 서버가 실행 중이면 바이너리 파일을 잡고 있어 cp 가 덮어쓰기 실패한다
#   ("cp: cannot create regular file ...: Text file busy" / ETXTBSY).
# 해결: 같은 디렉터리에 임시 파일로 복사한 뒤 mv(원자적 rename)로 교체.
# rename 은 실행 파일을 write 모드로 열지 않으므로 ETXTBSY 가 발생하지 않으며,
# 실행 중이던 프로세스는 옛 inode 를 계속 사용하다가 재시작 시 새 바이너리로 전환된다.
cp "$FOUND_BIN" "$TARGET_BIN.new"
chmod +x "$TARGET_BIN.new"
mv -f "$TARGET_BIN.new" "$TARGET_BIN"
echo "설치 완료: $TARGET_BIN"

# [FIX] 구버전 공유 라이브러리 전체 제거 (버전 불일치 방지).
# 예전엔 'libllama*/libggml*' 패턴만 지웠는데, 그러면 예를 들어 libmtmd.so처럼
# 다른 이름의 구버전 라이브러리가 새 버전과 뒤섞여 남을 수 있었다.
# 9번 섹션이 ldd로 필요한 걸 전부 다시 채워 넣으므로, 여기서는 안전하게 전부 지운다.
#
# [FIX] '-type f' 는 심볼릭 링크를 제외한다. 공유 라이브러리는 보통
#   libggml-hip.so.0 -> libggml-hip.so.0.17.0
# 처럼 심볼릭 링크 + 실체 파일 쌍으로 설치되므로, -type f 만 쓰면 링크가 살아남는다.
# 실제로 Vulkan 빌드에서 HIP 빌드로 갈아탔을 때 libggml-vulkan.so.0 링크가 남아
# 백엔드가 뒤섞이는 문제가 있었다. -type f 를 빼서 링크도 함께 지운다.
find "$INSTALL_DIR" -maxdepth 1 \( -type f -o -type l \) \
  \( -name '*.so*' -o -name '*.dylib' \) -delete 2>/dev/null || true

# ─────────────────────────────────────────────
# 9. 공유 라이브러리 복사 (ldd 기반 자동 탐지)
# ─────────────────────────────────────────────
section "9. 공유 라이브러리 복사"

# [FIX] 예전 방식: 'libllama*.so*', 'libggml*.so*' 처럼 사람이 이름을 미리 나열해서
#       find로 복사 → 업스트림이 libmtmd.so 같은 새 라이브러리를 추가하면 못 잡아냄
#       (실제로 이 문제로 "error while loading shared libraries: libmtmd.so.0" 발생).
#
# [FIX] 새 방식: ldd로 "이 실행 파일이 실제로 필요로 하는 라이브러리"를 링커에게
#       직접 물어봐서 그대로 복사. 이름을 몰라도 되고, 업스트림이 뭘 추가하든
#       자동으로 따라간다. 표준 시스템 경로(/lib, /usr/lib 등)에 있는 건 이미
#       시스템에 존재하는 것이므로 복사하지 않는다.
#
# FOUND_BIN(빌드 트리 안의 원본)을 기준으로 조회한다. 빌드 트리 실행 파일은
# cmake가 설정한 RPATH로 build/ 내부 라이브러리를 바로 찾을 수 있어 ldd가
# 정확히 해석된 경로를 보여준다.
echo "ldd로 런타임 의존성 탐지 중: $FOUND_BIN"
ldd "$FOUND_BIN" 2>/dev/null | grep '=>' | awk '{print $3}' | sort -u | while read -r lib; do
  [ -z "$lib" ] && continue
  [ -f "$lib" ] || continue
  case "$lib" in
    /lib/*|/lib64/*|/usr/lib/*|/usr/lib64/*)
      # 시스템 표준 라이브러리(glibc, libstdc++, libcuda 드라이버 등) — 이미 시스템에 있음
      continue
      ;;
  esac
  echo "  -> $(basename "$lib")  (from $lib)"
  # [FIX] 반드시 -L (심볼릭 링크를 따라가 내용을 복사) 이어야 한다.
  #
  # ldd 가 알려주는 경로는 보통 soname 심볼릭 링크다:
  #     /tmp/llama_build/build/bin/libggml-base.so.0 -> libggml-base.so.0.17.0
  # 여기서 'cp -a' 를 쓰면 링크 자체가 복사되어 설치 디렉터리에는
  #     libggml-base.so.0 -> libggml-base.so.0.17.0   (대상 파일 없음!)
  # 처럼 끊어진 링크만 남는다. 실제 파일(*.so.0.17.0)은 아무도 복사하지 않는다.
  #
  # 그런데도 한동안 정상 동작하는 것처럼 보이는데, cmake 가 바이너리에 박아 둔
  # RUNPATH 가 빌드 디렉터리를 가리키고 있어서 거기서 진짜 파일을 찾아 쓰기 때문이다:
  #     Library runpath: [/tmp/llama_build/build/bin:/opt/rocm-6.2.0/lib:]
  # 즉 설치본이 빌드 트리에 몰래 의존한 상태이고, 빌드 디렉터리를 지우거나
  # /tmp 에 두고 재부팅하면 그때서야 'libggml-base.so.0 => not found' 로 터진다.
  # (백업 디렉터리도 같은 방식으로 만들어졌으므로 자동 복구까지 함께 실패한다.)
  #
  # -L 로 soname 이름의 실제 파일을 심어 두면 설치본이 자립한다.
  cp -Lf "$lib" "$INSTALL_DIR/" || true
done

# [FIX] 위와 같은 이유로, 백엔드 라이브러리(libggml-vulkan/hip/cuda 등)는 dlopen 으로
# 열리므로 ldd 에 잡히지 않는다. 빌드 산출물 디렉터리에서 직접 실체를 복사한다.
BIN_SRC_DIR="$(dirname "$FOUND_BIN")"
for lib in "$BIN_SRC_DIR"/libggml-*.so*; do
  [ -e "$lib" ] || continue
  base="$(basename "$lib")"
  # 버전 전체 이름(*.so.0.17.0)은 건너뛰고 soname(*.so.0) 만 실체로 심는다
  case "$base" in
    *.so.[0-9]*.[0-9]*) continue ;;
  esac
  cp -Lf "$lib" "$INSTALL_DIR/" 2>/dev/null || true
done

# RUNPATH 가 빌드 트리를 가리킨 채로 남으면 위 문제가 다시 숨는다.
# patchelf 가 있으면 $ORIGIN(자기 디렉터리) 으로 바꿔 설치본을 완전히 자립시킨다.
if command -v patchelf >/dev/null 2>&1; then
  echo "patchelf 로 RUNPATH 를 \$ORIGIN 으로 재설정합니다 (빌드 트리 의존 제거)"
  for f in "$INSTALL_DIR"/llama-server "$INSTALL_DIR"/*.so*; do
    [ -f "$f" ] || continue
    patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null || true
  done
else
  echo "참고: patchelf 가 없어 RUNPATH 는 그대로 둡니다."
  echo "      run_llama_server.sh 가 LD_LIBRARY_PATH 를 지정하므로 동작에는 문제 없습니다."
fi

# [FIX] rocBLAS 는 .so 만으로 동작하지 않는다 — GPU 아키텍처별 커널 데이터(Tensile)를
# 런타임에 파일로 읽는다. 그리고 그 경로를 librocblas.so 자기 위치 기준으로 찾는다.
# 그래서 librocblas.so 만 설치 디렉터리로 복사하면 데이터를 못 찾고 이렇게 죽는다:
#
#   rocBLAS error: Cannot read <INSTALL_DIR>/rocblas/library/TensileLibrary.dat:
#                  No such file or directory for GPU arch : gfx906
#   rocBLAS error: Could not initialize Tensile host
#
# 모델 로드까지는 멀쩡히 끝나고 첫 추론 요청에서야 터지기 때문에 원인을 찾기 어렵다.
# (프롬프트 처리가 시작조차 안 되는 것처럼 보인다.)
#
# 데이터 전체는 3.5GB(모든 아키텍처)라 복사하면 낭비다. ROCm 은 어차피 시스템에
# 설치되어 있어야 HIP 빌드가 돌아가므로, 원본 디렉터리로 심볼릭 링크만 걸어 준다.
#
# [FIX] 단, 이 링크가 필요한 건 librocblas.so 를 설치 디렉터리로 "복사했을 때"뿐이다.
# 배포판 ROCm(/usr)에서는 librocblas.so 가 /usr/lib/... 에 그대로 남고(9번의 ldd 복사
# 루프가 시스템 경로를 건너뛴다) 자기 옆의 데이터를 알아서 찾는다. 그런 상황에서
# 링크를 걸면 잘못된 경로를 하나 더 만들 뿐이라 조건을 실제 복사 여부로 바꾼다.
if [ "$USE_ROCM" -eq 1 ]; then
  if ls "$INSTALL_DIR"/librocblas.so* >/dev/null 2>&1; then
    if [ -n "${ROCM_ROCBLAS_DIR:-}" ] && [ -d "$ROCM_ROCBLAS_DIR/library" ]; then
      ln -sfn "$ROCM_ROCBLAS_DIR" "$INSTALL_DIR/rocblas"
      echo "rocBLAS 커널 데이터 연결: $INSTALL_DIR/rocblas -> $ROCM_ROCBLAS_DIR"
    else
      # 배포판 레이아웃은 rocblas/<ver>/library 라 한 단계 더 들어가야 한다.
      _tensile=$(find "${ROCM_ROCBLAS_DIR:-/nonexistent}" -type d -name library -print -quit 2>/dev/null || true)
      if [ -n "$_tensile" ]; then
        mkdir -p "$INSTALL_DIR/rocblas"
        ln -sfn "$_tensile" "$INSTALL_DIR/rocblas/library"
        echo "rocBLAS 커널 데이터 연결: $INSTALL_DIR/rocblas/library -> $_tensile"
      else
        echo "⚠️  librocblas 를 설치했지만 Tensile 커널 디렉터리를 찾지 못했습니다."
        echo "    첫 추론에서 'Cannot read TensileLibrary.dat' 로 실패할 수 있습니다."
      fi
    fi
  else
    echo "librocblas 는 시스템 경로에 그대로 있습니다 — 커널 데이터를 스스로 찾으므로 링크 불필요."
  fi
fi

echo ""
echo "설치된 바이너리의 최종 의존성 확인 (LD_LIBRARY_PATH=$INSTALL_DIR 기준):"
LDD_OUT=$(LD_LIBRARY_PATH="$INSTALL_DIR:${LD_LIBRARY_PATH:-}" ldd "$TARGET_BIN" 2>/dev/null || true)
# grep -qi 로 바로 받으면 조기 종료 → ldd 가 SIGPIPE → pipefail 로 "정상"으로 오판될 수 있다.
if [[ "$LDD_OUT" == *"not found"* ]]; then
  echo "⚠️  다음 라이브러리를 찾지 못했습니다 (서버가 기동 실패할 수 있음):"
  grep -i "not found" <<<"$LDD_OUT" || true
else
  echo "  모든 런타임 의존성 정상 확인됨."
fi

# ─────────────────────────────────────────────
# 9b. 디스크 동기화 (크래시 대비)
# ─────────────────────────────────────────────
# cp로 설치한 바이너리/라이브러리는 이 시점에 "디스크에 실제로 써졌다"는 보장이 없다 —
# 커널 페이지 캐시에 dirty 상태로만 존재할 수 있고 아직 writeback되지 않았을 수 있다.
# 이 상태에서 하드 크래시/강제 재부팅(정전, OOM kill, WSL 비정상 종료 등)이 발생하면
# 방금 설치한 파일이 잘리거나 사라져서 "빌드는 성공했는데 다음 실행에서 라이브러리가
# 깨져 있다"는 사고가 난다. 여기서 강제로 flush해 두면 이후 크래시가 나더라도 최소한
# 방금 완성한 빌드 결과물은 안전하게 디스크에 남아있어 매번 재빌드할 필요가 없다.
# (run_llama_server.sh 쪽의 ldd 헬스체크 + 백업 자동복구와 짝을 이루는 방어선.)
section "9b. 디스크 동기화 (크래시 대비)"
sync
echo "sync 완료 — 설치된 바이너리/라이브러리가 디스크에 확실히 기록되었습니다."

# ─────────────────────────────────────────────
# 10. 완료
# ─────────────────────────────────────────────
# 사용한 백엔드 라벨 계산
if   [ "$USE_CUDA"   -eq 1 ]; then BACKEND_LABEL="CUDA ($NVCC_BIN)"
elif [ "$USE_ROCM"   -eq 1 ]; then BACKEND_LABEL="ROCm/HIP"
elif [ "$USE_VULKAN" -eq 1 ]; then BACKEND_LABEL="Vulkan"
elif [ "$USE_METAL"  -eq 1 ]; then BACKEND_LABEL="Metal"
else                                BACKEND_LABEL="CPU-only"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Build & install complete!"
echo "  Binary  : $TARGET_BIN"
echo "  Version : $CLONE_REF"
echo "  Arch    : $ARCH_NAME"
echo "  Backend : $BACKEND_LABEL"
echo ""
echo " 실행: ./run_llama_server.sh"
echo "  (라이브러리 경로는 그 스크립트가 llama-server 프로세스 하나에만"
echo "   한정해서 자동으로 적용합니다 — 전역 export 아님)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit 0