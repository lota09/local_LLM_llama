# Qwen3.8-Flash-Next 실행 — 진행 상황과 다음 명령

계획은 [`flash_next_plan.md`](flash_next_plan.md) 에 있다. 이 문서는 **지금 어디까지 왔고
다음에 무슨 명령을 치는가**만 다룬다. 측정값이 나오면 §6 에 덮어쓴다.

작업 디렉터리는 전부 아래 기준이다. 명령 블록에 `$WD` 로 나온다.

```bash
export WD=/home/lota/orca/workspaces/llamacpp/download-model-naming-2
cd "$WD"
```

> ⛔ `~/Developments/llamacpp` 가 아니다. 고친 `build_llama_server.sh`(인자 파서·BUILD_INFO·
> 실행 검증)는 이 워크트리에만 있다. 원본 체크아웃의 스크립트는 `--ref` 를 모른다.

## 0. 게이트 현황 (2026-08-31 기준)

| | 게이트 | 상태 | 근거 |
|:---|:---|:---|:---|
| **G0** | 빌드 | ✅ **통과** | `strings libllama.so* \| grep -x qwen4exp` → `qwen4exp` · `cuobjdump` → `sm_80` |
| **G1** | 다운로드 | ⬜ 미착수 | `models/` 비어 있음(0 B). 디스크 여유 571 GB |
| **G2** | 로딩 | ⬜ | G1 이후 |
| **G3** | 정합성 | ⬜ | |
| **G4** | 디코드 ≥25 tok/s | ⬜ | |
| **G5** | 콜드/웜 격차 <2배 | ⬜ | |

**지금 막고 있는 것 3개** — 전부 §2 에서 처리한다.

| | 현재 | 필요 |
|:---|:---|:---|
| vLLM 이 VRAM 점유 | pid **550998** · **51,528 MiB** / 65,536 | 내려야 함 |
| `vm.swappiness` | **60** | 10 |
| 호스트 RAM 여유 | **10 GiB** (vLLM 이 물고 있음) | vLLM 내리면 ~26 GiB |

## 1. 빌드 결과 — 실측

```
설치 위치   llama_server_cuda_b10717/
ref         b10717            (--ref 로 지정)
커밋        a32af33de2b5950e701578dc23a229e8e2c727b9   (2026-08-31T13:33:02+03:00)
버전        0.3.0-dev (build 1, commit a32af33)
백엔드      CUDA · 실측 sm_80 (단독)
툴체인      nvcc 13.3 (miniconda) · gcc 15.2 · cmake 4.3.1
```

`--gpu-arch` 없이 빌드했고 llama.cpp 의 `GGML_NATIVE` 자동감지가 `sm_80` 을 정확히
골랐다. 그래서 디렉터리 이름에 `-sm80` 이 없다(접미사는 명시 지정했을 때만 붙는다).

전체 내역은 `llama_server_cuda_b10717/BUILD_INFO` 에 있다. §6 기록에 그대로 옮기면 된다.

기존 `llama_server_cuda/`(v0.2.0-dev · bb4caa7 · 8월 23일)는 그대로 살아 있다. 두 빌드를
나란히 두고 비교할 수 있다.

### G0 재확인 명령

```bash
strings "$WD"/llama_server_cuda_b10717/libllama.so* | grep -x qwen4exp
cat "$WD"/llama_server_cuda_b10717/BUILD_INFO
```

⚠️ **`llama-server` 를 grep 하면 안 된다.** 그 실행파일은 `main.cpp` 하나뿐인 17 KB 런처이고
아키텍처 이름표는 `libllama.so` 에 있다. 정상 빌드에서도 0건이 나온다.

## 2. 다음 단계 — 사전 조치

```bash
# (1) vLLM 종료 — VRAM 51.5 GiB + 호스트 RAM 을 동시에 돌려받는다
kill 550998
sleep 5 && nvidia-smi --query-gpu=memory.used,memory.total --format=csv

# (2) mmap clean page 를 먼저 버리도록. 익명 메모리를 스왑으로 미는 걸 억제한다
sudo sysctl vm.swappiness=10

# (3) 확인 — VRAM 이 거의 0, 사용 가능 RAM 26 GiB 근처여야 한다
free -g && swapon --show
```

