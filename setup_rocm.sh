#!/usr/bin/env bash
# ROCm 설치 스크립트 — 우분투 재설치 등 맨바닥 상태에서 HIP 백엔드를 쓸 수 있게 만든다.
#
# build_llama_server.sh 는 "이미 설치된 ROCm 을 찾아 쓰는" 일만 한다(설치는 하지 않는다).
# Vulkan 은 의존성이 가벼워 자동 설치하지만, ROCm 은 수 GB 짜리 벤더 SDK 라
# 사용자 동의 없이 깔면 곤란하기 때문이다. 그래서 이 스크립트를 따로 둔다.
#
# ── 이 스크립트가 존재하는 진짜 이유 ─────────────────────────────────────────
# "최신 ROCm 을 깔면 된다"가 성립하지 않는 GPU 가 있다. 예를 들어 gfx906(MI50,
# Radeon VII)은 AMD 최신 ROCm(7.x)에서 지원이 끊겼는데, 문서상 표기만 그런 게
# 아니라 rocBLAS 커널 바이너리 자체가 패키지에서 빠져 있다:
#
#     ROCm 7.14 : rocBLAS 커널 2153개 / 25개 아키텍처, gfx906 = 0개
#     ROCm 6.2.0: gfx906 = 156개
#
# 즉 최신을 깔면 빌드는 되지만 첫 추론에서 아래처럼 죽는다:
#     rocBLAS error: Cannot read .../TensileLibrary.dat for GPU arch : gfx906
#
# 그래서 이 스크립트는 "내 GPU 아키텍처용 커널이 실제로 들어있는 가장 새로운
# ROCm 버전"을 골라 설치한다.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

if [ "$(uname -s)" != "Linux" ]; then
  echo "Error: ROCm 은 Linux 전용입니다." >&2; exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
  echo "Error: 이 스크립트는 Debian/Ubuntu(apt) 기준입니다." >&2
  echo "  다른 배포판은 https://rocm.docs.amd.com 의 설치 안내를 따르세요." >&2
  exit 1
fi

UBUNTU_CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
echo "배포판: ${UBUNTU_CODENAME}"

# ── 1. GPU 아키텍처 알아내기 ────────────────────────────────────────────────
# ROCm 이 아직 없으면 rocminfo 도 없다. 그래서 PCI ID 로 먼저 추정한다.
section() { echo ""; echo "── $* ──"; }

section "1. AMD GPU 확인"
if ! lspci -nn 2>/dev/null | grep -qiE "VGA|Display|3D" ; then
  echo "Error: PCI 장치를 읽을 수 없습니다." >&2; exit 1
fi
lspci -nn | grep -iE "VGA|Display|3D" | grep -i "AMD/ATI" || {
  echo "Error: AMD GPU 를 찾지 못했습니다. ROCm 은 AMD 전용입니다." >&2; exit 1
}

GPU_ARCH=""
# 이미 ROCm 이 있으면 rocminfo 가 가장 정확하다.
for ri in /opt/rocm*/bin/rocminfo "$(command -v rocminfo 2>/dev/null || true)"; do
  [ -n "$ri" ] && [ -x "$ri" ] || continue
  GPU_ARCH=$("$ri" 2>/dev/null | grep -oE 'gfx[0-9a-f]+' | head -n1 || true)
  if [ -z "$GPU_ARCH" ] && id -nG "$USER" 2>/dev/null | grep -qw render; then
    GPU_ARCH=$(sg render -c "$ri" 2>/dev/null | grep -oE 'gfx[0-9a-f]+' | head -n1 || true)
  fi
  [ -n "$GPU_ARCH" ] && break
done

