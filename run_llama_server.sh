#!/bin/bash
# 범용 GPU 가속 실행 스크립트 (대화형 선택 + 컨텍스트 계산 포함)
# CUDA(NVIDIA) / ROCm(AMD) / Vulkan(NVIDIA·AMD·Intel 공통) / Metal / CPU-only
# 어떤 백엔드로 빌드됐든 동일하게 동작한다 — 벤더 도구(nvidia-smi 등)에 의존하지 않고
# 방금 빌드된 llama-server 바이너리 자신의 --list-devices 로 디바이스/VRAM을 감지한다.
#
# [FIX] 준비/실패 판단은 after 방식(/health 폴링, 로그 문구에 안 흔들림)을 유지하면서,
#       화면에는 before 방식처럼 로그를 실시간으로 스트리밍한다(tail -f).
#       즉 "판단 기준"과 "화면 출력"을 분리 — 판단은 /health, 출력은 tail -f.

# 스크립트 위치로 이동
cd "$(dirname "$0")"

# ─── 포트 인자 파싱 ───────────────────────────────────────────────────────────
# 사용법: ./run_llama_server.sh [--port PORT]
# 기본값: 8080  (외부 접근은 setup_secure_server.sh 의 Caddy HTTPS 를 사용)
SERVER_PORT=8080
WANT_BACKEND=""
_argv=("$@")
_i=0
while [[ $_i -lt ${#_argv[@]} ]]; do
  case "${_argv[$_i]}" in
    --port)
      _i=$(( _i + 1 ))
      SERVER_PORT="${_argv[$_i]}"
      ;;
    --port=*)
      SERVER_PORT="${_argv[$_i]#*=}"
      ;;
    --backend)
      _i=$(( _i + 1 ))
      WANT_BACKEND="${_argv[$_i]}"
      ;;
    --backend=*)
      WANT_BACKEND="${_argv[$_i]#*=}"
      ;;
  esac
  _i=$(( _i + 1 ))
done
echo "llama-server 포트: ${SERVER_PORT}  (변경: ./run_llama_server.sh --port 1234)"

# ─── 설치된 백엔드 탐지 및 선택 ───────────────────────────────────────────────
# build_llama_server.sh 가 백엔드별로 llama_server_rocm / llama_server_vulkan /
# llama_server_x86_64 … 처럼 따로 설치하므로, 여기서 어떤 걸 쓸지 고른다.
# 예전 방식(llama_server 단일 디렉터리)도 그대로 인식해서 호환을 유지한다.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

BACKEND_DIRS=(); BACKEND_NAMES=()
for d in "$SCRIPT_DIR"/llama_server_*; do
  # *_backup_* 은 백업본이므로 후보에서 제외
  case "$d" in *_backup_*) continue ;; esac
  [ -x "$d/llama-server" ] || continue
  BACKEND_DIRS+=("$d")
  BACKEND_NAMES+=("${d##*/llama_server_}")
done
# 구버전 호환: 이름 없는 llama_server/ 도 후보에 넣는다
if [ -x "$SCRIPT_DIR/llama_server/llama-server" ]; then
  BACKEND_DIRS+=("$SCRIPT_DIR/llama_server")
  BACKEND_NAMES+=("(구버전 llama_server)")
fi

