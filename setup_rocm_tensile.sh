#!/usr/bin/env bash
# 배포판 ROCm 에 빠져 있는 GPU 아키텍처용 rocBLAS Tensile 커널을 채워 넣는다.
#
# ── 왜 필요한가 ─────────────────────────────────────────────────────────────
# Ubuntu 26.04 는 ROCm 7.1.0 을 universe 에 담고 있어 apt 한 줄로 설치된다.
# 그런데 MI50(gfx906) 로 실측해 보면 이렇게 갈린다:
#
#   컴파일러(LLVM 21)  : gfx906 정상 — oclc_isa_version_906.bc 있음
#   HIP 런타임/커널실행 : gfx906 정상 — 실제로 커널이 돌아감
#   rocBLAS Tensile     : gfx906 커널 0개 → 첫 GEMM 에서 SIGABRT
#
#     rocBLAS error: Cannot read .../TensileLibrary.dat for GPU arch : gfx906
#     Aborted (core dumped)
#
# 즉 3층 중 마지막 한 층, 그것도 "데이터 파일"만 비어 있다. 그 파일은 AMD 공식
# 저장소의 옛 rocblas 패키지 안에 그대로 남아 있으므로, 거기서 뽑아 채워 넣으면 된다.
#
# ── 왜 이게 안전한가 ────────────────────────────────────────────────────────
# 옮기는 것은 .so 나 실행 파일이 아니라 GPU 코드 오브젝트(.co/.hsaco)와
# msgpack 데이터(.dat) 뿐이다. glibc/libstdc++ 같은 호스트 ABI 와 무관하므로
# "24.04 용 바이너리를 26.04 에 얹는" 종류의 위험이 없다.
# 기존 파일은 하나도 건드리지 않고 새 파일만 추가하며, --uninstall 로 정확히 되돌린다.
#
# ── 쓰는 법 ────────────────────────────────────────────────────────────────
#   sudo bash setup_rocm_tensile.sh              # 설치 + 검증
#   sudo bash setup_rocm_tensile.sh --uninstall  # 넣은 파일만 정확히 제거
#   sudo bash setup_rocm_tensile.sh --no-verify  # 검증(컴파일/실행) 생략
#
# 24.04 처럼 AMD 공식 저장소(/opt/rocm-*)를 쓸 수 있는 환경이라면 이 스크립트가
# 아니라 setup_rocm.sh 를 쓰는 편이 낫다. 그쪽은 ROCm 을 통째로 일관된 버전으로
# 설치하므로 손댈 곳이 없다. 이 스크립트는 "배포판 ROCm 은 있는데 내 GPU 만
# 빠진" 상황 전용이다.

set -uo pipefail

section() { echo ""; echo "── $* ──"; }
die()     { echo "Error: $*" >&2; exit 1; }

MANIFEST_DIR=/var/lib/rocm-tensile-graft
CACHE=${ROCM_DEB_CACHE:-/var/cache/rocm-tensile-graft}
DO_VERIFY=1
DO_UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --uninstall) DO_UNINSTALL=1 ;;
    --no-verify) DO_VERIFY=0 ;;
    -h|--help)   sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "알 수 없는 인자: $a" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "root 권한이 필요합니다: sudo bash $0 $*"
command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb 가 필요합니다 (Debian/Ubuntu 전용)."

