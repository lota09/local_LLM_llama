# 새로운 모델 추가 및 실행 가이드

간단히: 모델 파일을 `models/`에 넣고 기존 실행 스크립트를 복사하거나 `MODEL_PATH`를 변경한 뒤 `llama-server`를 실행하면 됩니다.

**사전조건**
- `llama_server/llama-server` 실행 파일과 함께 필요한 라이브러리들이 있어야 합니다.
- `LD_LIBRARY_PATH`에 사용하는 Python 환경의 라이브러리 경로와 `./llama_server`가 포함되어야 합니다.
- GPU 사용 시 `CUDA_VISIBLE_DEVICES`를 설정하세요.

1) 모델 파일 준비
- 모델 파일 형식: 일반적으로 `.gguf` 또는 양자화된 `.q4_k_m.gguf` 같은 확장자를 사용합니다.
- 모델 파일을 저장소의 `models/` 폴더로 복사합니다.

예:

```bash
cp /path/to/your_model.gguf models/
ls -lh models/
```

2) 실행 스크립트 만들기 또는 기존 스크립트 수정
- 기존 스크립트(`run_huihui_35b.sh`, `run_claude_distill_35b.sh`, `run_omnicoder_9b.sh`)는 `MODEL_PATH` 변수를 사용합니다. 새 모델에 맞게 이 변수를 변경하거나 새 스크립트를 만드세요.

템플릿 스크립트 (새 파일 `run_my_model.sh`로 저장):

```bash
#!/bin/bash
cd "$(dirname "$0")"
export LD_LIBRARY_PATH=/users/lota7574/miniconda3/envs/llama_env/lib:./llama_server:$LD_LIBRARY_PATH
export CUDA_VISIBLE_DEVICES=0

pkill -9 -f llama-server || true
sleep 1

MODEL_PATH="models/your_model.gguf"
LOG_FILE="my_model.log"

nohup ./llama_server/llama-server \
  -m "$MODEL_PATH" \
  --port 11436 \
  --host 0.0.0.0 \
  -ngl 99 \
  -c 8192 \
  --reasoning on \
  > "$LOG_FILE" 2>&1 &

echo "Llama-server started on port 11436"
echo "Log file: $LOG_FILE"
echo "Check progress: tail -f $LOG_FILE"
```

설정 포인트:
- `-c` : 컨텍스트 길이 (ex. 8192, 16384)
- `--temp`, `--top-p`, `--repeat-penalty` 등 샘플링 파라미터를 모델 특성에 맞게 조정
- `--reasoning on` 같은 옵션은 모델/빌드에 따라 다르게 동작할 수 있음

3) 실행 및 확인

```bash
chmod +x run_my_model.sh
./run_my_model.sh
tail -f my_model.log
ps aux | grep llama-server
```

4) 문제 해결 팁
- 서버가 시작되지 않거나 라이브러리 오류가 나면 `LD_LIBRARY_PATH`가 올바른지 확인하세요.
- VRAM 부족: 더 낮은 정밀도(예: q4 계열) 모델을 사용하거나 컨텍스트(`-c`)를 줄이세요.
- 파일 권한 문제: `chmod +x llama_server/llama-server`
- 포트 충돌: 다른 프로세스가 같은 포트를 사용하면 `--port` 값을 변경하세요.

5) 권장 워크플로
- 새 모델을 추가할 때는 `models/`에 파일 복사 → `run_<name>.sh` 템플릿 복사 및 `MODEL_PATH` 수정 → 실행 및 로그 확인.

참고 파일
- `run_huihui_35b.sh` — 예제: [run_huihui_35b.sh](../run_huihui_35b.sh)
- `run_claude_distill_35b.sh` — 예제: [run_claude_distill_35b.sh](../run_claude_distill_35b.sh)
- `run_omnicoder_9b.sh` — 예제: [run_omnicoder_9b.sh](../run_omnicoder_9b.sh)

---
빠른 체크리스트:
- 모델 파일을 `models/`에 넣었는가?
- `LD_LIBRARY_PATH`와 `CUDA_VISIBLE_DEVICES`가 올바른가?
- 로그 파일을 확인하며 서버가 정상 기동했는가?

---

## 비전(Vision) 모델 사용 안내

일부 모델 패키지에는 이미지 입력을 처리하는 비전 모델이 포함됩니다. 예시 파일명:

- `mmproj-BF16.gguf`
- `mmproj-F16.gguf`
- `mmproj-F32.gguf`

간단한 사용 플로우는 일반 텍스트 모델과 동일합니다: 파일을 `models/`에 넣고 `MODEL_PATH`에 경로를 지정해 서버를 기동합니다. 다만 다음 사항을 참고하세요.

1) 정밀도(Precision) 선택
- `BF16`: 최신 데이터센터 GPU(A100/H100 등)에서 성능과 메모리 효율이 좋습니다. 가능한 경우 우선 권장합니다.
- `F16` (FP16): 일반적인 GPU에서 빠르게 동작하며 VRAM 절약에 효과적입니다.
- `F32` (FP32): 최대 정밀도(주로 CPU 실행 또는 디버깅용) — VRAM/메모리 요구량이 큽니다.

2) 실행 시 주의점
- 비전 모델은 텍스트 전용 모델보다 메모리를 더 요구할 수 있으니 `-c`(context) 값을 낮추거나 적절한 정밀도 파일을 선택하세요.
- GPU에서 `BF16`을 사용하려면 드라이버/런타임이 bfloat16을 지원해야 합니다.

3) 입력(이미지) 전송 방식
- `llama-server`가 멀티모달(이미지 입력) API를 제공하는 경우, 통상적으로 HTTP 엔드포인트에 multipart/form-data 또는 JSON으로 이미지(또는 base64)를 전달합니다. 서버가 지원하는 정확한 엔드포인트/필드명은 서버 빌드문서나 실행 바이너리의 도움말을 확인하세요.

예시: (서버가 JSON `image` 필드로 base64 이미지를 받는 경우)

```bash
# 이미지 파일을 base64로 인코딩해서 POST (예시)
IMG_B64=$(base64 -w0 path/to/image.jpg)
curl -X POST http://localhost:11436/generate \
  -H "Content-Type: application/json" \
  -d '{"image":"'$IMG_B64'","prompt":"Describe the image"}'
```

간단한 Python 예제 (서버가 base64-이미지 JSON을 받는다고 가정):

```python
import requests, base64

with open('path/to/image.jpg','rb') as f:
    b64 = base64.b64encode(f.read()).decode('ascii')

payload = {'image': b64, 'prompt': 'Describe the image'}
resp = requests.post('http://localhost:11436/generate', json=payload)
print(resp.json())
```

주의: 위 엔드포인트와 필드명(`/generate`, `image`)은 예시입니다. 실제 사용법은 `llama-server` 바이너리나 배포판의 문서를 확인하세요.

4) 권장 워크플로
- 모델 파일을 `models/`로 복사 → `run_my_model.sh` 템플릿 복사 및 `MODEL_PATH`를 `models/mmproj-...gguf`로 설정 → 서버 기동 → 서버 문서에 따라 이미지 전송 및 응답 확인.

5) 문제 해결 팁 (비전 모델 관련)
- 이미지 입력 시 에러가 발생하면 입력 포맷(base64 vs multipart), 필드명, 최대 이미지 크기 제한을 확인하세요.
- GPU 메모리 부족 시 `BF16` 대신 `F16`을 시도하거나 해상도를 낮춘 이미지를 사용하세요.

문서 끝.