PLE 테이블은 mmap 파일 백드라 메모리 압박 시 **그냥 버려진다**(clean page, 쓰기 0).
익명 메모리였다면 스왑에 써야 하고 그건 4 KB 랜덤 25 MB/s 다. swappiness 를 낮추는 이유가
이것이다.

## 3. G1 — 다운로드

3.84bpw 를 **먼저** 받는다(84.9 GB). 경로 검증용이고, 통과하면 4.27bpw(92.9 GB)로 올린다.
둘 다 받아도 178 GB 라 571 GB 안에 들어간다.

```bash
cd "$WD"
bash download_model.sh https://huggingface.co/AtomicChat/Qwen3.8-Flash-Next-GGUF
```

대화형으로 **빌드**를 고른다 → **`AD-3.84bpw-IQ4_XS-M64`** (샤드 28개 · 79.1 GiB).

이 저장소는 한 파일이 아니라 양자화별 디렉터리에 샤드 28~33개로 나뉘어 있다.
`download_model.py` 는 그걸 묶음 하나로 보여주고 28개를 4개씩 동시에 받는다
(전체 % · ETA 한 줄 + 진행 중인 것만 표시). 파일 이름은
`AtomicChat_…-M64-00001-of-00028.gguf` 처럼 **번호 접미사를 그대로** 유지한다.

| | |
|:---|:---|
| 통과 | 샤드 28개 전부 · 각 sha256 일치 |
| 중단됐다면 | 같은 명령 재실행 — 받다 만 샤드부터 이어받고 다 받은 샤드는 건너뛴다 |
| 검증 다시 | `VERIFY_ALL=1 bash download_model.sh <URL>` |

받은 뒤 경로를 잡아 둔다 — **첫 샤드**만 지목한다:

```bash
export M=$(ls "$WD"/models/*3.84bpw*/*-00001-of-*.gguf | head -1)
echo "$M"
```

⛔ 샤드 파일 이름을 바꾸지 마라. llama.cpp 는 첫 샤드만 받고 나머지를 이름에서
계산해 찾는다(`llama_split_prefix`). `<이름>.gguf` 로 합쳐 두면
`invalid split file name` 으로 죽는다.

## 4. G2 — 로딩

### ⛔ `run_llama_server.sh` 를 쓰지 않는다

`-ot` 를 넘길 통로가 없다(`:19-38` 파서가 `--port`·`--backend` 만 읽고 나머지를 버린다).
게다가 컨텍스트 자동 계산(`-fit` 프로브, `:645`)이 `-ot` 없이 도는 탓에 **PLE 테이블
39 GB 까지 VRAM 에 올릴 것으로 계산**해 엉뚱한 `-c` 를 고른다. G3 통과 후 인자 통과
경로를 뚫고 나서 재탕한다(§7).

### 기동

```bash
cd "$WD"
D=llama_server_cuda_b10717
LD_LIBRARY_PATH="$WD/$D" "$D/llama-server" \
  -m "$M" \
  -ngl 99 \
  -ot "per_layer_token_embd.weight=CPU" \
  -c 32768 \
  --jinja \
  --host 127.0.0.1 --port 8080
```

| 플래그 | 왜 |
|:---|:---|
| `-ngl 99` | 전문가·어텐션·GDN 전부 VRAM |
| `-ot "per_layer_token_embd.weight=CPU"` | **PLE 테이블만** CPU 쪽에. 이것 하나가 전체 계획이다 |
| `-c 32768` | 1차 게이트값. M4 에서 올린다 |

**금지:** `--no-mmap` · `--load-mode none` · `--mlock`.
전부 39 GB 를 RAM 으로 끌어올려 OOM 을 만든다.

### ⚠ `-ot` 는 이 테이블에 안 걸린다 — 소스 확인함