# URL 을 stdout 으로. curl 없는 최소 설치도 있으므로 wget 폴백을 둔다.
fetch() {
  if   command -v curl >/dev/null 2>&1; then curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then wget -qO- "$1"
  else return 1; fi
}
fetch_to() {
  if   command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 15 --max-time 1800 --retry 2 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -q --timeout=15 --tries=3 -O "$2" "$1"
  else return 1; fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. 대상 GPU 아키텍처
# ─────────────────────────────────────────────────────────────────────────────
section "1. GPU 아키텍처 확인"

# rocminfo 는 한 에이전트에 ISA 이름을 여러 개 보고한다. 실제 MI50 출력:
#     amdgcn-amd-amdhsa--gfx906:sramecc+:xnack-
#     amdgcn-amd-amdhsa--gfx9-generic:xnack-
# '-generic' 줄을 먼저 버리고 숫자 2자리 이상을 요구해야 'gfx9' 같은 잘린 값이 안 나온다.
GFX_RE='gfx[0-9]{2,}[a-z]?'
ARCH="${GPU_ARCH:-}"
if [ -z "$ARCH" ] && command -v rocminfo >/dev/null 2>&1; then
  ARCH=$(rocminfo 2>/dev/null | grep -v -- '-generic' | grep -oE "$GFX_RE" | head -n1)
fi
if [ -z "$ARCH" ]; then
  # rocminfo 가 없거나 /dev/kfd 를 못 열면 PCI ID 로 추정한다.
  PCI=$(lspci -nn 2>/dev/null | grep -iE 'VGA|Display|3D' | grep -i 'AMD/ATI' \
        | grep -oE '\[1002:[0-9a-f]{4}\]' | head -1 | tr -d '[]' | cut -d: -f2)
  case "$PCI" in
    66a0|66a1|66a3|66a7|66af) ARCH=gfx906 ;;
    6860|6861|6862|6863|687f) ARCH=gfx900 ;;
    738c|7388|738e|7390)      ARCH=gfx908 ;;
  esac
  [ -n "$ARCH" ] && echo "  rocminfo 불가 → PCI 1002:$PCI 로 $ARCH 추정"
fi
[ -n "$ARCH" ] || die "GPU 아키텍처를 알 수 없습니다. GPU_ARCH=gfx906 처럼 직접 지정하세요."
echo "  대상 아키텍처: $ARCH"

# ─────────────────────────────────────────────────────────────────────────────
# 2. 배포판 rocBLAS 의 Tensile 디렉터리 찾기
# ─────────────────────────────────────────────────────────────────────────────
section "2. 배포판 rocBLAS 위치 확인"

# 배포판 레이아웃은 /usr/lib/<multiarch>/rocblas/<ver>/library 처럼 버전 디렉터리가
# 하나 더 끼어 있어 경로를 고정할 수 없다. dpkg 에게 직접 물어보는 게 가장 정확하다.
BLAS_PKG=$(dpkg-query -W -f='${Package}\n' 'librocblas[0-9]*' 2>/dev/null | grep -vE -- '-(dev|doc|bench|tests|tests-data)$' | head -1)
BLASDIR=""
if [ -n "$BLAS_PKG" ]; then
  BLASDIR=$(dpkg -L "$BLAS_PKG" 2>/dev/null \
            | grep -E '/rocblas/.*/library/TensileLibrary_lazy_.*\.dat$' | head -1)
  [ -n "$BLASDIR" ] && BLASDIR=$(dirname "$BLASDIR")
fi
if [ -z "$BLASDIR" ]; then
  BLASDIR=$(find /usr/lib /opt -maxdepth 6 -type d -path '*rocblas*' -name library 2>/dev/null | head -1)
fi
[ -n "$BLASDIR" ] && [ -d "$BLASDIR" ] || die "rocBLAS Tensile 디렉터리를 찾지 못했습니다.
  배포판 ROCm 을 먼저 설치하세요:
    sudo apt install libamdhip64-dev librocblas-dev libhipblas-dev hipcc rocminfo"

echo "  패키지 : ${BLAS_PKG:-(불명)} $(dpkg-query -W -f='${Version}' "$BLAS_PKG" 2>/dev/null)"
echo "  경로   : $BLASDIR"
echo "  선언된 아키텍처: $(dpkg-query -W -f='${X-ROCm-GPU-Architecture}' "$BLAS_PKG" 2>/dev/null)"

MANIFEST="$MANIFEST_DIR/${ARCH}.list"

# ─────────────────────────────────────────────────────────────────────────────
# 되돌리기 모드
# ─────────────────────────────────────────────────────────────────────────────
if [ "$DO_UNINSTALL" -eq 1 ]; then
  section "되돌리기"
  [ -f "$MANIFEST" ] || die "설치 기록이 없습니다: $MANIFEST"
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -e "$f" ]; then rm -f "$f" && n=$((n+1)); fi
  done < "$MANIFEST"
  rm -f "$MANIFEST"
  echo "  $n 개 파일을 제거했습니다. 배포판 패키지 파일은 건드리지 않았습니다."
  echo "  확인: ls $BLASDIR | grep -c $ARCH   → 0 이면 완전히 되돌아간 것"
  exit 0
