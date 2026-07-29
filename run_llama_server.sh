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
  esac
  _i=$(( _i + 1 ))
done
echo "llama-server 포트: ${SERVER_PORT}  (변경: ./run_llama_server.sh --port 1234)"

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
LLAMA_LD_LIBRARY_PATH="$(pwd)/llama_server"

# 기존 프로세스 종료
pkill -9 -f llama-server || true
sleep 1

SERVER_BIN="./llama_server/llama-server"

# ─── 라이브러리 사전 점검 + 손상 시 백업에서 자동복구 ─────────────────────────
# 모델 선택 프롬프트까지 다 진행한 뒤에야 라이브러리 깨진 걸 발견하는 걸 방지하기
# 위해 시작하자마자 확인한다. build_llama_server.sh는 설치할 때마다 기존
# llama_server/를 "llama_server_backup_<epoch>/"로 백업해 두므로, 디스크 캐시 유실·
# 강제 재부팅·안티바이러스 격리 등으로 바이너리/라이브러리가 손상됐을 때 무조건
# "다시 빌드하세요"(5~10분 이상)로 끝내지 않고, 가장 최근 백업으로부터 복구를 먼저 시도한다.
_find_latest_llama_server_backup() {
  ls -d llama_server_backup_*/ 2>/dev/null \
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
    mkdir -p ./llama_server
    cp -a "$BACKUP_DIR_FOUND"/. ./llama_server/ 2>/dev/null || true
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

# Auto-detect mmproj and model inside the chosen directory
mapfile -t ALL_GGUF < <(find "$TARGET_DIR" -maxdepth 1 -type f -iname "*.gguf" | sort)
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
  # model candidates are gguf files excluding mmproj
  model_tmp=()
  for f in "${ALL_GGUF[@]}"; do
    if ! printf '%s\n' "${PROJ_CANDS[@]}" | grep -qx "${f}" 2>/dev/null; then
      model_tmp+=("$f")
    fi
  done
  mapfile -t MODEL_CANDS < <(printf '%s\n' "${model_tmp[@]}" )

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
  mapfile -t PROJ_FILES < <(find "$TARGET_DIR" -maxdepth 1 -type f -iname "*mmproj-*.gguf" | sort)
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

LOG_FILE="logs/llama_server.log"

mkdir -p "$(dirname "$LOG_FILE")"

# Measure file sizes (bytes)
model_bytes=0
proj_bytes=0
if [ -f "$MODEL_PATH" ]; then
  model_bytes=$(stat -c%s "$MODEL_PATH" 2>/dev/null || stat -f%z "$MODEL_PATH" 2>/dev/null || echo 0)
fi
if [ -n "$PROJ_PATH" ] && [ -f "$PROJ_PATH" ]; then
  proj_bytes=$(stat -c%s "$PROJ_PATH" 2>/dev/null || stat -f%z "$PROJ_PATH" 2>/dev/null || echo 0)
fi

model_mb=$(( (model_bytes + 1024*1024 - 1) / (1024*1024) ))
proj_mb=$(( (proj_bytes + 1024*1024 - 1) / (1024*1024) ))

echo "Model size: ${model_mb} MB"
if [ $proj_mb -gt 0 ]; then
  echo "Projection size: ${proj_mb} MB"
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

# Optimized Heuristic based on empirical VRAM measurements
# 1. OS VRAM usage is ~10MB. We reserve 300MB as a safe buffer for context spikes.
reserved_mb=300

# 2. estm=m*1.02 : Actual VRAM usage (5420MB) is less than file size (6033MB).
# We use 1.02 (2% overhead) instead of 1.2 to reclaim ~1.8GB of VRAM.
est_available_mb=$(awk -v v="$vram_mb" -v m="$model_mb" -v p="$proj_mb" -v r="$reserved_mb" 'BEGIN{ if(v<=0){print 0; exit} estm=m*1.02; estp=p*1.05; a=v-estm-estp-r; if(a<0) a=0; print a }')
echo "모델(${model_mb}MB)+프로젝션(${proj_mb}MB)+예비(${reserved_mb}MB) 적재 후 예상 여유 VRAM: ${est_available_mb} MB"

# largest_ctx: scale available MB -> tokens (with Q4 KV cache = ~16 tokens/MB)
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
#   - f16 대비 VRAM 절반 → 더 긴 컨텍스트를 담을 수 있다
#     (이 저장소의 35B 모델 기준 여유 VRAM 11.5GB 에서 f16 은 140K 토큰이 한계지만
#      q8_0 은 264K 로 모델의 학습 컨텍스트 262K 를 전부 담는다)
#   - q4_0 대비 양자화 손실이 작다
# 다른 값이 필요하면 KV_TYPE 환경변수로 바꾼다 (예: KV_TYPE=f16 ./run_llama_server.sh).
KV_TYPE=${KV_TYPE:-q8_0}
echo "KV 캐시 타입: ${KV_TYPE}  (백엔드=${CHOSEN_DEVICE:-CPU}, KV_TYPE 환경변수로 변경 가능)"

if [[ "${CHOSEN_DEVICE}" == Vulkan* ]] && [[ "$KV_TYPE" == q4_* || "$KV_TYPE" == q5_* || "$KV_TYPE" == iq4_* ]]; then
  echo "⚠️  Vulkan 백엔드 + ${KV_TYPE} 조합은 컨텍스트 20480 이상에서 생성 속도가"
  echo "    8.9 t/s 수준으로 붕괴하는 것이 실측되었습니다 (q8_0 은 70 t/s)."
fi

# 토큰당 KV 바이트가 타입에 따라 다르므로 컨텍스트 추정 계수도 함께 바꾼다.
#   q4_0 ≈ 0.5625 B/원소 → 경험적으로 약 16 tokens/MB 기준
#   q8_0 ≈ 1.0625 B/원소 → 약 8.5 tokens/MB
#   f16  = 2.0    B/원소 → 약 4.5 tokens/MB
case "$KV_TYPE" in
  f16|bf16|f32) tokens_per_mb=4.5 ;;
  q8_0)         tokens_per_mb=8.5 ;;
  *)            tokens_per_mb=16  ;;