if [ ${#BACKEND_DIRS[@]} -eq 0 ]; then
  echo "Error: 설치된 llama-server 를 찾지 못했습니다." >&2
  echo "  먼저 빌드하세요: bash build_llama_server.sh" >&2
  exit 1
fi

SELECTED_DIR=""
if [ -n "$WANT_BACKEND" ]; then
  # --backend rocm 처럼 명시된 경우
  for i in "${!BACKEND_NAMES[@]}"; do
    [ "${BACKEND_NAMES[$i]}" = "$WANT_BACKEND" ] && SELECTED_DIR="${BACKEND_DIRS[$i]}" && break
  done
  if [ -z "$SELECTED_DIR" ]; then
    echo "Error: --backend $WANT_BACKEND 에 해당하는 설치본이 없습니다." >&2
    echo "  사용 가능: ${BACKEND_NAMES[*]}" >&2
    exit 1
  fi
elif [ ${#BACKEND_DIRS[@]} -eq 1 ]; then
  SELECTED_DIR="${BACKEND_DIRS[0]}"
  echo "백엔드: ${BACKEND_NAMES[0]}  (설치된 것이 하나뿐이라 자동 선택)"
else
  echo "설치된 백엔드 ${#BACKEND_DIRS[@]}개:"
  for i in "${!BACKEND_NAMES[@]}"; do
    printf "  [%d] %s\n" "$i" "${BACKEND_NAMES[$i]}"
  done
  # read 는 EOF(비대화형)에서 즉시 실패하고 _sel 이 비므로 멈추지 않는다.
  # 굳이 [ -t 0 ] 로 막으면 파이프로 넘긴 선택값까지 무시되어 이 스크립트의
  # 다른 프롬프트(모델 선택 등)와 동작이 어긋난다.
  _sel=""
  read -r -p "사용할 백엔드 번호 [기본값 0: ${BACKEND_NAMES[0]}]: " _sel || true
  if [[ "$_sel" =~ ^[0-9]+$ ]] && [ "$_sel" -lt "${#BACKEND_DIRS[@]}" ]; then
    SELECTED_DIR="${BACKEND_DIRS[$_sel]}"
  else
    SELECTED_DIR="${BACKEND_DIRS[0]}"
  fi
  echo "선택됨: $(basename "$SELECTED_DIR")"
fi

# 라이브러리 경로 설정
# build_llama_server.sh 의 9번 섹션이 ldd로 필요한 공유 라이브러리를 전부
# ./llama_server 안에 자동 복사해두므로, 특정 conda 환경 경로를 하드코딩할 필요가 없다.
#
# [FIX] export로 전역 선언하지 않는다 — 그러면 이 스크립트가 이후에 실행하는
# find/sort/select 같은 무관한 시스템 명령까지 이 경로를 상속받는다. ./llama_server/
# 안의 라이브러리 하나가 깨지면(빌드 중 크래시 등으로 파일이 잘리는 경우) llama-server와
# 전혀 상관없는 명령들까지 "file too short" 에러로 줄줄이 죽어버릴 수 있다. 그래서
# 변수로만 갖고 있다가, 실제로 llama-server를 실행하는 시점에만 그 프로세스에
# 한정해서 적용한다(아래 --list-devices 조회, 서버 기동 시 각각 LD_LIBRARY_PATH=... 접두 참고).
LLAMA_LD_LIBRARY_PATH="$SELECTED_DIR"

# 기존 프로세스 종료
pkill -9 -f llama-server || true
sleep 1

SERVER_BIN="$SELECTED_DIR/llama-server"

# ─── 라이브러리 사전 점검 + 손상 시 백업에서 자동복구 ─────────────────────────
# 모델 선택 프롬프트까지 다 진행한 뒤에야 라이브러리 깨진 걸 발견하는 걸 방지하기
# 위해 시작하자마자 확인한다. build_llama_server.sh는 설치할 때마다 기존
# llama_server/를 "llama_server_backup_<epoch>/"로 백업해 두므로, 디스크 캐시 유실·
# 강제 재부팅·안티바이러스 격리 등으로 바이너리/라이브러리가 손상됐을 때 무조건
# "다시 빌드하세요"(5~10분 이상)로 끝내지 않고, 가장 최근 백업으로부터 복구를 먼저 시도한다.
_find_latest_llama_server_backup() {
  # [FIX] 백업도 백엔드별로 나뉜다(llama_server_rocm_backup_<epoch> 등).
  # 다른 백엔드의 백업으로 복구하면 백엔드가 뒤바뀌므로, 반드시 지금 선택한
  # 설치 디렉터리에 대응하는 백업만 후보로 삼는다.
  ls -d "${SELECTED_DIR}"_backup_*/ 2>/dev/null \
    | sed 's#/$##' \
    | awk -F'_' '{print $NF, $0}' \
    | sort -n \
    | tail -n1 \
    | cut -d' ' -f2-
}

_check_llama_server_ok() {
  # 0=정상, 1=문제 있음(바이너리 없음 또는 ldd 에러). 문제 내용은 LAST_LDD_ISSUE에 담는다.
  if [ ! -x "$SERVER_BIN" ]; then
    LAST_LDD_ISSUE="$SERVER_BIN 바이너리가 없습니다."
    return 1
  fi
  local out
  out=$(LD_LIBRARY_PATH="${LLAMA_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}" ldd "$SERVER_BIN" 2>&1)
  if echo "$out" | grep -qiE "not found|file too short|cannot open shared object|version .* not found"; then
    LAST_LDD_ISSUE=$(echo "$out" | grep -iE "not found|file too short|cannot open shared object|version .* not found")
    return 1
  fi
  return 0
}

if ! _check_llama_server_ok; then
  echo "──────────────────────────────────────────────"
  echo "설치된 llama-server 실행에 문제가 있습니다:"
  echo "$LAST_LDD_ISSUE"
  echo ""
  BACKUP_DIR_FOUND=$(_find_latest_llama_server_backup)
  if [ -n "$BACKUP_DIR_FOUND" ] && [ -d "$BACKUP_DIR_FOUND" ]; then
    echo "[자동 복구] 최근 백업 발견: $BACKUP_DIR_FOUND → 복구 시도 중..."
    mkdir -p "$SELECTED_DIR"
    cp -a "$BACKUP_DIR_FOUND"/. "$SELECTED_DIR"/ 2>/dev/null || true
    if _check_llama_server_ok; then
      echo "  → 복구 성공. 이번 실행은 복구된 바이너리로 계속 진행합니다."
      echo "──────────────────────────────────────────────"
    else
      echo "  → 백업에서 복구를 시도했지만 여전히 문제가 있습니다: $LAST_LDD_ISSUE"
      echo ""
      echo "→ bash build_llama_server.sh 를 다시 실행해서 재설치한 뒤 다시 시도하세요."
      echo "──────────────────────────────────────────────"
      exit 1
    fi
  else
    echo "[자동 복구] 사용할 수 있는 백업(llama_server_backup_*)이 없습니다."
    echo ""
    echo "→ bash build_llama_server.sh 를 다시 실행해서 재설치한 뒤 다시 시도하세요."
    echo "──────────────────────────────────────────────"
    exit 1
  fi
fi

# ─── GPU 백엔드/디바이스 자동 감지 ────────────────────────────────────────────
# nvidia-smi/rocm-smi 같은 벤더 전용 도구 대신, 방금 빌드된 llama-server 바이너리
# 자신에게 "어떤 디바이스가 보이는지" 물어본다(--list-devices). CUDA/ROCm/Vulkan/Metal
# 무엇으로 빌드됐든 공통 인자 파서라 출력 포맷이 동일해서 백엔드 무관하게 동작한다.
# [FIX] 권한 점검은 "등록되어 있는가"와 "지금 이 셸에 반영되어 있는가"를 반드시 구분한다.
#   id -nG "$USER" → /etc/group 을 조회 (usermod 하면 즉시 반영)
#   id -nG         → 현재 프로세스의 실제 그룹 (재로그인 전이면 옛날 그대로)
# 예전 코드는 앞의 것만 봐서, usermod 직후 재로그인을 안 한 상태에서도
# "render 그룹 소속 확인됨"이라고 알려준 뒤 정작 GPU 인식에 실패했다.
#
# 또한 두 디바이스 노드의 권한 방식이 달라서 백엔드별로 증상이 갈린다:
#   /dev/dri/renderD128 → ACL(+) 이 붙어 로그인 세션 사용자에게 자동 허용 → Vulkan은 재로그인 없이도 동작
#   /dev/kfd            → ACL 없음, 오직 render 그룹으로만 접근 → ROCm/HIP 는 재로그인 필수
# 그래서 "Vulkan은 됐는데 HIP로 바꾸니 갑자기 디바이스가 없다"는 상황이 발생한다.
GROUP_HINT=""
if [ -e /dev/dri/renderD128 ] || [ -e /dev/kfd ]; then
  if ! id -nG "$USER" 2>/dev/null | grep -qw render; then
    GROUP_HINT="사용자($USER)가 'render' 그룹에 등록되어 있지 않습니다.
    해결: sudo usermod -aG render,video $USER   (실행 후 로그아웃→재로그인)"
  elif ! id -nG 2>/dev/null | grep -qw render; then
    GROUP_HINT="'render' 그룹에 등록은 되어 있지만 현재 로그인 세션에 아직 반영되지 않았습니다.
    해결: 로그아웃 후 다시 로그인 (또는 재부팅)
    임시 우회: sg render -c \"sg video -c ./run_llama_server.sh\"
    참고: /dev/kfd 는 ACL이 없어 ROCm/HIP 은 반드시 그룹 반영이 필요합니다.
          (Vulkan 은 /dev/dri 의 ACL 덕분에 재로그인 없이도 동작하므로 증상이 다릅니다.)"
  fi
  [ -n "$GROUP_HINT" ] && echo "⚠️  $GROUP_HINT"
fi

mapfile -t DEVICE_LINES < <(LD_LIBRARY_PATH="${LLAMA_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}" "$SERVER_BIN" --list-devices 2>/dev/null | grep -E '^[[:space:]]*[A-Za-z0-9_]+:' || true)

DEVICE_IDS=()
DEVICE_LABELS=()
DEVICE_TOTAL_MB=()
DEVICE_FREE_MB=()
for line in "${DEVICE_LINES[@]:-}"; do
  [ -z "$line" ] && continue
  # 형식 예: "  Vulkan1: AMD Radeon Graphics (RADV VEGA20) (32768 MiB, 32737 MiB free)"
  if [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_]+):[[:space:]]*(.+)\(([0-9]+)[[:space:]]MiB,[[:space:]]([0-9]+)[[:space:]]MiB[[:space:]]free\) ]]; then
    dev_id="${BASH_REMATCH[1]}"
    dev_name="$(echo "${BASH_REMATCH[2]}" | sed 's/[[:space:]]*$//')"
    DEVICE_IDS+=("$dev_id")
    DEVICE_LABELS+=("${dev_id}: ${dev_name} (${BASH_REMATCH[3]} MiB total, ${BASH_REMATCH[4]} MiB free)")
    DEVICE_TOTAL_MB+=("${BASH_REMATCH[3]}")
    DEVICE_FREE_MB+=("${BASH_REMATCH[4]}")
  fi
done

CHOSEN_DEVICE=""
chosen_free_mb=0

if [ ${#DEVICE_IDS[@]} -eq 0 ]; then
  echo "GPU 디바이스가 감지되지 않았습니다 (CPU-only 빌드이거나 드라이버 미인식). CPU로 진행합니다."
elif [ ${#DEVICE_IDS[@]} -eq 1 ]; then
  CHOSEN_DEVICE="${DEVICE_IDS[0]}"
  chosen_free_mb="${DEVICE_FREE_MB[0]}"
  echo "감지된 GPU 디바이스: ${DEVICE_LABELS[0]}"
else
  echo "감지된 GPU 디바이스 ${#DEVICE_IDS[@]}개:"
  for i in "${!DEVICE_IDS[@]}"; do
    echo "  [$i] ${DEVICE_LABELS[$i]}"
  done
  # 기본값: 총 용량(VRAM)이 가장 큰 디바이스. 보통 내장 GPU의 UMA 공유메모리보다
  # 전용 GPU의 VRAM이 크거나, 최소한 실제 추론 용도에 맞는 디바이스일 확률이 높다.
  default_idx=0
  for i in "${!DEVICE_IDS[@]}"; do
    if [ "${DEVICE_TOTAL_MB[$i]}" -gt "${DEVICE_TOTAL_MB[$default_idx]}" ]; then
      default_idx=$i
    fi
  done
  read -p "사용할 디바이스 번호 선택 [기본값 $default_idx: ${DEVICE_IDS[$default_idx]}]: " dev_choice
  if [[ "$dev_choice" =~ ^[0-9]+$ ]] && [ "$dev_choice" -ge 0 ] && [ "$dev_choice" -lt "${#DEVICE_IDS[@]}" ]; then
    default_idx="$dev_choice"
  fi
  CHOSEN_DEVICE="${DEVICE_IDS[$default_idx]}"
  chosen_free_mb="${DEVICE_FREE_MB[$default_idx]}"
  echo "선택됨: ${DEVICE_LABELS[$default_idx]}"
fi

MODEL_DIR="models"

echo "Available model directories under '$MODEL_DIR':"
mapfile -t DIRS < <(find "$MODEL_DIR" -maxdepth 1 -mindepth 1 -type d | sort)
PS3="Select a directory (or enter 0 to use root models dir): "
options=()
for d in "${DIRS[@]}"; do
  options+=("$d")
done
# Do not add $MODEL_DIR to options to avoid showing it twice; accept 0 to select root
select CHOSEN_DIR in "${options[@]}"; do
  if [ "$REPLY" = "0" ]; then
    TARGET_DIR="$MODEL_DIR"
    echo "Selected directory: $TARGET_DIR"
    break
  elif [ -n "$CHOSEN_DIR" ]; then
    echo "Selected directory: $CHOSEN_DIR"
    TARGET_DIR="$CHOSEN_DIR"
    break
  else
    echo "Invalid selection.";
  fi
done

# ── 디스크 페이징 모드 검증 (LAZY_MODE=auto|on|off) ─────────────────────────
# 값 검사는 여기서 한다 — 2분짜리 로딩을 태운 뒤에 "잘못된 값" 을 보면 안 된다.
LAZY_MODE="${LAZY_MODE:-auto}"
case "$LAZY_MODE" in
  auto|on|off) : ;;
  *) echo "⛔ LAZY_MODE 는 auto|on|off 중 하나여야 합니다 (받은 값: $LAZY_MODE)"; exit 1 ;;
esac
if [ "$LAZY_MODE" = "off" ]; then
  echo "⚠ LAZY_MODE=off — 페이징 대상 텐서를 통째로 메모리에 올립니다."
  echo "  큰 색인 텐서가 있는 모델(예: Qwen3.8-Flash-Next 의 36 GiB n-gram 테이블)에서는"
  echo "  RAM 이 부족해 죽습니다. 이 박스(RAM 30 GiB)에서는 실측으로 죽었습니다."
  read -p "  그래도 진행할까요? (y/N): " _lz; [[ "${_lz:-N}" =~ ^[Yy]$ ]] || exit 1
fi

# Auto-detect mmproj and model inside the chosen directory
mapfile -t ALL_GGUF < <(find "$TARGET_DIR" -maxdepth 1 \( -type f -o -type l \) -iname "*.gguf" | sort)
if [ ${#ALL_GGUF[@]} -eq 0 ]; then
  echo "No .gguf files found in $TARGET_DIR.";
  read -p "Would you like to provide absolute paths for model and (optional) mmproj? (y/N): " provide
  provide=${provide:-N}
  if [[ "$provide" =~ ^[Yy]$ ]]; then
    read -p "Enter absolute path to model GGUF: " MODEL_PATH
    if [ ! -f "$MODEL_PATH" ]; then echo "File not found: $MODEL_PATH"; exit 1; fi
    read -p "Enter absolute path to mmproj GGUF (or press Enter to skip): " PROJ_PATH
    if [ -n "$PROJ_PATH" ] && [ ! -f "$PROJ_PATH" ]; then echo "Projection file not found: $PROJ_PATH"; exit 1; fi
  else
    echo "Place gguf files in the directory or choose another directory."; exit 1
  fi
else
  mapfile -t PROJ_CANDS < <(printf '%s\n' "${ALL_GGUF[@]}" | grep -i mmproj || true)
  # MTP 사이드카 탐지. download_model.py 는 '<이름>_mtp.gguf' 로 저장하지만,
  # HF 원본 파일명(…-FastMTP-32K.gguf)을 그대로 넣어 둔 경우도 받아 준다.
  # 패턴을 더 넓히면 안 된다: 본 모델 파일 이름이 '-MTP.gguf' 로 끝나는 경우가 흔한데
  # (저장소 이름에서 딴 디렉터리 이름 때문) 그걸 사이드카로 오인하면 30GB 짜리
  # 본 모델이 드래프트 자리로 넘어간다.
  mapfile -t MTP_CANDS < <(printf '%s\n' "${ALL_GGUF[@]}" \
    | grep -Ei '(_mtp\.gguf|[-_.]fastmtp([-_.][^/]*)?\.gguf|/mtp[-_.][^/]*\.gguf)$' || true)
  if [ ${#MTP_CANDS[@]} -gt 0 ]; then
    MTP_PATH="${MTP_CANDS[0]}"
    echo "Auto-detected MTP draft model: $MTP_PATH"
  else
    MTP_PATH=""
  fi
  # model candidates are gguf files excluding mmproj
  model_tmp=()
  for f in "${ALL_GGUF[@]}"; do
    if ! printf '%s\n' "${PROJ_CANDS[@]}" | grep -qx "${f}" 2>/dev/null \
        && ! printf '%s\n' "${MTP_CANDS[@]}" | grep -qx "${f}" 2>/dev/null; then
      model_tmp+=("$f")
    fi
  done
  mapfile -t MODEL_CANDS < <(printf '%s\n' "${model_tmp[@]}" | grep -v '^$' || true)

  # ── 샤드 분할 GGUF 접기 ────────────────────────────────────────────────────
  # 큰 모델은 '…-00001-of-00033.gguf' 로 쪼개져 있다. 접지 않으면 select 메뉴에
  # 33줄이 뜨고, 무엇을 고르든 조각 하나가 -m 으로 넘어가 llama.cpp 가
  # 'invalid split file name' 으로 죽는다. llama.cpp 에는 **첫 샤드만** 주면
  # 나머지는 이름에서 계산해 찾는다(llama_split_prefix).
  # 접두사(-NNNNN-of-NNNNN 를 뗀 것)로 묶고, 묶음당 첫 샤드 하나만 남긴다.
  declare -A _shard_first _shard_n _shard_want _shard_bytes
  folded=()
  for f in "${MODEL_CANDS[@]}"; do
    b="$(basename "$f")"
    if [[ "$b" =~ ^(.+)-([0-9]{5})-of-([0-9]{5})\.gguf$ ]]; then
      key="$(dirname "$f")/${BASH_REMATCH[1]}"
      idx=$((10#${BASH_REMATCH[2]})); want=$((10#${BASH_REMATCH[3]}))
      _shard_n["$key"]=$(( ${_shard_n["$key"]:-0} + 1 ))
      _shard_want["$key"]=$want
      _shard_bytes["$key"]=$(( ${_shard_bytes["$key"]:-0} + $(stat -Lc%s "$f" 2>/dev/null || echo 0) ))
      if [ "$idx" -eq 1 ]; then _shard_first["$key"]="$f"; folded+=("$f"); fi
    else
      folded+=("$f")
    fi
  done
  # 첫 샤드가 없는 묶음(00001 누락)은 위 루프에서 후보가 안 잡히므로 여기서 알린다
  for key in "${!_shard_n[@]}"; do
    if [ -z "${_shard_first[$key]:-}" ]; then
      echo "⚠ $(basename "$key"): 첫 샤드(-00001-of-*)가 없습니다. 이 묶음은 띄울 수 없습니다."
    fi
  done
  mapfile -t MODEL_CANDS < <(printf '%s\n' "${folded[@]}" | grep -v '^$' || true)

  # 묶음 요약을 한 줄씩 보여 준다 (메뉴에서 무엇을 고르는지 알 수 있게)
  for key in "${!_shard_n[@]}"; do
    have=${_shard_n[$key]}; want=${_shard_want[$key]}
    gb=$(awk -v b="${_shard_bytes[$key]:-0}" 'BEGIN{printf "%.1f", b/1073741824}')
    if [ "$have" -eq "$want" ]; then
      echo "샤드 묶음: $(basename "$key") — ${have}/${want}개 · ${gb} GiB"
    else
      echo "⚠ 샤드 묶음: $(basename "$key") — ${have}/${want}개 · ${gb} GiB  ($((want-have))개 없음 — 띄우면 'invalid split count' 로 죽습니다)"
    fi
  done

  # choose projection if present
  if [ ${#PROJ_CANDS[@]} -gt 0 ]; then
    PROJ_PATH="${PROJ_CANDS[0]}"
    echo "Auto-detected projection: $PROJ_PATH"
  else
    PROJ_PATH=""
  fi

  # choose model if exactly one candidate, else prompt
  if [ ${#MODEL_CANDS[@]} -eq 1 ]; then
    MODEL_PATH="${MODEL_CANDS[0]}"
    echo "Auto-detected model: $MODEL_PATH"
  elif [ ${#MODEL_CANDS[@]} -gt 1 ]; then
    echo "Multiple model GGUF files found in $TARGET_DIR:";
    select sel in "${MODEL_CANDS[@]}" "Enter absolute path"; do
      if [ "$REPLY" -ge 1 ] 2>/dev/null && [ "$REPLY" -le ${#MODEL_CANDS[@]} ]; then
        MODEL_PATH="${MODEL_CANDS[$REPLY-1]}"; echo "Selected model: $MODEL_PATH"; break
      elif [ "$REPLY" -eq $((${#MODEL_CANDS[@]}+1)) ] 2>/dev/null; then
        read -p "Enter absolute path to model GGUF: " MODEL_PATH
        if [ ! -f "$MODEL_PATH" ]; then echo "File not found: $MODEL_PATH"; exit 1; fi
        break
      else
        echo "Invalid selection.";
      fi
    done
  else
    # no non-mmproj gguf found
    echo "No LLM gguf file detected in $TARGET_DIR.";
    read -p "Would you like to provide model path manually? (y/N): " manual
    manual=${manual:-N}
    if [[ "$manual" =~ ^[Yy]$ ]]; then
      read -p "Enter absolute path to model GGUF: " MODEL_PATH
      if [ ! -f "$MODEL_PATH" ]; then echo "File not found: $MODEL_PATH"; exit 1; fi
    else
      echo "Aborting."; exit 1
    fi
  fi
fi

# ── 샤드 완결성 검사 ──────────────────────────────────────────────────────────
# 여기서 막지 않으면 100초짜리 로딩을 태운 뒤에야 'invalid split count' 를 본다.
# llama.cpp 는 첫 샤드 이름에서 나머지 경로를 계산하므로, 이름이 하나라도
# 어긋나거나 빠지면 못 찾는다.
check_shards() {
  local first="$1" base dir stem want i path missing=0
  base="$(basename "$first")"
  [[ "$base" =~ ^(.+)-([0-9]{5})-of-([0-9]{5})\.gguf$ ]] || return 0   # 단일 파일
  dir="$(dirname "$first")"; stem="${BASH_REMATCH[1]}"; want=$((10#${BASH_REMATCH[3]}))
  if [ "$((10#${BASH_REMATCH[2]}))" -ne 1 ]; then
    echo "⛔ 샤드 모델은 **첫 샤드**를 지정해야 합니다: ${stem}-00001-of-$(printf '%05d' "$want").gguf"
    return 1
  fi
  for ((i=1;i<=want;i++)); do
    path="$dir/${stem}-$(printf '%05d' "$i")-of-$(printf '%05d' "$want").gguf"
    [ -f "$path" ] || { echo "   없음: $(basename "$path")"; missing=$((missing+1)); }
    [ "$missing" -ge 5 ] && { echo "   … (이하 생략)"; break; }
  done
  if [ "$missing" -gt 0 ]; then
    echo "⛔ 샤드가 빠졌습니다. 다 받고 다시 실행하세요 (download_model.sh 가 이어받습니다)."
    return 1
  fi
  echo "샤드 ${want}개 모두 확인 — llama.cpp 에는 첫 샤드만 넘깁니다."
  return 0
}
check_shards "$MODEL_PATH" || exit 1

# Confirm auto-detected paths with user
echo "Detected paths: model=$MODEL_PATH proj=${PROJ_PATH:-<none>}"
read -p "Confirm and continue? (Y/n): " confirm
confirm=${confirm:-Y}
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  read -p "Enter absolute path to model GGUF: " MODEL_PATH
  if [ ! -f "$MODEL_PATH" ]; then echo "File not found: $MODEL_PATH"; exit 1; fi
  read -p "Enter absolute path to mmproj GGUF (or press Enter to skip): " PROJ_PATH
  if [ -n "$PROJ_PATH" ] && [ ! -f "$PROJ_PATH" ]; then echo "Projection file not found: $PROJ_PATH"; exit 1; fi
fi

# Vision model projection selection (interactive)
# If a projection was already auto-detected, assume it's vision and keep it
if [ -n "${PROJ_PATH:-}" ]; then
  echo "Auto-detected projection: $PROJ_PATH (using it)"
  IS_VISION=Y
else
  read -p "Is this a vision / multimodal model that requires a projection file? (y/N): " IS_VISION
  IS_VISION=${IS_VISION:-N}
fi

# Only search for projection files in the chosen target directory when needed
if [[ "$IS_VISION" =~ ^[Yy]$ ]] && [ -z "${PROJ_PATH:-}" ]; then
  echo "Searching for projection files (mmproj-*.gguf) in '$TARGET_DIR'..."
  mapfile -t PROJ_FILES < <(find "$TARGET_DIR" -maxdepth 1 \( -type f -o -type l \) -iname "*mmproj-*.gguf" | sort)
  if [ ${#PROJ_FILES[@]} -eq 0 ]; then
    echo "No mmproj-*.gguf files found in $TARGET_DIR. You can add one or skip.";
    read -p "Proceed without projection file? (y/N): " SKIP_PROJ
    SKIP_PROJ=${SKIP_PROJ:-N}
    if [[ ! "$SKIP_PROJ" =~ ^[Yy]$ ]]; then
      echo "Aborting. Place projection files in $TARGET_DIR and re-run."; exit 1
    fi
  else
    echo "Select a vision projection file:"
    PS3="Enter number (or Ctrl+C to cancel): "
    select PROJ_PATH in "${PROJ_FILES[@]}" "Skip"; do
      if [ "$REPLY" -ge 1 ] 2>/dev/null && [ "$REPLY" -le ${#PROJ_FILES[@]} ]; then
        PROJ_PATH="${PROJ_FILES[$REPLY-1]}"
        echo "Selected projection: $PROJ_PATH"
        break
      elif [ "$REPLY" -eq $((${#PROJ_FILES[@]}+1)) ] 2>/dev/null; then
        PROJ_PATH=""
        echo "Skipping projection file."; break
      else
        echo "Invalid selection.";
      fi
    done
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# MTP(다중 토큰 예측) 설정
#
# 갈래가 둘인데 예전 코드는 (2)만 처리했다.
#   (1) 내장 MTP : 본 모델 GGUF 안에 nextn 블록이 들어 있으면 사이드카 없이
#                  '--spec-type draft-mtp' 만으로 켜진다. llama.cpp 가 타깃 모델
#                  자신을 상대로 MTP 드래프트 컨텍스트를 만든다.
#   (2) 사이드카 : 본 모델에 nextn 이 없고 별도 MTP GGUF 가 있을 때
#                  '--model-draft <사이드카>' 를 같이 넘긴다(Gemma4 계열이 이쪽).
# 그래서 nextn 이 내장된 models/…-Q8_K_P-MTP.gguf 로 띄우면, 디렉터리에 사이드카
# 파일이 없다는 이유만으로 MTP 플래그가 하나도 안 붙은 채 돌고 있었다.
#
# 판정은 GGUF 헤더 grep 한 번. 메타데이터 KV 는 파일 앞쪽이지만 토크나이저 배열
# (248k 토큰) 뒤에 오는 키가 있어 실측 오프셋이 11MB 근처였다 → 64MB 를 훑는다.
# MTP=0 으로 통째로 끌 수 있다.
# ─────────────────────────────────────────────────────────────────────────────
_gguf_has_str() {   # $1: gguf 파일, $2: 찾을 문자열(고정 문자열)
  [ -f "$1" ] || return 1
  head -c 67108864 "$1" 2>/dev/null | LC_ALL=C grep -q -a -m1 -F -- "$2"
}

# 사이드카가 d2t(드래프트 어휘 축소 맵) 텐서를 갖고 있으면 stock llama.cpp 로는
# 못 읽는다(HauhauCS FastMTP 방식). GGUF 는 텐서 이름을 '길이(8바이트 LE) + 이름'
# 으로 저장하므로 길이 접두까지 같이 봐야 토크나이저 문자열과 안 헷갈린다
# (실측: 그냥 'd2t' 로 찾으면 Gemma 사이드카에서 4번 오탐).
_gguf_has_d2t_tensor() {
  [ -f "$1" ] || return 1
  head -c 67108864 "$1" 2>/dev/null | LC_ALL=C grep -q -a -P '\x03\x00{7}d2t' 2>/dev/null
}

# 설치된 llama.cpp 가 그 d2t 를 읽을 수 있는가(= HauhauCS 런타임 패치가 들어갔는가).
_llama_has_d2t_support() {
  LC_ALL=C grep -q -a -F 'd2t draft-vocab trim' \
    "$SELECTED_DIR"/libllama*.so* "$SERVER_BIN" 2>/dev/null
}

MTP_ARGS=()
MTP_EMBEDDED=0
if [ "${MTP:-1}" = "0" ]; then
  echo "MTP: 환경변수 MTP=0 → 비활성화"
  MTP_PATH=""
else
  if _gguf_has_str "$MODEL_PATH" "nextn_predict_layers"; then
    MTP_EMBEDDED=1
  fi

  if [ -n "${MTP_PATH:-}" ] && _gguf_has_d2t_tensor "$MTP_PATH" \
      && ! _llama_has_d2t_support; then
    echo "⚠️  MTP 사이드카가 d2t(축소 어휘) 방식입니다: $(basename "$MTP_PATH")"
    echo "    지금 설치된 llama-server 에는 이걸 읽는 코드가 없습니다. 그대로 넘기면"
    echo "    드래프트 로딩이 'expected …, got …' 텐서 크기 불일치로 실패합니다."
    echo "    (해결: 모델 저장소의 HauhauCS-FastMTP-llama.cpp.patch 를 적용해 재빌드)"
    if [ "$MTP_EMBEDDED" -eq 1 ]; then
      echo "    → 본 모델에 MTP 가 내장돼 있으므로 사이드카 없이 내장 MTP 로 진행합니다."
    else
      echo "    → MTP 를 끄고 진행합니다."
    fi
    MTP_PATH=""
  fi

  if [ -n "${MTP_PATH:-}" ]; then
    MTP_ARGS=( --model-draft "$MTP_PATH" --spec-type draft-mtp )
    echo "MTP: 사이드카 사용 — $(basename "$MTP_PATH")"
  elif [ "$MTP_EMBEDDED" -eq 1 ]; then
    MTP_ARGS=( --spec-type draft-mtp )
    echo "MTP: 본 모델에 내장된 MTP 사용 (--spec-type draft-mtp, 사이드카 없음)"
  else
    echo "MTP: 사용 안 함 (본 모델에 nextn 블록이 없고 사이드카도 없습니다)"
  fi
fi

LOG_FILE="logs/llama_server.log"

mkdir -p "$(dirname "$LOG_FILE")"

# Measure file sizes (bytes)
model_bytes=0
proj_bytes=0
if [ -f "$MODEL_PATH" ]; then
  # 샤드 분할이면 **묶음 전체**를 더한다. 첫 샤드만 재면 88 GB 모델이 662 MB 로 찍히고,
  # 그 값으로 컨텍스트를 추정하는 2·3순위 경로가 VRAM 을 크게 과대평가한다.
  _mb="$(basename "$MODEL_PATH")"
  if [[ "$_mb" =~ ^(.+)-([0-9]{5})-of-([0-9]{5})\.gguf$ ]]; then
    model_bytes=0
    for _sh in "$(dirname "$MODEL_PATH")/${BASH_REMATCH[1]}"-[0-9][0-9][0-9][0-9][0-9]-of-*.gguf; do
      [ -e "$_sh" ] || continue
      model_bytes=$(( model_bytes + $(stat -Lc%s "$_sh" 2>/dev/null || echo 0) ))
    done
  else
    model_bytes=$(stat -Lc%s "$MODEL_PATH" 2>/dev/null || stat -f%z "$MODEL_PATH" 2>/dev/null || echo 0)
  fi
fi
if [ -n "$PROJ_PATH" ] && [ -f "$PROJ_PATH" ]; then
  proj_bytes=$(stat -Lc%s "$PROJ_PATH" 2>/dev/null || stat -f%z "$PROJ_PATH" 2>/dev/null || echo 0)
fi

# MTP 사이드카도 VRAM 을 먹는다(903MB 짜리도 있다). 1순위 -fit 경로는 드래프트를
# 같이 올려서 재보므로 자동으로 반영되지만, 2·3순위 추정 경로는 파일 크기로만
# 계산하므로 여기서 같이 빼 주지 않으면 그만큼 컨텍스트를 과대평가한다.
mtp_bytes=0
if [ -n "${MTP_PATH:-}" ] && [ -f "$MTP_PATH" ]; then
  mtp_bytes=$(stat -c%s "$MTP_PATH" 2>/dev/null || stat -f%z "$MTP_PATH" 2>/dev/null || echo 0)
fi

model_mb=$(( (model_bytes + 1024*1024 - 1) / (1024*1024) ))
proj_mb=$(( (proj_bytes + 1024*1024 - 1) / (1024*1024) ))
mtp_mb=$(( (mtp_bytes + 1024*1024 - 1) / (1024*1024) ))

echo "Model size: ${model_mb} MB"
if [ $proj_mb -gt 0 ]; then
  echo "Projection size: ${proj_mb} MB"
fi
if [ $mtp_mb -gt 0 ]; then
  echo "MTP draft size: ${mtp_mb} MB"
fi

# GPU 여유 VRAM (MB) — 위에서 --list-devices 로 감지해 둔 값을 그대로 사용.
# (벤더 도구 대신 llama-server 자신이 보고하는 값이라 백엔드 무관하게 정확하다.)
vram_mb="${chosen_free_mb:-0}"
if [ -z "$vram_mb" ] || [ "$vram_mb" -eq 0 ]; then
  echo "Warning: GPU 여유 VRAM을 감지하지 못했습니다. 안전한 기본값으로 폴백합니다.";
else
  # [FIX] 이 값은 "모델을 로드하기 전, 지금 이 순간" GPU에 비어있는 용량이다.
  # 바로 아래에서 곧 올릴 모델(model_mb)+프로젝션(proj_mb) 크기를 빼서 "모델 로드 후
  # 실제로 컨텍스트/KV캐시에 쓸 수 있는 양"(est_available_mb)을 별도로 계산하는데,
  # 예전엔 그 결과를 화면에 안 보여주고 바로 largest_ctx(토큰 수)로만 환산해서 보여줬다.
  # 그러면 "여유 VRAM 32GB인데 왜 컨텍스트가 이거밖에 안 나오지?"처럼 헷갈리므로,
  # 라벨을 명확히 하고 중간 계산값(로드 후 여유량)도 그대로 출력한다.
  echo "감지된 GPU 여유 VRAM (모델 로드 전 현재값): ${vram_mb} MB"
fi

# [FIX] KV 캐시 타입 기본값은 q8_0. 취향이 아니라 실측 근거가 있다.
#
# MI50/gfx906, 35B-A3B Q4_K_M, -fa on, 채운 토큰 175개 고정, 클럭 high:
#
#   KV 타입 | ctx 16384 | ctx 20480 | ctx 32768 | ctx 65536 | ctx 131072
#   --------|-----------|-----------|-----------|-----------|------------
#   q4_0    |   69.9    |    8.9 ⚠  |    8.9 ⚠  |     -     |     -        (Vulkan)
#   f16     |     -     |     -     |   71.3    |   70.7    |     -        (Vulkan)
#   q8_0    |     -     |     -     |   70.0    |   70.0    |     -        (Vulkan)
#   q8_0    |     -     |     -     |   58.6    |     -     |   58.4       (ROCm/HIP)
#
# 관찰 1: Vulkan + q4_0 은 컨텍스트 20480 부터 무너진다. 세 값(20480/24576/32768)이
#         소수점까지 같은 8.9 인 것으로 보아 KV 크기에 비례하는 연산이 아니라
#         고정 비용의 느린 경로다. q8_0/f16 은 이 현상이 없다.
# 관찰 2: q8_0 은 f16 과 속도 차이가 사실상 없으면서 VRAM 은 절반만 쓴다.
#         (토큰당 K+V: f16 2.0B/원소, q8_0 1.0625B/원소, q4_0 0.5625B/원소)
# 관찰 3: HIP 는 q4_0 로도 평탄하지만, q8_0 이어도 성능 손해가 없다.
#
# 결론: q8_0 을 양쪽 백엔드 공통 기본값으로 쓴다.
#   - Vulkan 의 q4_0 절벽을 피한다
#   - f16 대비 VRAM 절반 → 같은 여유 VRAM 으로 약 2배 긴 컨텍스트를 담는다
#     (원소당 2.0B → 1.0625B, 실측한 토큰당 KV 도 정확히 이 비율로 줄어든다)
#   - q4_0 대비 양자화 손실이 작다
# 다른 값이 필요하면 KV_TYPE 환경변수로 바꾼다 (예: KV_TYPE=f16 ./run_llama_server.sh).
KV_TYPE=${KV_TYPE:-q8_0}
echo "KV 캐시 타입: ${KV_TYPE}  (백엔드=${CHOSEN_DEVICE:-CPU}, KV_TYPE 환경변수로 변경 가능)"

# [FIX] 슬롯 개수(--parallel)를 명시한다. 지정하지 않으면 llama-server 기본값이 4 인데,
# Vulkan 백엔드에서는 이것만으로 토큰 생성이 무너진다.
#
#   MI50/gfx906 + Vulkan, 35B-A3B Q4_K_M, -fa on -ctk/-ctv q8_0:
#       ctx 65536, --parallel 4  →  5.49 t/s
#       ctx 93184, --parallel 4  →  5.49 t/s   ← 컨텍스트를 바꿔도 값이 같다
#       ctx 93184, --parallel 1  → 55.14 t/s
#
# 컨텍스트 크기와 무관하게 정확히 같은 5.49 가 나오는 것으로 보아, 연산량 증가가 아니라
# 다중 시퀀스(kv_unified) 상황에서 느린 경로로 빠지는 것이다. q4_0 절벽(8.9 고정)과
# 같은 양상이며, 둘 다 Vulkan 백엔드 한정이다. ROCm/HIP 는 슬롯을 늘려도 무너지지 않는다.
#
# 슬롯을 여러 개 두면 동시 요청 처리량이 늘지만, 개인용 서버는 보통 한 번에 한 요청만
# 처리하므로 1 이 지연시간 면에서 유리하다. 동시 사용자가 여럿이면 PARALLEL 로 올린다.
N_PARALLEL=${PARALLEL:-1}
echo "슬롯 수(--parallel): ${N_PARALLEL}  (동시 요청을 여럿 받으려면 PARALLEL=4 등으로 지정)"
if [[ "${CHOSEN_DEVICE}" == Vulkan* ]] && [ "$N_PARALLEL" -gt 1 ]; then
  echo "⚠️  Vulkan 백엔드에서 --parallel > 1 은 생성 속도를 10배 가까이 떨어뜨립니다"
  echo "    (실측: parallel=1 에서 55 t/s → parallel=4 에서 5.5 t/s)."
fi

if [[ "${CHOSEN_DEVICE}" == Vulkan* ]] && [[ "$KV_TYPE" == q4_* || "$KV_TYPE" == q5_* || "$KV_TYPE" == iq4_* ]]; then
  echo "⚠️  Vulkan 백엔드 + ${KV_TYPE} 조합은 컨텍스트 20480 이상에서 생성 속도가"
  echo "    8.9 t/s 수준으로 붕괴하는 것이 실측되었습니다 (q8_0 은 70 t/s)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# [FIX 2026-08-21] 컨텍스트 추정: 상수를 버리고 llama.cpp 자신에게 물어본다.
#
# 예전 코드는 토큰당 KV 크기를 KV 타입만 보고 상수로 잡았다(q8_0 이면 8.5 tokens/MB).
# KV 크기는 모델 구조에 달려 있어서 상수 하나로는 맞을 수 없다. 이 저장소의 모델
# 세 개를 llama.cpp 가 보고하는 값으로 재보면:
#
#   모델                          | KV 있는 층  | 토큰당 KV(q8_0) | tokens/MiB
#   ------------------------------|-------------|-----------------|-----------
#   Qwen3.8-27B-ABLITERATED       | 64 중 16    |   34,816 B      |   30.1
#   Qwen3.6-35B-A3B (MoE)         | 40 중 10    |   10,880 B      |   96.4
#   Gemma4-26B-A4B (MoE)          | 30 중  5    |   10,880 B      |   96.4
#
# 상수 8.5 는 첫 모델에서 3.5배, 뒤 둘에서 11배 과대평가였다(= 컨텍스트를 그만큼
# 손해봤다). 셋 다 하이브리드 구조라 층 전부가 KV 를 갖지 않는다. qwen35 계열은
# full_attention_interval=4 라 네 층 중 하나만 어텐션이고 나머지는 SSM 상태(RS 버퍼),
# Gemma4 는 25개 층이 슬라이딩 윈도우라 컨텍스트와 무관하게 1536 셀로 고정된다.
# 그래서 GGUF 메타데이터에 block_count × head_count_kv × key_length 공식을 그대로
# 넣는 방법도 4배씩 틀린다. 추측하지 말고 물어봐야 한다.
#
# 물어보는 방법은 두 가지고, 정확한 쪽을 먼저 쓴다.
#
# [1순위] -fit: llama-server 는 -c 를 주지 않으면 "여유 VRAM 에 맞는 가장 큰
#   컨텍스트"를 스스로 고른다(--fit on 이 기본값). 이 계산은 **가중치를 올리기 전에**
#   끝난다(실측 0.57초). 그래서 띄우기 직전에 한 번 물어보고 그 값을 그대로 쓸 수 있다.
#   백엔드별 연산 버퍼, 호스트에 남는 텐서(임베딩 등), mmproj 몫까지 llama.cpp 가
#   아는 그대로 반영된다. 사람이 다시 추정할 이유가 없다.
#
#   실측(Qwen3.8-27B + mmproj, ROCm0/gfx906, q8_0, parallel 1):
#     선택 262144 토큰, 예상 30,268 MiB / 여유 32,434 MiB, 2,165 MiB 남김
#     → 이 스크립트로 실제 기동 후 rocm-smi 31,689 MiB / 32,752 MiB (여유 1,063 MiB),
#       65,536 토큰 프롬프트 처리 중에도 그대로 유지. 예전 상수는 같은 조건에서
#       82,304 토큰을 제안했다(3.2배 손해).
#
# [2순위] CPU 드라이런 2점 측정: -fit 이 없는 예전 빌드용 폴백.
#   --device none -ngl 0 --no-repack --no-warmup 으로 두 번 띄워 메모리 내역만 읽는다.
#   GPU 를 건드리지 않고 1초면 끝나지만, GPU 쪽 실측과는 두 군데가 다르다.
#     - 모델 크기: CPU 는 21,049 MiB 로 보고하는데 GPU 에는 20,054 MiB 만 올라간다
#       (임베딩 995 MiB 는 호스트에 남는다) → 과대 추정(안전한 방향)
#     - 연산 버퍼: 컨텍스트에 비례하는 몫이 CPU 1,024 B/token vs ROCm 4,693 B/token
#       → 과소 추정(위험한 방향)
#   두 오차가 대략 상쇄돼서 결과는 쓸 만하지만, 1순위가 되면 쓰지 않는다.
#
#     총량(c) = context + compute (llama.cpp 의 memory breakdown 표)
#     per_token = (총량(c2) − 총량(c1)) / (c2 − c1)     ← KV + 어텐션 마스크
#     fixed     = 총량(c1) − per_token × c1             ← RS/SWA 캐시 + 연산 버퍼 고정분
#
# [3순위] 옛 상수. 위 둘이 다 실패했을 때만 쓰고, 썼다고 화면에 찍는다.
#
# SKIP_CTX_PROBE=1 로 물어보는 단계를 통째로 끄면 3순위로 간다.
# ─────────────────────────────────────────────────────────────────────────────

# 컨텍스트 스파이크용 예비. 2순위(CPU 측정) 경로에서만 쓴다.
reserved_mb=300

probe_tmp=""
probe_port=$(( 18000 + RANDOM % 900 ))

# [1순위] -c 없이 띄워서 llama.cpp 가 고르는 컨텍스트를 읽는다. 가중치 로딩 전에
# 결론이 나오므로 그 줄이 찍히는 즉시 죽인다(VRAM 에 모델이 올라가지 않는다).
# 성공하면 "<선택 n_ctx> <예상 사용 MiB> <여유 MiB> <남기는 MiB>" 한 줄을 출력.
probe_fit() {
  local log="$probe_tmp/fit.log" pid
  local args=( -m "$MODEL_PATH" )
  [ -n "${PROJ_PATH:-}" ] && args+=( --mmproj "$PROJ_PATH" )
  args+=( "${MTP_ARGS[@]}" )
  [ -n "${CHOSEN_DEVICE:-}" ] && args+=( --device "$CHOSEN_DEVICE" )
  args+=( -ngl 99 -fa on -ctk "$KV_TYPE" -ctv "$KV_TYPE" --parallel "$N_PARALLEL"
          --no-warmup -v --port "$probe_port" --host 127.0.0.1 )
  LD_LIBRARY_PATH="${LLAMA_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}" \
    "$SERVER_BIN" "${args[@]}" > "$log" 2>&1 &
  pid=$!
  timeout "${PROBE_TIMEOUT:-180}" tail -f -n +1 --pid="$pid" "$log" 2>/dev/null \
    | grep -m1 -q 'common_fit_params: fitting params to free memory took' || true
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  awk '
    # 마지막으로 찍힌 n_ctx 가 -fit 이 고른 값이다(줄였으면 줄인 값이 뒤에 찍힌다).
    /llama_context: n_ctx  *=/ { nctx = $NF }
    /common_params_fit_impl: projected to use/ {
      s = $0; sub(/.*projected to use /, "", s); split(s, a, " "); projected = a[1]
      t = $0; sub(/.*vs\. /,             "", t); split(t, b, " "); freemem   = b[1]
    }
    /common_params_fit_impl: will leave/ {
      u = $0; sub(/.*will leave /, "", u); split(u, c, " "); leave = c[1]
    }
    /common_fit_params: fitting params to free memory took/ {
      if (nctx > 0) printf "%d %d %d %d\n", nctx, projected, freemem, leave
      exit
    }
  ' "$log"
}

# [2순위] CPU 전용 드라이런. $1 = 요청 컨텍스트.
# 성공하면 "<실제 n_ctx> <context+compute MiB> <모델 MiB> <n_ctx_train>" 한 줄을 출력.
probe_mem() {
  local want="$1" log="$probe_tmp/probe_$1.log" pid
  LD_LIBRARY_PATH="${LLAMA_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}" \
    "$SERVER_BIN" -m "$MODEL_PATH" --device none -ngl 0 --no-repack --no-warmup \
      -c "$want" -fa on -ctk "$KV_TYPE" -ctv "$KV_TYPE" --parallel "$N_PARALLEL" \
      -v --port "$probe_port" --host 127.0.0.1 > "$log" 2>&1 &
  pid=$!
  # 메모리 내역 줄이 찍히면 볼 일이 끝났다. 서버가 포트를 열기 전이다.
  timeout "${PROBE_TIMEOUT:-180}" tail -f -n +1 --pid="$pid" "$log" 2>/dev/null \
    | grep -m1 -q 'common_memory_breakdown_print: |   - ' || true
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  awk '
    /llama_context: n_ctx  *=/  { nctx  = $NF }
    /print_info: n_ctx_train/   { train = $NF }
    # 메모리 내역 표는 두 번 이상 찍힐 수 있다(컨텍스트 재생성). 첫 표만 센다.
    /common_memory_breakdown_print: \| memory breakdown/ { tbl++ }
    # | - Host | <self> = <model> + <context> + <compute> |
    tbl == 1 && /common_memory_breakdown_print: \|   - / {
      split($0, f, "="); split(f[2], g, "+")
      tot_model += g[1] + 0
      tot_ctx   += (g[2] + 0) + (g[3] + 0)
    }
    END { if (nctx > 0 && tot_ctx > 0) printf "%d %d %d %d\n", nctx, tot_ctx, tot_model, train }
  ' "$log"
}

fit_ok=0
kv_probe_ok=0
n_ctx_train=0

if [ "${SKIP_CTX_PROBE:-0}" != "1" ] && [ -x "$SERVER_BIN" ] && [ -f "$MODEL_PATH" ]; then
  probe_tmp="$(mktemp -d 2>/dev/null || echo "/tmp/llama_ctx_probe.$$")"
  mkdir -p "$probe_tmp"

  echo "컨텍스트 계산 중… (llama-server 에게 -fit 으로 물어봅니다. 가중치를 올리기 전 단계라 1초면 끝납니다)"
  fit_out="$(probe_fit)"
  if [ -n "$fit_out" ]; then
    read -r fit_ctx fit_proj fit_free fit_leave <<<"$fit_out"
    if [ "${fit_ctx:-0}" -gt 0 ]; then
      largest_ctx="$fit_ctx"
      fit_ok=1
    fi
  fi

  if [ "$fit_ok" -eq 1 ]; then
    echo "llama.cpp 가 직접 고른 값 (-fit, 백엔드=${CHOSEN_DEVICE:-CPU}, KV=${KV_TYPE}, --parallel ${N_PARALLEL}):"
    echo "  선택된 컨텍스트 : ${largest_ctx} 토큰"
    if [ "${fit_proj:-0}" -gt 0 ]; then
      echo "  예상 VRAM 사용  : ${fit_proj} MiB  (여유 ${fit_free} MiB 중)"
    fi
    if [ "${fit_leave:-0}" -gt 0 ]; then
      echo "  남기는 여유     : ${fit_leave} MiB  (-fitt 로 조정, 기본 1024 + mmproj 몫)"
    fi
  else
    # -fit 이 없는(또는 로그 형식이 다른) 빌드. CPU 드라이런 2점 측정으로 내려간다.
    echo "-fit 결과를 읽지 못했습니다 → CPU 드라이런 측정으로 대체합니다."
    probe_a=$(probe_mem 8192)
    probe_b=$(probe_mem 32768)
    if [ -n "$probe_a" ] && [ -n "$probe_b" ]; then
      read -r pc1 pt1 pm1 ptrain <<<"$probe_a"
      read -r pc2 pt2 _   _      <<<"$probe_b"
      if [ "$pc2" -gt "$pc1" ] && [ "$pt2" -gt "$pt1" ]; then
        kv_bytes_per_token=$(awk -v a="$pt1" -v b="$pt2" -v c="$pc1" -v d="$pc2" \
          'BEGIN{ printf "%.0f", (b-a)*1048576/(d-c) }')
        fixed_mb=$(awk -v a="$pt1" -v c="$pc1" -v bpt="$kv_bytes_per_token" \
          'BEGIN{ f = a - bpt*c/1048576; if (f < 0) f = 0; printf "%.0f", f }')
        probe_model_mb="$pm1"
        n_ctx_train="${ptrain:-0}"
        kv_probe_ok=1
      fi
    fi
  fi

  if [ "$fit_ok" -eq 1 ] || [ "$kv_probe_ok" -eq 1 ]; then
    rm -rf "$probe_tmp"
  else
    echo "⚠️  측정도 실패했습니다. 옛 상수로 폴백합니다 (컨텍스트를 크게 과소평가합니다)."
    echo "    측정 로그: $probe_tmp"
  fi
else
  echo "컨텍스트 계산을 건너뜁니다 (SKIP_CTX_PROBE=1 이거나 바이너리/모델 경로 없음)."
  echo "옛 상수로 추정합니다."
fi

if [ "$fit_ok" -eq 1 ]; then
  :   # largest_ctx 는 위에서 정해졌다.
elif [ "$kv_probe_ok" -eq 1 ]; then
  # 모델 가중치는 파일 크기가 아니라 llama.cpp 가 보고한 적재량을 쓴다.
  # (쓰이지 않는 텐서는 로드되지 않는다. Qwen3.8: 파일 21392 → 21049 MiB.
  #  반대로 Gemma4 Q8_K_P 는 파일 26013 → 26745 MiB 로 더 크다.)
  proj_est_mb=$(awk -v p="$proj_mb" 'BEGIN{ printf "%.0f", p*1.02 }')
  mtp_est_mb=$(awk -v x="$mtp_mb" 'BEGIN{ printf "%.0f", x*1.02 }')
  ctx_pool_mb=$(awk -v v="$vram_mb" -v m="$probe_model_mb" -v p="$proj_est_mb" \
                    -v x="$mtp_est_mb" -v f="$fixed_mb" -v r="$reserved_mb" \
    'BEGIN{ a = v - m - p - x - f - r; if (a < 0) a = 0; printf "%.0f", a*0.95 }')
  largest_ctx=$(awk -v pool="$ctx_pool_mb" -v bpt="$kv_bytes_per_token" \
    'BEGIN{ n = int(pool*1048576/bpt); n = int(n/256)*256; if (n < 1024) n = 1024; print n }')

  echo "컨텍스트 예산 (CPU 드라이런 측정값, MiB):"
  echo "  GPU 여유 VRAM            : ${vram_mb}"
  echo "  − 모델 가중치            : ${probe_model_mb}   (파일 ${model_mb})"
  if [ "$proj_mb" -gt 0 ]; then
    echo "  − 프로젝션(mmproj)       : ${proj_est_mb}   (파일 ${proj_mb} × 1.02)"
  fi
  if [ "$mtp_mb" -gt 0 ]; then
    echo "  − MTP 드래프트           : ${mtp_est_mb}   (파일 ${mtp_mb} × 1.02)"
  fi
  echo "  − 고정 오버헤드          : ${fixed_mb}   (RS/SWA 캐시 + 연산 버퍼 고정분)"
  echo "  − 예비                   : ${reserved_mb} + 남은 양의 5%"
  echo "  = 컨텍스트에 쓸 수 있는 양: ${ctx_pool_mb}"
  echo "  토큰당 비용              : ${kv_bytes_per_token} B  ($(awk -v b="$kv_bytes_per_token" 'BEGIN{printf "%.1f", 1048576/b}') tokens/MiB)"
  echo "  ※ GPU 쪽 연산 버퍼는 이보다 큽니다. 여유가 빠듯하면 -c 를 직접 낮춰 주세요."
  if [ "${vram_mb:-0}" -le 0 ]; then
    # VRAM 감지 실패. 측정값은 맞지만 나눌 예산을 모르므로 옛 기본값으로 돌아간다.
    largest_ctx=8192
    echo "GPU 여유 VRAM 을 감지하지 못해 예산을 계산할 수 없습니다 → 기본 ${largest_ctx} 토큰."
  elif [ "$ctx_pool_mb" -le 0 ]; then
    echo "⚠️  모델(+프로젝션+오버헤드)만으로 여유 VRAM 을 다 씁니다. 이대로면 로드에 실패하거나"
    echo "    일부 층이 CPU 로 밀립니다. 더 작은 양자화를 쓰거나 -ngl 을 낮추세요."
  fi
else
  # 폴백: 모델 구조를 보지 않는 옛 상수. 대체로 크게 과대평가한다(= 컨텍스트 손해).
  #   q4_0 ≈ 0.5625 B/원소 → 약 16 tokens/MB
  #   q8_0 ≈ 1.0625 B/원소 → 약 8.5 tokens/MB
  #   f16  = 2.0    B/원소 → 약 4.5 tokens/MB
  case "$KV_TYPE" in
    f16|bf16|f32) tokens_per_mb=4.5 ;;
    q8_0)         tokens_per_mb=8.5 ;;
    *)            tokens_per_mb=16  ;;
  esac
  est_available_mb=$(awk -v v="$vram_mb" -v m="$model_mb" -v p="$proj_mb" -v x="$mtp_mb" \
                         -v r="$reserved_mb" \
    'BEGIN{ if (v <= 0) { print 0; exit } estm = m*1.02; estp = p*1.05; estx = x*1.02;
            a = v - estm - estp - estx - r; if (a < 0) a = 0; print a }')
  echo "모델(${model_mb}MB)+프로젝션(${proj_mb}MB)+MTP(${mtp_mb}MB)+예비(${reserved_mb}MB) 적재 후 예상 여유 VRAM: ${est_available_mb} MB"
  largest_ctx=$(awk -v a="$est_available_mb" -v t="$tokens_per_mb" \
    'BEGIN{ if (a <= 0) { print 8192; exit } d = int(a*t); if (d < 1024) d = 1024; print d }')
fi

# 학습 컨텍스트(n_ctx_train) 상한. 2순위 경로에서만 필요하다.
# (-fit 은 애초에 학습 컨텍스트를 넘겨 고르지 않는다.) 넘겨서 띄우는 것 자체는
# llama.cpp 가 허용하지만(RoPE 외삽) 품질 이득 없이 VRAM 만 먹는다. 그래도 필요하면
# 아래 프롬프트에 더 큰 값을 직접 넣으면 그대로 쓴다.
if [ "${n_ctx_train:-0}" -gt 0 ] && [ "$largest_ctx" -gt "$n_ctx_train" ]; then
  echo "VRAM 으로는 ${largest_ctx} 토큰까지 가능하지만 학습 컨텍스트 ${n_ctx_train} 으로 제한합니다."
  largest_ctx=$n_ctx_train
fi

# 자동 계산값 상한. 위에서 Vulkan 이면 KV 를 f16 으로 바꿔 성능 절벽 자체를 피했으므로
# (f16 은 ctx 32768/65536 에서도 70~71 t/s 로 평탄한 것을 확인) 백엔드별 상한은 두지 않는다.
# 필요하면 MAX_AUTO_CTX 로 직접 제한할 수 있다. 0 이면 제한 없음.
#
# 참고: 예전 주석에 "학습 컨텍스트는 보통 32768이라 넘겨도 잘린다"고 적었던 것은 오류였다.
# 모델마다 다르고(이 저장소의 35B 모델은 262,144), 실제로 capping 경고도 나지 않았다.
# 학습 컨텍스트 초과 여부는 llama.cpp 가 로드 시점에 스스로 판단해 경고/조정하므로
# 여기서 임의로 가정하지 않는다.
max_auto_ctx=${MAX_AUTO_CTX:-0}
if [ "$max_auto_ctx" -gt 0 ] && [ "$largest_ctx" -gt "$max_auto_ctx" ]; then
  echo "VRAM 기준 계산값 ${largest_ctx} 토큰 → MAX_AUTO_CTX 상한 ${max_auto_ctx} 으로 제한합니다."
  largest_ctx=$max_auto_ctx
fi

echo "Calculated largest context length: ${largest_ctx} tokens"

# [FIX 2026-08-21] 1순위(-fit)로 값을 얻었고 별도 상한도 없으면, Enter 시 -c 를 아예
# 넘기지 않는다. 같은 계산을 기동 시점에 llama.cpp 가 다시 하므로 값은 같고, 그 사이
# VRAM 사정이 바뀌었으면 llama.cpp 가 알아서 줄여서 뜬다(우리가 박아 넣으면 OOM 난다).
# 사용자가 숫자를 넣으면 그대로 -c 로 넘긴다 — 기존 동작 그대로다.
fit_delegate=0
if [ "$fit_ok" -eq 1 ] && [ "${max_auto_ctx:-0}" -eq 0 ]; then
  fit_delegate=1
  echo "Enter 를 누르면 -c 를 지정하지 않고 llama.cpp 의 -fit 에 맡깁니다 (위와 같은 값이 나오고,"
  echo "그 사이 VRAM 이 줄었으면 알아서 낮춰 뜹니다). 숫자를 넣으면 그 값을 그대로 씁니다."
else
  echo "Enter 를 누르면 -c ${largest_ctx} 로 띄웁니다."
fi
read -p "Enter desired context tokens (-c) [largest: ${largest_ctx}]: " user_c

C_ARGS=()
if [[ "$user_c" =~ ^[0-9]+$ ]] && [ "$user_c" -gt 0 ]; then
  c_opt="$user_c"
  C_ARGS=( -c "$c_opt" )
  echo "Using user-specified -c $c_opt"
elif [ "$fit_delegate" -eq 1 ]; then
  c_opt="$largest_ctx"          # 화면 표시용. 실제로는 -c 를 넘기지 않는다.
  echo "-c 를 넘기지 않고 llama.cpp 의 -fit 에 맡깁니다 (예상 ${c_opt} 토큰)."
else
  c_opt=${largest_ctx}
  C_ARGS=( -c "$c_opt" )
  echo "Empty or invalid input — falling back to -c $c_opt"
fi

# Start server
echo "Starting llama-server with model: $MODEL_PATH"
ARGS=( -m "$MODEL_PATH" )
if [ -n "$PROJ_PATH" ]; then
  ARGS+=( --mmproj "$PROJ_PATH" )
fi
ARGS+=( "${MTP_ARGS[@]}" )

# CHOSEN_DEVICE가 비어있으면(CPU-only 빌드, 또는 디바이스 자동감지 실패) --device를
# 아예 넘기지 않는다 — llama.cpp가 기본 동작(전체 디바이스 자동 사용 또는 CPU)에 위임.
if [ -n "$CHOSEN_DEVICE" ]; then
  ARGS+=( --device "$CHOSEN_DEVICE" )
fi

# Flash Attention(-fa) & Q4 KV cache applies
# --host 127.0.0.1: 로컬 전용 (외부 HTTP 차단 — 외부 접근은 Caddy HTTPS 사용)
ARGS+=( --port "$SERVER_PORT" --host 127.0.0.1 -ngl 99 "${C_ARGS[@]}" --parallel "$N_PARALLEL" -fa on -ctk "$KV_TYPE" -ctv "$KV_TYPE" --reasoning on --tools all --ui-mcp-proxy)
ARGS+=( --repeat-penalty 1.1 --presence-penalty 0.1 --frequency-penalty 0.1 --repeat-last-n 256 )

# ── 디스크 페이징 모드 (LAZY_MODE=auto|on|off) ──────────────────────────────
# llama.cpp 는 세 조건이 **모두** 맞을 때만 텐서를 파일에 남긴다:
#   ① 아키텍처가 그 텐서에 TENSOR_READ_LAZY 를 달았다 (qwen4exp 의 n-gram 테이블,
#      gemma3n/gemma4 의 per-layer 임베딩 등. 전부 GET_ROWS 색인 텐서다)
#   ② auto 면 그 텐서가 4 GiB 를 넘는다 (on 이면 크기 무시)
#   ③ mmap 을 쓸 수 있다
# 화이트리스트 방식이라 일반 dense 모델에서는 아무 일도 일어나지 않는다.
# 끄고 싶으면 LAZY_MODE=off — 단, 대상 텐서가 크면 그만큼 RAM/VRAM 을 더 쓴다.
case "$LAZY_MODE" in
  auto) : ;;   # llama.cpp 기본값 — 플래그를 넘기지 않는다
  on|off) ARGS+=( -lzm "$LAZY_MODE" ) ;;
esac

# ── 디스크 페이징 금지 플래그 가드 ──────────────────────────────────────────
# 일부 아키텍처(qwen4exp 의 n-gram 테이블 등)는 36 GiB 짜리 텐서를 **파일에 둔 채**
# 필요한 4 KB 행만 읽어 쓴다(llama.cpp 의 --lazy-mode, 기본값 auto).
# 아래 플래그들은 그 텐서를 통째로 메모리로 끌어올리므로, 30 GiB RAM 에서는 즉사한다.
# 이 스크립트가 직접 넣지는 않지만 EXTRA_ARGS 등으로 새어 들어올 수 있어 막는다.
for _bad in "${ARGS[@]}"; do
  case "$_bad" in
    --no-mmap|--mlock)
      echo "⛔ $_bad 는 쓸 수 없습니다 — 디스크 페이징이 죽고 큰 텐서를 RAM 으로 끌어올립니다."; exit 1 ;;
    --load-mode)
      echo "⛔ --load-mode 를 직접 지정하지 마세요 — mmap 이 아니면 페이징이 죽습니다."; exit 1 ;;
  esac
done

# [FIX] LD_LIBRARY_PATH는 여기, llama-server 프로세스 하나에만 적용한다(전역 export 아님).
LD_LIBRARY_PATH="${LLAMA_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}" \
  nohup "$SERVER_BIN" "${ARGS[@]}" > "$LOG_FILE" 2>&1 &
SERVER_PID=$!

echo "Llama-server started (PID $SERVER_PID) on port ${SERVER_PORT}"

# 디스크 페이징이 실제로 걸렸는지는 로그가 알려준다. 준비 완료 후 §아래에서 확인한다.
# (여기서 바로 보면 아직 안 찍혔을 수 있어 플래그만 세워 둔다.)
LAZY_EXPECTED=1
echo ""

# 서버가 준비/실패할 때까지 대기.
#   판단 기준(after 방식, 유지): 특정 로그 문구("all slots are idle")에 의존하면
#   llama.cpp 버전업 시 깨지므로, 공식 readiness 엔드포인트 /health 폴링으로 견고하게 판단한다.
#     /health → 준비 200{"status":"ok"} / 로딩 중 503 / 오류 500
#   추가 안전장치: (1) 서버 프로세스 사망 감지 (2) 로그 치명 오류 패턴 (3) 타임아웃.
#
#   화면 출력(before 방식, 복원): 점(.)만 찍는 대신 로그를 tail -f로 실시간 스트리밍해서
#   모델 로딩 중 실제로 무슨 일이 일어나고 있는지 그대로 볼 수 있게 한다.
#   판단 로직과는 완전히 분리되어 있어, 로그 문구가 바뀌어도 판단에는 영향이 없다.
HEALTH_URL="http://127.0.0.1:${SERVER_PORT}/health"
MAX_WAIT=${SERVER_START_TIMEOUT:-600}   # 초. 큰 모델 로딩 고려(기본 10분). 환경변수로 조정 가능.
FATAL_RE="symbol lookup error|GGML_ABORT|Killed|[Ss]egmentation fault|core dumped|failed to load model|error loading model|unable to load model"
READY=0
WAITED=0

echo "서버 준비 대기 중... (/health 폴링, 최대 ${MAX_WAIT}s, 아래는 실시간 로그)"
echo "──────────────────────────────────────────────"

# --pid 옵션: 서버 프로세스가 죽으면 tail도 자동 종료됨.
tail -f "$LOG_FILE" --pid="$SERVER_PID" &
TAIL_PID=$!
# 스크립트가 어떤 경로로 빠져나가든(타임아웃/에러/Ctrl-C) tail은 반드시 정리.
trap 'kill "$TAIL_PID" 2>/dev/null || true' EXIT

while [ "$WAITED" -lt "$MAX_WAIT" ]; do
  # (1) 서버 프로세스가 죽었으면 실패
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$TAIL_PID" 2>/dev/null || true
    sleep 0.3   # tail이 마지막 남은 로그 줄까지 다 찍고 끝나도록 잠깐 대기
    echo "──────────────────────────────────────────────"
    echo "Server process exited prematurely. See: $LOG_FILE"
    break
  fi
  # (2) /health 200 → 준비 완료
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null)" = "200" ]; then
    READY=1
    break
  fi
  # (3) 로그에 치명 오류 패턴 → 즉시 중단
  if tail -n 60 "$LOG_FILE" 2>/dev/null | grep -qE "$FATAL_RE"; then
    kill "$TAIL_PID" 2>/dev/null || true
    sleep 0.3
    echo "──────────────────────────────────────────────"
    echo "Server failed to start. See: $LOG_FILE"
    break
  fi
  sleep 2
  WAITED=$((WAITED + 2))
done

# 루프를 정상적으로 빠져나온 경우(READY=1 또는 타임아웃)에도 tail 정리
kill "$TAIL_PID" 2>/dev/null || true
trap - EXIT
echo "──────────────────────────────────────────────"
echo ""

if [ "$READY" -eq 1 ]; then
  echo "Server ready at http://127.0.0.1:${SERVER_PORT}  (PID $SERVER_PID)"

  # ── 디스크 페이징이 걸렸는지 ─────────────────────────────────────────────
  # 로그의 'lazy read enabled' 줄은 기본 상세도에서 안 찍히므로 그것에 의존하지 않는다.
  # 대신 **파일 크기와 VRAM 사용량의 차이**로 본다: 가중치를 다 올렸다면 둘이 비슷하고,
  # 큰 텐서를 파일에 남겼다면 그만큼 벌어진다.
  _vram_mib=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
  if [ -n "${_vram_mib:-}" ] && [ "$model_mb" -gt 0 ]; then
    _gap=$(( model_mb - _vram_mib ))
    printf '모델 파일     : %.1f GiB   ·   VRAM 사용 %.1f GiB\n' \
      "$(awk -v m="$model_mb" 'BEGIN{print m/1024}')" \
      "$(awk -v m="$_vram_mib" 'BEGIN{print m/1024}')"
    echo "페이징 모드   : --lazy-mode ${LAZY_MODE}  (LAZY_MODE 환경변수로 변경)"
    if [ "$_gap" -gt 4096 ]; then
      printf '디스크 페이징 : ● 차이 %.1f GiB 가 파일에 남아 필요한 행만 읽힙니다 (--lazy-mode auto)\n' \
        "$(awk -v g="$_gap" 'BEGIN{print g/1024}')"
      echo "                이 텐서들은 VRAM·RAM 을 쓰지 않습니다. 남는 RAM 이 자동으로 캐시가 됩니다."
    else
      echo "디스크 페이징 : ○ 가중치가 모두 적재됐습니다 (페이징 대상 텐서가 없는 모델이면 정상)"
    fi
  fi
  if rss_kb=$(awk '/^VmRSS:/{print $2}' "/proc/$SERVER_PID/status" 2>/dev/null); then
    printf '호스트 RSS    : %.1f GB   (페이지 캐시는 별도이며 메모리 압박 시 그냥 버려집니다)\n' \
      "$(awk -v k="$rss_kb" 'BEGIN{print k/1048576}')"
  fi
elif kill -0 "$SERVER_PID" 2>/dev/null && [ "$WAITED" -ge "$MAX_WAIT" ]; then
  echo "Timeout(${MAX_WAIT}s): 아직 준비되지 않았지만 서버는 계속 로딩 중일 수 있습니다."
  echo "  상태 확인: curl $HEALTH_URL   (준비되면 {\"status\":\"ok\"})"
  echo "  로그 계속 보기: tail -f $LOG_FILE"
fi