fi

# 이미 되어 있으면 아무것도 하지 않는다(재실행 안전).
# 'ls | grep -c' 대신 find 를 쓴다. grep 이 조기 종료해 ls 가 SIGPIPE 로 죽는 경합을
# 만들지 않고, 파일명에 특수문자가 있어도 안전하다.
EXISTING=$(find "$BLASDIR" -maxdepth 1 -name "*${ARCH}*" 2>/dev/null | wc -l)
if [ "$EXISTING" -gt 0 ]; then
  echo ""
  echo "  이미 $ARCH 커널이 $EXISTING 개 있습니다 — 이식할 것이 없습니다."
  [ -f "$MANIFEST" ] && echo "  (이 스크립트가 넣은 것: $(wc -l < "$MANIFEST") 개)"
  if [ "$DO_VERIFY" -eq 0 ]; then exit 0; fi
  echo "  검증만 진행합니다."
  SKIP_INSTALL=1
else
  SKIP_INSTALL=0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. 커널이 남아 있는 가장 최신 AMD ROCm 찾기
# ─────────────────────────────────────────────────────────────────────────────
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

if [ "$SKIP_INSTALL" -eq 0 ]; then
section "3. $ARCH 커널이 들어 있는 AMD ROCm 버전 탐색"

# AMD 는 버전이 올라가면서 옛 아키텍처를 조용히 덜어낸다. 문서가 아니라 패키지
# 내용을 직접 세는 이유가 그것이다. (gfx906 은 6.4.x 에서 이미 0 개, 6.3.3 에 156 개)
CANDIDATES="${ROCM_VERSIONS:-6.4.4 6.4.3 6.4.2 6.4.1 6.3.4 6.3.3 6.3.2 6.3.1 6.3 6.2.4 6.2.2 6.2.1 6.2}"
# repo.radeon.com 에 26.04(resolute) dist 는 없다. 어차피 데이터 파일만 꺼내 쓰므로
# 어느 dist 의 패키지든 내용은 같다 — 존재하는 것을 아무거나 쓴다.
DISTS="${ROCM_DISTS:-noble jammy}"
mkdir -p "$CACHE"
echo "  deb 캐시: $CACHE  (ROCM_VERSIONS 로 탐색 범위를 좁힐 수 있습니다)"

PICKED=""; PICKED_DEB=""
for v in $CANDIDATES; do
  for d in $DISTS; do
    PKGS=$(fetch "https://repo.radeon.com/rocm/apt/$v/dists/$d/main/binary-amd64/Packages.gz" 2>/dev/null | gunzip -c 2>/dev/null)
    [ -n "$PKGS" ] || continue

    FN=$(echo "$PKGS" | awk '/^Package: rocblas$/{f=1} f&&/^Filename: /{print $2; exit}')
    WANT=$(echo "$PKGS" | awk -v fn="$FN" '$0=="Filename: "fn{f=1} f&&/^Size: /{print $2; exit}')
    [ -n "$FN" ] || { echo "  ROCm $v ($d): rocblas 패키지 없음"; break; }

    # 받아 둔 deb 는 캐시에 남긴다. apt 업그레이드로 파일이 날아가 재실행할 때
    # 140MB 를 다시 받지 않아도 되고, 탐색 도중 훑고 지나간 버전도 재사용된다.
    DEB="$CACHE/rocblas-${v}.deb"
    printf '  ROCm %-6s (%s) rocblas %d MB … ' "$v" "$d" "$(( ${WANT:-0} / 1024 / 1024 ))"
    if [ -f "$DEB" ] && [ -n "$WANT" ] && [ "$(stat -c%s "$DEB" 2>/dev/null || echo 0)" = "$WANT" ]; then
      printf '캐시 사용, '
    else
      if ! fetch_to "https://repo.radeon.com/rocm/apt/$v/$FN" "$DEB"; then
        echo "다운로드 실패 → 건너뜀"; rm -f "$DEB"; break
      fi
      # 잘린 파일을 그대로 검사하면 dpkg-deb 가 실패하고 그게 "커널 없음"으로 오인되어
      # 멀쩡한 버전을 건너뛴다. 크기를 먼저 대조한다.
      GOT=$(stat -c%s "$DEB" 2>/dev/null || echo 0)
      if [ -n "$WANT" ] && [ "$GOT" != "$WANT" ]; then
        echo "크기 불일치(${GOT}/${WANT}) → 건너뜀"; rm -f "$DEB"; break
      fi
    fi
    if ! LIST=$(dpkg-deb -c "$DEB" 2>/dev/null); then
      echo "패키지를 읽을 수 없음 → 건너뜀"; rm -f "$DEB"; break
    fi
    N=$(printf '%s' "$LIST" | grep -c "$ARCH")
    if [ "$N" -gt 0 ]; then
      echo "$ARCH 커널 ${N}개 → 채택"
      PICKED="$v"; PICKED_DEB="$DEB"
    else
      echo "$ARCH 커널 없음"
      rm -f "$DEB"   # 쓸모없는 버전은 캐시에 남기지 않는다
    fi
    break   # 이 버전은 처리했으므로 다른 dist 는 볼 필요 없다
  done
  [ -n "$PICKED" ] && break