b10717 의 llama.cpp 에는 **이 용도의 전용 경로**가 이미 있다.
`qwen4exp.cpp:139` 이 PLE 테이블을 `TENSOR_READ_LAZY` 로 만들고,
`llama-model-loader.h:72` 가 그것을 "read rows on demand instead of loading whole
tensor" 로 정의한다. 켜는 스위치는 `-lzm/--lazy-mode` 이고 **기본값 `auto` 가
4 GiB 넘는 그런 텐서를 자동으로 잡는다** — 38.4 GB 테이블은 당연히 걸린다.

그리고 `llama-model-loader.cpp:1204` 의 `if (is_lazy) return lazy_read::buft();` 는
**`-ot` 를 보는 1228줄보다 앞에서 빠져나간다.** 즉 `-ot
"per_layer_token_embd.weight=CPU"` 는 이 텐서에 대해 **아무 일도 하지 않는다**
(해롭지도 않다 — 어차피 CPU buft 로 간다). AtomicChat 문서의
"No `--override-tensor` is needed, the table goes to the host by itself" 가 이것이다.

→ 첫 기동은 `-ot` 없이 하고, 로그에서 이 줄을 확인한다:

```
tensor per_layer_token_embd.weight (size = 36621 MiB) lazy read enabled
```

안 뜨면 그때 `-lzm on` 을 명시한다. 또 AtomicChat 은 `-fit off` 를 요구한다
(자동 파라미터 피팅이 이 아키텍처를 잘못 재서 할당에 실패한다) — G2 가 이상하면
여기부터 의심한다.

### 다른 터미널에서 게이트 감시

```bash
watch -n2 'nvidia-smi --query-gpu=memory.used --format=csv,noheader; \
           ps -o rss= -C llama-server | awk "{printf \"RSS %.1f GB\n\", \$1/1048576}"; \
           free -g | sed -n 2p'
```

| | 통과 | 실패 시 |
|:---|:---|:---|
| VRAM | ≈ **46 GiB** | 60 GiB 초과 → `-ot` 정규식 오타. 테이블이 GPU 로 갔다 |
| 호스트 RSS | **< 40 GB** | 초과 → mmap 미적용. 금지 플래그 확인 |
| 서버 | `/health` 200 | — |

```bash
curl -s localhost:8080/health     # {"status":"ok"} 면 ready
```

## 5. G3 → G5

### G3 정합성

```bash
curl -s localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"한국어로 자기소개를 세 문장으로 해줘."}],
       "max_tokens":128}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"])'
```

반복·깨짐 없이 말이 되면 통과. 깨지면 **IQ4_XS 의 CUDA 경로 의심** → 4.27bpw Q4_K_M 으로 교체.

### G4 디코드 속도 — 기준 ≥ 25 tok/s

벤치 도구는 이 저장소가 아니라 **`/home/lota/Developments/vllm/bench/`** 에 있다.
`VLLM_URL` 로 llama-server 를 가리킨다.

```bash
cd /home/lota/Developments/vllm/bench
VLLM_URL=http://127.0.0.1:8080 python3 bench_manga.py --levels 1,4,16 --label flashnext-3.84
```

밴드는 25~80 tok/s. **아래로 떨어지면 원인은 대역폭이 아니라 PLE 게더 동기화다** — G5 로 간다.

### G5 콜드/웜 격차 — 기준 < 2배

```bash
# 웜: 5분 warm-up 후 측정
VLLM_URL=http://127.0.0.1:8080 python3 bench_manga.py --levels 1 --label warm

# 콜드: 서버 내리고 캐시 비운 뒤 재기동
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
```

### M5 — PLE 페이지 캐시 히트율 (이 계획의 핵심 미지수)

```bash
R0=$(awk '{print $3}' /sys/block/nvme0n1/stat)     # 추론 전 (읽은 섹터)
# … 추론 N 토큰 실행 …
R1=$(awk '{print $3}' /sys/block/nvme0n1/stat)
# 읽은 바이트 = (R1-R0)*512,  이론 최대 = N × 2.7 KB
# 히트율 = 1 − 읽은바이트 / (N × 2764)
```

