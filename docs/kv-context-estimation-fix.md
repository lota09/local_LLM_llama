# run_llama_server.sh 의 컨텍스트 추정 오차 — 측정·수정·E2E 검증 기록

2026-08-20 조사 시작, 2026-08-21 **수정 및 실기동 검증 완료.**
수정 전 스크립트는 `git show f5eeede:run_llama_server.sh` 로 볼 수 있다.

한 줄 요약: 추정식을 고칠 필요가 없었다. **llama.cpp 가 이미 정확히 계산해 준다.**

---

## 1. 문제

`run_llama_server.sh` 는 `-c` 기본값을 제안하려고 토큰당 KV 크기를 **KV 타입만 보고
상수**로 잡았다.

```sh
case "$KV_TYPE" in
  f16|bf16|f32) tokens_per_mb=4.5 ;;
  q8_0)         tokens_per_mb=8.5 ;;
  *)            tokens_per_mb=16  ;;
esac
```

KV 크기는 모델 구조에 달려 있으므로 상수로는 맞을 수 없다. 실제로 이 저장소의 모델
전부에서 틀렸고, 방향은 과대평가(= 컨텍스트를 손해 보는 쪽)였다. 32 GB 카드에
Qwen3.8-27B 를 올릴 때 **82,304 토큰**을 제안했는데 실제 한계는 **262,144 토큰**이다.

## 2. 답: `-fit` 에게 물어본다

`llama-server` 는 `-c` 를 주지 않으면 여유 VRAM 에 맞는 가장 큰 컨텍스트를 스스로
고른다(`--fit on` 이 기본값). 중요한 성질은 **이 계산이 가중치를 올리기 전에 끝난다**는
것이다. 실측 로그:

```
0.00.084 cmn common_init_: fitting params to device memory ...
0.00.572 common_params_fit_impl: projected to use 30268 MiB of device memory vs. 32434 MiB of free device memory
0.00.572 common_params_fit_impl: will leave 2165 >= 1908 MiB of free device memory, no changes needed
0.00.572 common_fit_params: fitting params to free memory took 0.49 seconds
0.00.881 load_tensors: loading model tensors, this can take a while... (load_mode = mmap)   ← 여기서부터가 진짜 로딩
```

그래서 띄우기 직전에 `-c` 없이 한 번 띄워 이 줄까지만 읽고 죽이면 **0.5초에** 답을
얻는다. VRAM 에 모델이 올라가기 전이라 비용이 사실상 없다.

여유가 모자라면 줄이는 쪽도 같은 형식으로 찍는다(`-fitt 12000` 으로 강제 실험):

```
common_params_fit_impl: cannot meet free memory target of 12884 MiB, need to reduce device memory by 10718 MiB
common_params_fit_impl: context size reduced from 262144 to 4096 -> need 9802 MiB less memory in total
```

이 값에는 사람이 못 맞추는 것들이 전부 들어 있다 — 백엔드별 연산 버퍼, 호스트에
남는 텐서, mmproj 몫, 하이브리드 층 구조. 관련 옵션:

- `-fitt MiB` 남길 여유(기본 1024, mmproj 가 있으면 그만큼 더해진다 → 위 예에서 1908)
- `-fitc N` 줄일 수 있는 최소 컨텍스트(기본 4096)
- `-fit off` 기능 자체를 끔

## 3. 폴백으로 남긴 CPU 드라이런 측정, 그리고 거기서 알게 된 것

`-fit` 이 없는 예전 빌드를 위해 2순위 경로를 남겼다. `--device none -ngl 0
--no-repack --no-warmup` 으로 두 컨텍스트(8192/32768)에 대해 띄워 메모리 내역만 읽고
차분한다. GPU 를 건드리지 않아 **다른 서버가 떠 있어도 안전**하고 1초면 끝난다.

```
총량(c)   = context + compute (llama.cpp 의 memory breakdown 표)
per_token = (총량(c2) − 총량(c1)) / (c2 − c1)
fixed     = 총량(c1) − per_token × c1
```

이 측정에서 상수가 왜 틀렸는지가 드러났다. q8_0, `--parallel 1` 기준:

| 모델 | 전체 층 | KV 있는 층 | 토큰당 KV | tokens/MiB |
|---|---|---|---|---|
| Qwen3.8-27B-ABLITERATED-Q6_K | 64 | 16 | 34,816 B | 30.1 |
| Qwen3.6-35B-A3B (MoE) | 40 | 10 | 10,880 B | 96.4 |
| Gemma4-26B-A4B (MoE) | 30 | 5 | 10,880 B | 96.4 |

셋 다 하이브리드라 **층 전부가 KV 를 갖지 않는다.**

- qwen35 계열은 `full_attention_interval = 4` — 네 층 중 하나만 어텐션, 나머지는 SSM
  상태(`RS buffer`, 컨텍스트와 무관한 고정 크기). Qwen3.8 149.62 MiB, Qwen3.6 62.81 MiB.
- Gemma4 는 KV 캐시가 두 개다. 5개 층은 컨텍스트 전체, 25개 층은 슬라이딩 윈도우라
  **1536 셀로 고정**(159.38 MiB). 컨텍스트를 늘려도 이 몫은 안 는다.

그래서 GGUF 메타데이터로 `block_count × head_count_kv × key_length` 를 계산하는 방법도
4배씩 틀린다. `key_length` 는 **헤드당이 맞다** — Qwen3.6 의 실측 10,880 B =
10층 × kv_heads 2 × (256+256) × 1.0625 로 정확히 떨어진다. 이전 문서에서 "층당" 가설이
Qwen3.8 에 더 맞아 보였던 것은 우연이다(그 모델은 `kv_heads=4` 이고 어텐션 층이 1/4 이라
두 오해가 정확히 상쇄된다).

KV 타입 계수는 알려진 값대로였다(Qwen3.6, ctx 65536): f16 1280 MiB / q8_0 680 / q4_0 360
= 원소당 2.0 / 1.0625 / 0.5625 B. `--parallel` 은 KV 총량은 안 바꾸지만 **RS 를 슬롯 수만큼
곱한다**(Qwen3.8 ctx 32768: 149.62 → 598.50 MiB). 측정할 때 실제 값을 그대로 넘겨야 한다.

### CPU 측정과 GPU 실측의 차이 (Qwen3.8-27B, q8_0, parallel 1)

2순위를 1순위로 쓰면 안 되는 이유다.

| 항목 | CPU 드라이런 | ROCm 실측 |
|---|---|---|
| 모델 가중치 | 21,049 MiB | **20,054 MiB** (임베딩 994 MiB 는 호스트에 남는다) |
| 연산 버퍼 @ctx 8192 | 140.28 MiB | 130.28 MiB (+ ROCm_Host 28.28) |
| 연산 버퍼 @ctx 32768 | 164.28 MiB | **240.28 MiB** (+ 52.28) |
| 컨텍스트 비례분 | 1,024 B/token | **4,693 B/token** |
| 연산 버퍼 @ctx 262144 | — | 1,360.28 MiB |

모델 크기는 과대(안전), 연산 버퍼는 과소(위험) 추정이라 대략 상쇄된다. 실제로 이
경로만으로 계산해도 262,144 가 나오긴 했지만, 두 오차가 우연히 상쇄된 결과다.

## 4. E2E 검증 (2026-08-21, 실제로 서버를 내리고 돌림)

스크립트를 그대로 실행한 결과:

```
컨텍스트 계산 중… (llama-server 에게 -fit 으로 물어봅니다. 가중치를 올리기 전 단계라 1초면 끝납니다)
llama.cpp 가 직접 고른 값 (-fit, 백엔드=ROCm0, KV=q8_0, --parallel 1):
  선택된 컨텍스트 : 262144 토큰
  예상 VRAM 사용  : 30268 MiB  (여유 32434 MiB 중)
  남기는 여유     : 2165 MiB  (-fitt 로 조정, 기본 1024 + mmproj 몫)
```

- 기동 후 `n_ctx_slot = 262144`, `rocm-smi` **31,689 MiB / 32,752 MiB** (여유 1,063 MiB)
- 추론 정상(짧은 요청 7.0초/389 토큰)
- **65,536 토큰짜리 프롬프트**를 실제로 처리하는 동안에도 VRAM 31,767 MiB 로 고정
  (KV 는 기동 시 통째로 잡히므로 요청이 길어져도 늘지 않는다)
