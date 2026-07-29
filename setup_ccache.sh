#!/usr/bin/env bash
# ccache 설정 — llama.cpp 재빌드 가속
#
# 왜 ccache 인가:
#   이 프로젝트는 "백엔드만 바꿔서 여러 번 빌드"하는 패턴이 잦다(ROCm/Vulkan/CPU).
#   그런데 실제로 달라지는 건 ggml-hip / ggml-vulkan 쪽 일부이고, llama.cpp 본체와
#   ggml-cpu 등 대다수 오브젝트는 매번 똑같이 다시 컴파일된다. ccache 는 이걸
#   내용 해시로 캐싱해서 두 번째 빌드부터 대부분을 건너뛴다.
#
# 분산 빌드(distcc/icecream)보다 이걸 먼저 하는 이유:
#   빌드 시간의 큰 몫이 .cu(HIP) 커널과 Vulkan 셰이더인데, 이건 distcc/icecc 가
#   원격으로 넘기지 못하고 로컬로 폴백한다. 반면 ccache 는 이들에도 그대로 먹힌다.
#
# cmake 는 GGML_CCACHE 옵션으로 ccache 를 자동 감지해 쓴다(기본 ON).
# 그래서 설치와 설정만 해두면 build_llama_server.sh 는 수정 없이 혜택을 받는다.

set -euo pipefail

echo "── 1. ccache 설치 확인 ──"
if command -v ccache >/dev/null 2>&1; then
  echo "이미 설치됨: $(ccache --version | head -1)"
else
  echo "설치 중..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y ccache
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y ccache
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm ccache
  elif command -v brew >/dev/null 2>&1; then
    brew install ccache
  else
    echo "Error: 패키지 매니저를 찾지 못했습니다. ccache 를 직접 설치하세요." >&2
    exit 1
  fi
fi

echo ""
echo "── 2. 캐시 크기 설정 ──"
# llama.cpp 한 번 빌드에 오브젝트가 대략 1~2GB. 백엔드 3종 x 버전 몇 개를 감안해
# 20GB 를 준다. 디스크가 빠듯하면 CCACHE_MAX_SIZE 환경변수로 조절.
CACHE_SIZE="${CCACHE_MAX_SIZE:-20G}"

# 디스크 여유를 보고 과하면 줄인다 (캐시가 디스크를 꽉 채우는 사고 방지)
AVAIL_GB=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
WANT_GB=$(echo "$CACHE_SIZE" | tr -dc '0-9')
if [ "$AVAIL_GB" -lt $(( WANT_GB * 2 )) ]; then
  SAFE_GB=$(( AVAIL_GB / 3 ))
  [ "$SAFE_GB" -lt 2 ] && SAFE_GB=2
  echo "여유 공간 ${AVAIL_GB}GB → 캐시를 ${SAFE_GB}GB 로 낮춥니다 (요청: ${CACHE_SIZE})"
  CACHE_SIZE="${SAFE_GB}G"
fi

ccache --max-size="$CACHE_SIZE"
echo "최대 캐시 크기: $CACHE_SIZE"

echo ""
echo "── 3. HIP/CUDA 커널 캐싱을 위한 설정 ──"
# .cu / HIP 컴파일은 컴파일러가 임시 파일 경로를 명령줄에 넣는 등
# 호출마다 미묘하게 달라지는 요소가 있어 기본 설정으로는 캐시 미스가 잦다.
# 아래 sloppiness 로 "결과물에 영향 없는 차이"는 무시하게 한다.
ccache --set-config=sloppiness=locale,time_macros,include_file_ctime,include_file_mtime,random_seed
# 컴파일러 자체가 바뀌면 캐시를 무효화해야 하는데, 심볼릭 링크 경로만 바뀌어도
# 다른 컴파일러로 오인하지 않도록 내용 기준으로 판단한다.
ccache --set-config=compiler_check=content
# 절대 경로가 섞여도 캐시가 재사용되도록 (빌드 디렉터리가 매번 새로 클론됨)
ccache --set-config=hash_dir=false
echo "설정 완료:"
ccache --show-config 2>/dev/null | grep -E "max_size|sloppiness|compiler_check|hash_dir" || true

echo ""
echo "── 4. 현재 통계 ──"
ccache --show-stats 2>/dev/null | head -12

cat <<'EOF'

────────────────────────────────────────────────────────
설정 완료. 다음 빌드부터 자동으로 적용됩니다.
(cmake 가 GGML_CCACHE 로 ccache 를 자동 감지합니다)

효과 확인:
  ccache --show-stats        # 캐시 적중률
  ccache --zero-stats        # 통계 초기화 후 빌드하면 이번 빌드의 적중률만 봄

참고:
  - 첫 빌드는 캐시가 비어 있어 빨라지지 않습니다(오히려 약간 느림).
    두 번째 빌드부터 효과가 납니다.
  - llama.cpp 버전(태그)이 바뀌면 소스가 달라져 상당 부분 다시 컴파일됩니다.
    같은 태그에서 백엔드만 바꿀 때 효과가 가장 큽니다.
────────────────────────────────────────────────────────
EOF