⚠️ 측정 직전에 다른 GGUF 를 건드리지 마라. `run_llama_server.sh` 는 MTP 탐지로 GGUF 앞
**64 MB 를 읽으므로**(`:428`) 기준선을 오염시킨다.

## 6. 측정 기록

측정할 때마다 아래를 채운다. 조건을 같이 안 적으면 나중에 비교가 안 된다.

```
날짜        2026-__-__
빌드        llama.cpp a32af33 · CUDA 13.3 · sm_80        ← BUILD_INFO 에서 복사
모델        AD-_.__bpw-____  (파일 __._ GB)
플래그      -ngl 99 -ot "per_layer_token_embd.weight=CPU" -c _____
전력캡      ___ W   ·   SM ____ MHz   ·   코어 __°C / HBM __°C
캐시 상태   콜드 / 웜(__분)
VRAM        __._ GiB / 64.0     호스트 RSS __._ GB     스왑 __._ GB
결과        프리필 ___._ tok/s   디코드 __._ tok/s   TTFT ___ ms
디스크      읽기 __._ GB   쓰기 __._ GB   (토큰당 ___ KB)
```

## 7. 알아 둘 것

### patchelf 가 없다 — 다음 빌드 전에 깔아라

두 설치본 모두 `RUNPATH` 가 `/tmp/llama_build/build/bin` 을 가리킨다. 지금은 필요한 `.so`
가 전부 설치 디렉터리에 있어서 **무해하다**(확인함: 빌드트리 참조 0건). 다만 설치본에서
`.so` 하나라도 없어지면 조용히 빌드 트리 쪽을 집어 `undefined symbol` 로 죽는다 —
빌드 트리는 다음 빌드 때 갈아엎히므로 엉뚱한 판본이 섞인다.

```bash
sudo apt install patchelf      # 커널/nvidia-* 가 아니므로 언락에 무관, 안전
```

깔아 두면 `build_llama_server.sh` 가 `RUNPATH` 를 `$ORIGIN` 으로 바꿔 설치본을 자립시킨다.

### `run_llama_server.sh` 재탕 — G3 통과 후

블로커는 **`-ot` 통과 경로 하나**뿐이다. 최소 변경 두 줄:

1. `--` 뒤 인자를 `EXTRA_ARGS` 로 받아 `ARGS` **맨 뒤**에 붙인다(뒤가 이긴다).
2. **같은 `EXTRA_ARGS` 를 `probe_fit`(`:645`)에도 넘긴다.**

2번이 진짜 이득이다. `-ot` 가 들어간 채로 `-fit` 이 돌면 §8 **M4(KV 한계 컨텍스트)를
`-c` 를 올려가며 OOM 을 때려 찾을 필요가 없어진다** — llama.cpp 가 직접 답한다.

그 밖에 환경변수로 끌 수 있는 것: `SKIP_CTX_PROBE=1` · `KV_TYPE=f16` · `MTP=0`.
못 끄는 것: `-fa on` · 샘플링 페널티 4종 · `pkill -9 -f llama-server`.

### 재빌드가 필요할 때

```bash
cd "$WD"
./build_llama_server.sh --ref <REF>              # 예: --ref master, --ref b10800
./build_llama_server.sh --help                   # 옵션 전체
```

설치 위치는 `llama_server_cuda_<ref>` 로 갈리므로 기존 빌드를 덮어쓰지 않는다.
백엔드 선택 프롬프트는 Enter(기본값 CUDA)로 넘긴다.

## 8. 문서 링크 주의

[`flash_next_plan.md`](flash_next_plan.md) 안의 `hardware.md` · `performance.md` ·
`quantization.md` 링크는 이 저장소에 없다. 실제 위치:

| 참조 | 실제 경로 |
|:---|:---|
| `hardware.md` · `performance.md` | `/home/lota/Developments/vllm/docs/` |
| `bench_manga.py` · `bench_decode_pl.py` · `bench_accuracy.py` | `/home/lota/Developments/vllm/bench/` |
