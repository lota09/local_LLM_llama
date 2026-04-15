#!/bin/bash
# RTX 4060 Ti GPU 가속 실행 스크립트 (최종 안정화 버전)

# 스크립트 위치로 이동
cd "$(dirname "$0")"

# 라이브러리 경로 설정
export LD_LIBRARY_PATH=/users/lota7574/miniconda3/envs/llama_env/lib:./llama_server:$LD_LIBRARY_PATH
export CUDA_VISIBLE_DEVICES=0

# 기존 프로세스 종료
pkill -9 -f llama-server
sleep 1

MODEL_PATH="models/Qwen3.5-35B-A3B-Uncensored-HauhauCS-Aggressive-IQ2_M.gguf"
LOG_FILE="qwen_uncensored.log"

# 불필요한 추론(Thinking)을 줄이고 최적의 성능을 내는 설정
# 주석과 명령어를 확실히 분리하여 오류 방지
nohup ./llama_server/llama-server \
  -m "$MODEL_PATH" \
  --port 11436 \
  --host 0.0.0.0 \
  -ngl 99 \
  -c 8192 \
  #--temp 0.4 \
  #--top-p 0.9 \
  #--min-p 0.05 \
  --reasoning on \
  #--repeat-penalty 1.15 \
  #--presence-penalty 0.1 \
  #--frequency-penalty 0.1 \
  #--repeat-last-n 512 \
  > "$LOG_FILE" 2>&1 &

echo "Llama-server (GPU/CUDA) started on port 11436"
echo "Log file: $LOG_FILE"
echo "The service will remain active even after you logout."
echo "Check progress: tail -f $LOG_FILE"