- 같은 조건에서 예전 코드는 82,304 토큰을 제안했다 → **3.2배 손해였다**

3단 폴백도 각각 확인했다.

| 순위 | 방법 | 확인 |
|---|---|---|
| 1 | `-fit` 에게 질의 | ROCm 실기동 성공. Vulkan 빌드에서도 같은 줄을 찍는 것 확인(VRAM 이 점유된 상태라 4096 으로 축소 — 축소 경로도 정상 동작) |
| 2 | CPU 드라이런 2점 측정 | `-fit` 줄을 못 읽는 상황을 만들어 확인. "대체합니다" 를 찍고 262,144 산출 |
| 3 | 옛 상수 | `SKIP_CTX_PROBE=1` 로 확인. "옛 상수로 추정합니다" 를 찍고 90,203 산출 |

## 5. 무엇을 바꿨나

변경은 `tokens_per_mb` 계산 주변으로 한정했다. 실측표가 들어 있는 주석(Vulkan + q4_0
성능 절벽, `--parallel` 붕괴)은 그대로고, 대화형 `read -p` 프롬프트도 그대로다.
자동화 쪽에서 `-c` 를 직접 넘기는 경로도 영향 없다.

1. 컨텍스트 값을 `-fit` 에게 물어 그대로 쓴다. 실패하면 CPU 드라이런, 그것도 실패하면
   옛 상수로 내려가고 **내려갔다는 사실을 매번 화면에 찍는다.**
2. **Enter 를 누르면 `-c` 를 아예 넘기지 않는다.** 같은 계산을 llama.cpp 가 기동
   시점에 다시 하므로 값은 같고, 그 사이 VRAM 사정이 바뀌었으면 알아서 낮춰서 뜬다.
   우리가 숫자를 박아 넣으면 그런 경우 그냥 OOM 이다. 숫자를 직접 입력하면 그 값을
   `-c` 로 넘긴다(기존 동작 그대로). `MAX_AUTO_CTX` 를 쓰면 상한을 `-c` 로 넘긴다.
3. 2순위 경로에서는 모델 크기도 파일 크기가 아니라 llama.cpp 보고값을 쓴다.
   (Qwen3.8: 파일 21,392 → 21,049 MiB. 반대로 Gemma4 Q8_K_P 는 26,013 → 26,745 MiB 로
   **더 크다.** 파일 크기 기반 추정은 양방향으로 틀린다.)
4. 계산 근거를 화면에 찍는다.

환경변수: `SKIP_CTX_PROBE=1`(질의 생략), `PROBE_TIMEOUT`(기본 180초),
`MAX_AUTO_CTX`, `KV_TYPE`, `PARALLEL`.

## 6. 남은 것

- Vulkan 백엔드로 **실제 기동**은 안 해봤다(파싱만 확인). ROCm 만 실기동 검증했다.
- Qwen3.6 / Gemma4 는 GPU 실기동을 안 했다. `-fit` 에 맡기는 구조라 모델별 검증 필요성은
  낮아졌지만, 확인한 적이 없다는 사실은 사실이다.
- Gemma4 Q8_K_P 의 적재량이 파일보다 732 MiB 큰 이유는 확인하지 않았다(과대 추정 쪽이라
  안전한 방향이고, 1순위 경로에서는 쓰이지도 않는다).

## 7. 참고: 이 문제를 발견한 경위

`~/auto-typesetter` 프로젝트에서 로컬 VLM 으로 만화를 번역하며 모델별 VRAM 예산을 따지다
드러났다. 처음에는 옛 모델(MoE)에서 뺄셈으로 추정한 "KV 는 매우 싸다" 는 감각을 새
모델에 그대로 옮겨 반대 방향으로 크게 틀렸고, 그 뒤 GGUF 공식을 써서 또 틀렸다.
결국 맞은 것은 llama.cpp 가 직접 찍는 값뿐이었다. **추정식을 세우기 전에 프로그램에게
물어볼 수 있는지부터 확인하는 편이 빠르다.**