if [ -z "$GPU_ARCH" ]; then
  # PCI device ID → gfx 매핑 (자주 쓰이는 것들만. 없으면 사용자에게 묻는다)
  PCI_ID=$(lspci -nn | grep -iE "VGA|Display|3D" | grep -i "AMD/ATI" \
           | grep -oE '\[1002:[0-9a-f]{4}\]' | head -1 | tr -d '[]' | cut -d: -f2)
  case "$PCI_ID" in
    66a0|66a1|66a3|66a7|66af) GPU_ARCH="gfx906" ;;   # Vega 20 / MI50, MI60, Radeon VII
    6860|6861|6862|6863|687f) GPU_ARCH="gfx900" ;;   # Vega 10 / MI25
    738c|7388|738e|7390)      GPU_ARCH="gfx908" ;;   # MI100
    7408|740c|740f)           GPU_ARCH="gfx90a" ;;   # MI200
    73bf|73df|73ff)           GPU_ARCH="gfx1030" ;;  # RDNA2 (6800/6900/6700)
    744c|7448)                GPU_ARCH="gfx1100" ;;  # RDNA3 (7900)
  esac
  [ -n "$GPU_ARCH" ] && echo "PCI ID 1002:${PCI_ID} → ${GPU_ARCH} 로 추정"
fi

if [ -z "$GPU_ARCH" ]; then
  echo "GPU 아키텍처를 자동으로 알아내지 못했습니다."
  read -r -p "gfx 이름을 직접 입력하세요 (예: gfx906, 모르면 빈칸): " GPU_ARCH || true
fi
echo "대상 아키텍처: ${GPU_ARCH:-(미지정 — 커널 존재 확인을 건너뜁니다)}"

# ── 2. 내 아키텍처를 지원하는 가장 새로운 ROCm 버전 찾기 ────────────────────
section "2. 지원 버전 탐색"
# repo.radeon.com 에 있는 버전들을 새 것부터 훑으며, rocblas 패키지 안에
# 내 gfx 커널이 실제로 들어있는지 .deb 를 받아 확인한다.
CANDIDATES="${ROCM_VERSIONS:-6.4.1 6.4 6.3.3 6.3.2 6.3.1 6.3 6.2.4 6.2.2 6.2.1 6.2}"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
PICKED=""

for v in $CANDIDATES; do
  BASE="https://repo.radeon.com/rocm/apt/$v"
  PKGS_URL="$BASE/dists/${UBUNTU_CODENAME}/main/binary-amd64/Packages"
  echo -n "  ROCm $v … "
  PKGLIST=$(curl -fsSL "$PKGS_URL" 2>/dev/null || true)
  if [ -z "$PKGLIST" ]; then echo "저장소 없음"; continue; fi
  if [ -z "$GPU_ARCH" ]; then echo "사용 가능 (아키텍처 확인 생략)"; PICKED="$v"; break; fi

  FN=$(echo "$PKGLIST" | awk '/^Package: rocblas$/{f=1} f&&/^Filename: /{print $2; exit}')
  if [ -z "$FN" ]; then echo "rocblas 없음"; continue; fi
  echo -n "rocblas 확인 중… "
  if ! curl -fsSL -o "$WORK/r.deb" "$BASE/$FN" 2>/dev/null; then echo "다운로드 실패"; continue; fi
  # 커널 파일 목록만 확인 (전체 전개는 느리므로 파일명만 훑는다)
  if dpkg-deb -c "$WORK/r.deb" 2>/dev/null | grep -q "$GPU_ARCH"; then
    N=$(dpkg-deb -c "$WORK/r.deb" 2>/dev/null | grep -c "$GPU_ARCH")
    echo "${GPU_ARCH} 커널 ${N}개 → 채택"
    PICKED="$v"; break
  else
    echo "${GPU_ARCH} 커널 없음 → 건너뜀"
  fi
  rm -f "$WORK/r.deb"
done

if [ -z "$PICKED" ]; then
  echo ""
  echo "Error: ${GPU_ARCH} 를 지원하는 ROCm 을 찾지 못했습니다." >&2
  echo "  이 GPU 는 Vulkan 백엔드를 쓰세요: GGML_BACKEND=vulkan bash build_llama_server.sh" >&2
  exit 1
