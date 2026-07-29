#!/usr/bin/env bash
# AMD GPU 클럭을 최대 성능으로 고정한다. (재부팅하면 초기화되므로 부팅 후 매번 필요)
#
# 왜 필요한가:
#   이 카드(MI50/gfx906)는 헤드리스 컴퓨트 카드라 드라이버의 'auto' DPM 정책이
#   LLM 추론 부하를 "클럭을 올릴 만한 부하"로 인식하지 못한다. 특히 메모리 클럭이
#   최대치의 35%(350MHz)에 묶이는데, MoE 모델은 토큰마다 서로 다른 전문가 가중치를
#   VRAM 에서 새로 읽으므로 여기서 직격탄을 맞는다.
#
#   실측 (35B-A3B Q4_K_M):
#       auto : sclk  938MHz / mclk  350MHz →  pp  41.8 t/s,  tg  6.28 t/s
#       high : sclk 1800MHz / mclk 1000MHz →  pp 346.7 t/s,  tg 15.9  t/s
#   즉 토큰 생성 2.5배, 프롬프트 처리 8.3배 차이다.
#
#   참고: 이 현상은 VBIOS 와 무관하다. 디스플레이 출력이 가능한 V420 VBIOS
#   (113-D1640200-043) 를 쓰는 카드에서도 동일하게 발생한다. VBIOS 는 전력 상한과
#   DPM 레벨 테이블의 상한선만 정하고, 클럭을 올릴지 말지는 드라이버 정책이 정한다.
#
# 사용법: mi50_high.sh [high|auto|low|manual]   (기본 high)

set -euo pipefail

# [FIX] card 번호를 하드코딩하지 않는다.
# /sys/class/drm/cardN 의 N 은 부팅 시 장치 열거 순서에 따라 달라질 수 있고,
# 이 기기에는 Intel iGPU 와 AMD 가 함께 있어 뒤바뀌면 엉뚱한 장치에 쓰게 된다.
# PCI 벤더 ID(0x1002 = AMD)로 찾는다.
TARGETS=()
for v in /sys/class/drm/card*/device/vendor; do
  [ -f "$v" ] || continue
  [ "$(cat "$v" 2>/dev/null)" = "0x1002" ] || continue
  d="$(dirname "$v")"
  # 전력 정책 파일이 있는 장치만 (해당 인터페이스가 없는 장치 제외)
  [ -f "$d/power_dpm_force_performance_level" ] || continue
  TARGETS+=("$d")
done

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "Error: AMD GPU(vendor 0x1002)를 찾지 못했습니다." >&2
  echo "  확인: ls /sys/class/drm/card*/device/vendor" >&2
  exit 1
fi

LEVEL="${1:-high}"
case "$LEVEL" in
  high|auto|low|manual) ;;
  *) echo "Error: 알 수 없는 레벨 '$LEVEL' (high|auto|low|manual)" >&2; exit 1 ;;
esac

for d in "${TARGETS[@]}"; do
  card="$(basename "$(dirname "$d")")"
  echo "$LEVEL" | sudo tee "$d/power_dpm_force_performance_level" >/dev/null
  cur="$(cat "$d/power_dpm_force_performance_level" 2>/dev/null || echo '?')"
  sclk="$(grep '\*' "$d/pp_dpm_sclk" 2>/dev/null | sed 's/.*: *//' | tr -d ' *' || true)"
  mclk="$(grep '\*' "$d/pp_dpm_mclk" 2>/dev/null | sed 's/.*: *//' | tr -d ' *' || true)"
  echo "$card: 정책=$cur  sclk=${sclk:-?}  mclk=${mclk:-?}"
done
