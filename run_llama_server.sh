#!/bin/bash
# RTX 4060 Ti GPU 가속 실행 스크립트 (대화형 선택 + 컨텍스트 계산 포함)

# 스크립트 위치로 이동
cd "$(dirname "$0")"

# 라이브러리 경로 설정
export LD_LIBRARY_PATH=/users/lota7574/miniconda3/envs/llama_env/lib:./llama_server:$LD_LIBRARY_PATH
export CUDA_VISIBLE_DEVICES=0

# 기존 프로세스 종료
pkill -9 -f llama-server || true
sleep 1

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

# Detect GPU VRAM (MB)
vram_mb=0
if command -v nvidia-smi >/dev/null 2>&1; then
  vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ')
  vram_mb=${vram_mb:-0}
fi
if [ -z "$vram_mb" ] || [ "$vram_mb" -eq 0 ]; then
  echo "Warning: Could not detect GPU VRAM via nvidia-smi. Will fall back to safe defaults.";
else
  echo "Detected GPU total VRAM: ${vram_mb} MB"
fi

# Optimized Heuristic based on empirical nvidia-smi data
# 1. OS VRAM usage is ~10MB. We reserve 300MB as a safe buffer for context spikes.
reserved_mb=300

# 2. estm=m*1.02 : Actual VRAM usage (5420MB) is less than file size (6033MB). 
# We use 1.02 (2% overhead) instead of 1.2 to reclaim ~1.8GB of VRAM.
est_available_mb=$(awk -v v="$vram_mb" -v m="$model_mb" -v p="$proj_mb" -v r="$reserved_mb" 'BEGIN{ if(v<=0){print 0; exit} estm=m*1.02; estp=p*1.05; a=v-estm-estp-r; if(a<0) a=0; print a }')

# largest_ctx: scale available MB -> tokens (with Q4 KV cache = ~16 tokens/MB)
largest_ctx=$(awk -v a="$est_available_mb" 'BEGIN{ if(a<=0){print 8192; exit} d=int(a*16); if(d<1024) d=1024; print d }')

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

# Flash Attention(-fa) & Q4 KV cache applies
ARGS+=( --port 11436 --host 0.0.0.0 -ngl 99 -c "$c_opt" -fa on -ctk q4_0 -ctv q4_0 --reasoning on )
ARGS+=( --repeat-penalty 1.1 --presence-penalty 0.1 --frequency-penalty 0.1 --repeat-last-n 256 )

nohup ./llama_server/llama-server "${ARGS[@]}" > "$LOG_FILE" 2>&1 &

echo "Llama-server started on port 11436"
echo "Log file: $LOG_FILE"
echo "Check progress: tail -f $LOG_FILE"