fi
echo ""
echo "설치할 버전: ROCm $PICKED"

# ── 3. 저장소 등록 ──────────────────────────────────────────────────────────
section "3. apt 저장소 등록"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key \
  | sudo gpg --dearmor -o "/etc/apt/keyrings/rocm-${PICKED}.gpg"
echo "deb [signed-by=/etc/apt/keyrings/rocm-${PICKED}.gpg] https://repo.radeon.com/rocm/apt/${PICKED} ${UBUNTU_CODENAME} main" \
  | sudo tee "/etc/apt/sources.list.d/rocm-${PICKED}.list" >/dev/null
sudo apt-get update

# ── 4. 설치 ────────────────────────────────────────────────────────────────
section "4. 패키지 설치"
# llama.cpp HIP 백엔드에 실제로 필요한 최소 집합.
# (전체 ROCm 메타패키지는 수십 GB 라 불필요하다)
PKGS="rocblas rocblas-dev hipblas hipblas-dev hip-runtime-amd hip-dev rocm-device-libs rocm-llvm"
echo "설치: $PKGS"
sudo apt-get install -y $PKGS

# hipcc 는 배포판 버전(구버전)이 먼저 잡히는 경우가 있어 저장소 버전을 명시한다.
HIPCC_VER=$(apt-cache policy hipcc 2>/dev/null | awk '/repo.radeon.com/{found=1} found&&/^ +[0-9]/{print $1; exit}')
if [ -n "$HIPCC_VER" ]; then
  echo "hipcc=$HIPCC_VER 설치"
  sudo apt-get install -y --allow-downgrades "hipcc=$HIPCC_VER"
else
  sudo apt-get install -y hipcc
fi

# rocm-llvm 이 auto 로 잡히면 autoremove 때 사라질 수 있다(HIP 컴파일러가 여기 있다).
sudo apt-mark manual rocm-llvm rocm-device-libs >/dev/null 2>&1 || true

# ── 5. 권한 ────────────────────────────────────────────────────────────────
section "5. GPU 접근 권한"
# /dev/kfd 는 ACL 이 없어 render 그룹 소속이 반드시 필요하다.
# (/dev/dri/renderD* 는 ACL 덕분에 Vulkan 은 재로그인 없이도 되지만 ROCm 은 안 된다)
if ! id -nG "$USER" | grep -qw render; then
  sudo usermod -aG render,video "$USER"
  echo "render,video 그룹에 추가했습니다 → 로그아웃 후 재로그인 필요"
  NEED_RELOGIN=1
else
  echo "이미 render 그룹 소속"
  id -nG | grep -qw render || { echo "  단, 현재 셸에는 미반영 → 재로그인 필요"; NEED_RELOGIN=1; }
fi

# ── 6. 확인 ────────────────────────────────────────────────────────────────
section "6. 설치 확인"
ROOT=$(ls -d /opt/rocm-* 2>/dev/null | sort -Vr | head -1)
echo "ROCm 루트: ${ROOT:-없음}"
[ -n "$GPU_ARCH" ] && [ -n "$ROOT" ] && \
  echo "${GPU_ARCH} rocBLAS 커널: $(ls "$ROOT"/lib/rocblas/library/*"$GPU_ARCH"* 2>/dev/null | wc -l)개"

cat <<EOF

────────────────────────────────────────────────────────
ROCm $PICKED 설치 완료.

${NEED_RELOGIN:+⚠️  로그아웃 후 다시 로그인하세요 (/dev/kfd 접근에 render 그룹 반영 필요).
    재로그인 후 확인: rocminfo | grep gfx

}다음 단계:
  bash build_llama_server.sh      # 백엔드 선택에서 ROCm 을 고르세요

참고: GPU 클럭이 기본 auto 면 추론 성능이 절반 이하로 떨어집니다.
      bash mi50_high.sh           # 부팅할 때마다 필요
────────────────────────────────────────────────────────
EOF