done

[ -n "$PICKED" ] || die "$ARCH 커널이 들어 있는 ROCm 을 찾지 못했습니다.
  이 GPU 는 Vulkan 백엔드를 쓰세요: GGML_BACKEND=vulkan bash build_llama_server.sh"

# ─────────────────────────────────────────────────────────────────────────────
# 4. 아키텍처 파일만 추출해 설치
# ─────────────────────────────────────────────────────────────────────────────
section "4. $ARCH 파일 추출 및 설치 (ROCm $PICKED → $BLASDIR)"

# deb 전체를 펼치면 2GB 가까이 되므로, tar 스트림에서 해당 아키텍처만 골라 뽑는다.
mkdir -p "$WORK/x"
dpkg-deb --fsys-tarfile "$PICKED_DEB" \
  | tar -x -C "$WORK/x" --wildcards "./opt/rocm*/lib/rocblas/library/*${ARCH}*" 2>/dev/null
SRC=$(find "$WORK/x" -type d -name library | head -1)
[ -n "$SRC" ] || die "추출에 실패했습니다."

mkdir -p "$MANIFEST_DIR"
: > "$MANIFEST.tmp"
copied=0; skipped=0
for f in "$SRC"/*; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  if [ -e "$BLASDIR/$base" ]; then
    # 배포판 파일을 덮어쓰는 일은 절대 하지 않는다. 되돌릴 수 없게 되기 때문이다.
    skipped=$((skipped+1)); continue
  fi
  install -m 0644 "$f" "$BLASDIR/$base" && { echo "$BLASDIR/$base" >> "$MANIFEST.tmp"; copied=$((copied+1)); }
done
mv -f "$MANIFEST.tmp" "$MANIFEST"
sync

echo "  복사: ${copied}개   건너뜀(이미 존재): ${skipped}개"
echo "  설치 기록: $MANIFEST  (되돌리기: sudo bash $0 --uninstall)"
[ "$copied" -gt 0 ] || die "복사된 파일이 없습니다."

# lazy 로딩 인덱스가 있어야 rocBLAS 가 이 아키텍처를 찾는다.
if [ -f "$BLASDIR/TensileLibrary_lazy_${ARCH}.dat" ]; then
  echo "  핵심 인덱스 확인: TensileLibrary_lazy_${ARCH}.dat 있음"
else
  echo "  ⚠️  TensileLibrary_lazy_${ARCH}.dat 이 없습니다 — 동작하지 않을 수 있습니다."
fi
fi   # SKIP_INSTALL

# ─────────────────────────────────────────────────────────────────────────────
# 5. 진짜로 되는지 검증 — rocBLAS sgemm 을 GPU 에서 실행
# ─────────────────────────────────────────────────────────────────────────────
if [ "$DO_VERIFY" -eq 1 ]; then
section "5. 검증 (rocBLAS sgemm 실행)"

if ! command -v hipcc >/dev/null 2>&1; then
  echo "  hipcc 가 없어 검증을 건너뜁니다 (sudo apt install hipcc)."
else
  cat > "$WORK/blas.cpp" <<'CPP'
#include <hip/hip_runtime.h>
#include <rocblas/rocblas.h>
#include <cstdio>
#include <vector>
int main(){
  const int n=256;
  std::vector<float> A(n*n,1.0f),B(n*n,2.0f),C(n*n,0.0f);
  float *dA,*dB,*dC;
  if(hipMalloc(&dA,n*n*4)||hipMalloc(&dB,n*n*4)||hipMalloc(&dC,n*n*4)){printf("FAIL: hipMalloc\n");return 1;}
  if(hipMemcpy(dA,A.data(),n*n*4,hipMemcpyHostToDevice)||
     hipMemcpy(dB,B.data(),n*n*4,hipMemcpyHostToDevice)){printf("FAIL: memcpy\n");return 1;}
  rocblas_handle h;
  if(rocblas_create_handle(&h)!=rocblas_status_success){printf("FAIL: create_handle\n");return 1;}
  float al=1.0f,be=0.0f;
  rocblas_status st=rocblas_sgemm(h,rocblas_operation_none,rocblas_operation_none,
                                  n,n,n,&al,dA,n,dB,n,&be,dC,n);
  if(st!=rocblas_status_success){printf("FAIL: sgemm status=%d (%s)\n",(int)st,rocblas_status_to_string(st));return 1;}
  if(hipDeviceSynchronize()!=hipSuccess){printf("FAIL: sync\n");return 1;}
  if(hipMemcpy(C.data(),dC,n*n*4,hipMemcpyDeviceToHost)){printf("FAIL: memcpy back\n");return 1;}
  printf("C[0]=%.1f (기대 %.1f)\n",C[0],2.0f*n);
  if(C[0]==2.0f*n){printf("SGEMM_OK\n");return 0;}
  printf("FAIL: 계산 결과 불일치\n"); return 1;
}
CPP
  if hipcc --offload-arch="$ARCH" "$WORK/blas.cpp" -o "$WORK/blas" -lrocblas 2>"$WORK/cc.log"; then
    echo "  컴파일 성공, 실행:"
    OUT=$("$WORK/blas" 2>&1); RC=$?
    echo "$OUT" | sed 's/^/    /'
    if [ "$RC" -eq 0 ]; then
      VERDICT=OK
    else
      VERDICT=FAIL
    fi
  else
    echo "  컴파일 실패:"; tail -10 "$WORK/cc.log" | sed 's/^/    /'
    VERDICT=FAIL
  fi
fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. 결과
# ─────────────────────────────────────────────────────────────────────────────
section "결과"
if [ "${VERDICT:-SKIP}" = "OK" ]; then
  cat <<EOF
  ✅ $ARCH 에서 rocBLAS 가 정상 동작합니다.

  다음 단계:
    bash build_llama_server.sh        # ROCm(HIP) 이 자동으로 선택됩니다
    bash mi50_high.sh                 # GPU 클럭 고정 (부팅할 때마다 필요)

  주의: apt 로 librocblas 를 업그레이드하면 이 디렉터리가 갱신되면서 넣은 파일이
        사라질 수 있습니다. 그때는 이 스크립트를 다시 실행하면 됩니다.
        (기존 파일을 덮어쓴 적이 없으므로 재실행은 항상 안전합니다)
EOF
elif [ "${VERDICT:-SKIP}" = "FAIL" ]; then
  cat <<EOF
  ❌ 파일은 들어갔지만 rocBLAS 가 동작하지 않습니다.
     ROCm ${PICKED:-?} 의 Tensile 포맷을 현재 rocBLAS 가 읽지 못하는 경우일 수 있습니다.

  되돌리기:
    sudo bash $0 --uninstall

  대안: Vulkan 백엔드 (검증된 경로)
    GGML_BACKEND=vulkan bash build_llama_server.sh
EOF
  exit 1
else
  echo "  검증을 건너뛰었습니다. 직접 확인하려면 --no-verify 없이 다시 실행하세요."
fi