esac
largest_ctx=$(awk -v a="$est_available_mb" -v t="$tokens_per_mb" 'BEGIN{ if(a<=0){print 8192; exit} d=int(a*t); if(d<1024) d=1024; print d }')

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

echo "Calculated largest context length (Optimized Heuristic): ${largest_ctx} tokens"
echo "You may enter a desired -c value. If you enter an invalid value or press Enter, the script will use -c ${largest_ctx} as fallback."
read -p "Enter desired context tokens (-c) [largest: ${largest_ctx}]: " user_c

if [[ "$user_c" =~ ^[0-9]+$ ]] && [ "$user_c" -gt 0 ]; then
  c_opt="$user_c"
  echo "Using user-specified -c $c_opt"
else
  c_opt=${largest_ctx}
  echo "Invalid or empty input — falling back to -c $c_opt"
fi

# Start server
echo "Starting llama-server with model: $MODEL_PATH"
ARGS=( -m "$MODEL_PATH" )
if [ -n "$PROJ_PATH" ]; then
  ARGS+=( --mmproj "$PROJ_PATH" )
fi

# CHOSEN_DEVICE가 비어있으면(CPU-only 빌드, 또는 디바이스 자동감지 실패) --device를
# 아예 넘기지 않는다 — llama.cpp가 기본 동작(전체 디바이스 자동 사용 또는 CPU)에 위임.
if [ -n "$CHOSEN_DEVICE" ]; then
  ARGS+=( --device "$CHOSEN_DEVICE" )
fi

# Flash Attention(-fa) & Q4 KV cache applies
# --host 127.0.0.1: 로컬 전용 (외부 HTTP 차단 — 외부 접근은 Caddy HTTPS 사용)
ARGS+=( --port "$SERVER_PORT" --host 127.0.0.1 -ngl 99 -c "$c_opt" -fa on -ctk "$KV_TYPE" -ctv "$KV_TYPE" --reasoning on --tools all --ui-mcp-proxy)
ARGS+=( --repeat-penalty 1.1 --presence-penalty 0.1 --frequency-penalty 0.1 --repeat-last-n 256 )

# [FIX] LD_LIBRARY_PATH는 여기, llama-server 프로세스 하나에만 적용한다(전역 export 아님).
LD_LIBRARY_PATH="${LLAMA_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}" \
  nohup "$SERVER_BIN" "${ARGS[@]}" > "$LOG_FILE" 2>&1 &
SERVER_PID=$!

echo "Llama-server started (PID $SERVER_PID) on port ${SERVER_PORT}"
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
elif kill -0 "$SERVER_PID" 2>/dev/null && [ "$WAITED" -ge "$MAX_WAIT" ]; then
  echo "Timeout(${MAX_WAIT}s): 아직 준비되지 않았지만 서버는 계속 로딩 중일 수 있습니다."
  echo "  상태 확인: curl $HEALTH_URL   (준비되면 {\"status\":\"ok\"})"
  echo "  로그 계속 보기: tail -f $LOG_FILE"
fi