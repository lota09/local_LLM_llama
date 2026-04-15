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

echo "Searching for GGUF model files in '$MODEL_DIR'..."
mapfile -t GGUF_FILES < <(find "$MODEL_DIR" -maxdepth 1 -type f \( -iname "*.gguf" -o -iname "*.GGUF" \) | sort)
if [ ${#GGUF_FILES[@]} -eq 0 ]; then
  echo "No .gguf files found in $MODEL_DIR. Place model files there and re-run."
  exit 1
fi

echo "Select a model to run:"
PS3="Enter number (or Ctrl+C to cancel): "
select MODEL_PATH in "${GGUF_FILES[@]}"; do
  if [ -n "$MODEL_PATH" ]; then
    echo "Selected model: $MODEL_PATH"
    break
  else
    echo "Invalid selection.";
  fi
done

# Vision model projection selection
read -p "Is this a vision / multimodal model that requires a projection file? (y/N): " IS_VISION
IS_VISION=${IS_VISION:-N}
PROJ_PATH=""
if [[ "$IS_VISION" =~ ^[Yy]$ ]]; then
  echo "Searching for projection files (mmproj-*.gguf) in '$MODEL_DIR'..."
  mapfile -t PROJ_FILES < <(find "$MODEL_DIR" -maxdepth 1 -type f -iname "*mmproj-*.gguf" | sort)
  if [ ${#PROJ_FILES[@]} -eq 0 ]; then
    echo "No mmproj-*.gguf files found in $MODEL_DIR. You can add one or skip.";
    read -p "Proceed without projection file? (y/N): " SKIP_PROJ
    SKIP_PROJ=${SKIP_PROJ:-N}
    if [[ ! "$SKIP_PROJ" =~ ^[Yy]$ ]]; then
      echo "Aborting. Place projection files in $MODEL_DIR and re-run."; exit 1
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

LOG_FILE="llama_server.log"

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

# Heuristic to estimate recommended context (-c)
# We reserve a safety margin and estimate model/proj resident memory loosely.
reserved_mb=1500
# use float math via awk
est_available_mb=$(awk -v v="$vram_mb" -v m="$model_mb" -v p="$proj_mb" -v r="$reserved_mb" 'BEGIN{ if(v<=0){print 0; exit} estm=m*1.2; estp=p*1.1; a=v-estm-estp-r; if(a<0) a=0; print a }')
recommended_ctx=$(awk -v a="$est_available_mb" 'BEGIN{ d=int(a*4); if(d<1024) d=8192; if(d>16384) d=16384; print d }')

echo "Calculated recommended context length (heuristic): ${recommended_ctx} tokens"
echo "You may enter a desired -c value. If you enter an invalid value or press Enter, the script will use -c ${recommended_ctx} as fallback."
read -p "Enter desired context tokens (-c) [recommended ${recommended_ctx}]: " user_c

if [[ "$user_c" =~ ^[0-9]+$ ]] && [ "$user_c" -gt 0 ]; then
  c_opt="$user_c"
  echo "Using user-specified -c $c_opt"
else
  c_opt=${recommended_ctx}
  echo "Invalid or empty input — falling back to -c $c_opt"
fi

# Start server (preserve commented options as-is)
echo "Starting llama-server with model: $MODEL_PATH"
nohup ./llama_server/llama-server \
  -m "$MODEL_PATH" \
  --port 11436 \
  --host 0.0.0.0 \
  -ngl 99 \
  -c $c_opt \
  --reasoning on \
  > "$LOG_FILE" 2>&1 &

echo "Llama-server started on port 11436"
echo "Log file: $LOG_FILE"
echo "Check progress: tail -f $LOG_FILE"
