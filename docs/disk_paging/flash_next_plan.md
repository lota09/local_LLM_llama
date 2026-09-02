# Qwen3.8-Flash-Next 기동·측정 계획

**CMP 170HX (SM80 · 64 GiB HBM2e) · 호스트 RAM 30 GiB · Crucial P1 NVMe** 에서
177B 모델을 띄우기 위한 계획서. 아직 **실행 전**이다 — 이 문서의 숫자 중
"예측"이라고 표시된 것은 전부 반증 대상이고, 측정하면 그 자리를 실측으로 덮는다.

> 하드웨어 사실은 [`hardware.md`](hardware.md) · 속도 방법론은 [`performance.md`](performance.md)
> · 양자화 축은 [`quantization.md`](quantization.md).

## 0. 결론부터

1. **된다. 단 llama.cpp 로만 된다.** 이 모델의 51B n-gram 테이블(PLE)을
   vLLM 과 FreeToken 은 **호스트 RAM 상주**로 요구한다. 30 GiB 로는 불가능하다.
2. **PLE 테이블은 행렬곱이 아니라 게더다.** 토큰당 16행 × 160값 = **약 2.7 KB**.
   95 GiB 테이블인데 접근이 희소해서 **SSD 에서 페이징해도 된다** — Apple
   "LLM in a Flash" 가 말한 구조다. 이것이 이 계획 전체가 성립하는 유일한 이유다.
3. **가중치 쪽은 이 카드에 여유롭게 들어간다.** 4.27bpw 빌드 기준 54.5 GB —
   64 GiB VRAM 안이다. 오프로딩이 필요한 건 테이블뿐이다.
4. **PCIe Gen2 x4 는 이번에도 안 아프다.** 토큰당 PCIe 를 건너는 건 게더 결과
   2560개 값(≈5 KB)뿐이다. [`hardware.md`](hardware.md) §0 의 "적재만 느리고
   디코드엔 무관" 이 여기서도 성립한다.
5. **SSD 수명 문제 없다.** 순수 읽기이고 25 tok/s 24시간 연속 = **5.8 GB/일**.
   쓰기 0. 이 박스가 오늘 15시간 동안 이미 1,035 GB 를 읽었다.
6. **가장 큰 불확실성은 PLE 게더의 동기화 비용이다.** 매 토큰 레이어 1에서
   CPU→GPU 를 건너는데, 이게 CUDA 그래프를 깨고 스톨을 만들면 디코드가
   예측 밴드 아래로 떨어진다. §7 의 G4 가 이걸 가른다.

### 엔진 3파 — 왜 llama.cpp 인가

| | PLE 51B 테이블 처리 | 나머지 가중치 | 이 박스에서 |
|:---|:---|:---|:---|
| **llama.cpp** | GGUF 텐서 · `-ot` 로 CPU 배치 · **mmap 으로 SSD 페이징** | `-ngl 99` 로 VRAM | ✅ **유일한 경로** |
| FreeToken | `PinnedUVATable` — **47.7 GiB pinned** host RAM 필수 (`models/qwen4_exp/ple.py`). 핀 메모리는 스왑도 안 된다 | offload/fused | ❌ RAM 30 GiB |
| vLLM | `VLLM_PLE_CPU_OFFLOAD=1` → **≥51 GB host RAM** + headroom | FP8 172.78 GiB · **TP2 GB300 최소** | ❌ 이중으로 막힘 |

FreeToken 은 vLLM 포크도 llama.cpp 래퍼도 아닌 **독립 엔진**이다(자체 Triton 커널 ·
자체 스케줄러 · radix KV · OpenAI+Anthropic 서버). vLLM 에서는 NVFP4 Marlin MoE GEMM 과
Anthropic 프로토콜·툴 파서만 **부품 단위로 차용**했고, `transformers>=5.5` 를 요구해
vLLM 과 **같은 venv 에 못 들어간다**(`pyproject.toml:82`). 이 모델에 한해서는
셋 다 후보였다가 PLE 테이블 하나로 llama.cpp 만 남았다.

## 1. 이 박스의 관련 실측값 (2026-08-31 측정)

| 경로 | 실측 | 측정법 |
|:---|---:|:---|
| VRAM (HBM2e) | **1,592.8 GB/s** | [`hardware.md`](hardware.md) §1 |
| 호스트 RAM 읽기 | 19.7 / 26.7 / **32.0 GB/s** (1/4/8 스레드) | numpy sum, 192 MiB/스레드 |
| PCIe H2D (pinned) | **1.55 GB/s** | [`hardware.md`](hardware.md) §1 |
| NVMe 순차 (O_DIRECT) | **1.6 GB/s** | `dd bs=8M iflag=direct` 4 GiB |
| NVMe 랜덤 4 KB | 0.025 / 0.107 / 0.180 GB/s · **6,063 / 26,121 / 43,847 op/s** (QD 1/8/32) | `preadv` + O_DIRECT |
| NVMe 랜덤 1 MB | 0.807 / 1.276 / 1.446 GB/s | 〃 |
| NVMe 랜덤 4 MB | 1.311 / **1.554** / 1.593 GB/s | 〃 |

**PLE 게더는 4 KB 행 접근이다.** 위 표의 첫 줄이 이 계획의 성패를 쥔 숫자고,
QD1(6,063 op/s)와 QD32(43,847 op/s)의 **7.2배 차이**가 §7 G5 의 관심사다.

디스크 여유: NVMe 544 GB. gcc 13/15 둘 다 있고 nvcc 13.3(miniconda) — CUDA 13.3 은
gcc ≤15 를 허용하므로 **호스트 컴파일러 문제 없다**.

## 2. 모델 — 무엇을 받는가

### 2.1 아키텍처 분해

```
Qwen3.8-Flash-Next  (HF model_type: qwen4_exp)
├─ 언어모델  125B  ·  토큰당 활성 6B
│   ├─ MoE      512 experts, top-10, gated shared expert
│   ├─ GDN      Gated Delta Network — 4개 레이어 중 3개 (KV 없음, 상태만)
│   ├─ QSA      Query-aware Sparse Attention — budget 2048, ratio 4
│   └─ HC       hyper-connections (저랭크 residual stream)
└─ PLE 테이블  51B  ·  3.2억 행  ·  BF16 95.4 GiB
    토큰당 16행(2-gram 8 + 3-gram 8) × 160값 → E_t[2560]  =  약 2.7 KB
```

**KV 가 싼 모델이다.** 어텐션 레이어가 1/4뿐이고 그마저 sparse 라, 남는 VRAM 대비
컨텍스트가 길게 나올 여지가 있다. 실측으로 확인한다(§8 M4).

### 2.2 빌드 선택 — [AtomicChat/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/AtomicChat/Qwen3.8-Flash-Next-GGUF)

| 빌드 | 파일 | **VRAM 상주분** | SSD 페이징분 | top-1 | 판정 |
|:---|---:|---:|---:|---:|:---|
| AD-3.84bpw-IQ4_XS | 84.9 GB | **45.8 GB** | 39.1 GB | 82.68% | 1차 게이트용 |
| **AD-4.27bpw-Q4_K_M** | 92.9 GB | **54.5 GB** | 38.4 GB | **89.49%** | ★ **최종 목표** |
| AD-5.00bpw-Q5_K_M | 110.5 GB | 56.1 GB | 54.4 GB | 89.55% | 여유 없음 |

**순서: 3.84 로 먼저 띄우고(위험 낮음), 통과하면 4.27 로 올린다.**

- top-1 82.68% → 89.49% 는 **무시 못 할 격차**다. 3.84 는 어디까지나 경로 검증용이고
  상주 목표는 4.27 이다.
- 5.00 은 top-1 이 4.27 대비 +0.06%p 인데 SSD 페이징분이 54.4 GB 로 늘어난다. **버린다.**
- **Q4_K_M 이 IQ4_XS 보다 CUDA 에서 유리할 가능성이 있다.** K-quant 는 MMQ 경로가
  성숙했고 IQ 계열은 역양자화 비용이 크다. 즉 4.27 이 품질도 속도도 이길 수 있다 —
  §8 M2 에서 같은 조건으로 재서 확인한다.

두 빌드 합계 178 GB, 여유 544 GB. 둘 다 받아두고 비교한 뒤 하나를 지운다.

## 3. 메모리 예산

### 3.1 VRAM 64 GiB

| | 3.84bpw | 4.27bpw |
|:---|---:|---:|
| 가중치(테이블 제외) | 45.8 GB | 54.5 GB |
| **남는 것** | **~18 GiB** | **~9.5 GiB** |
| ─ CUDA 그래프 + 활성화 버퍼 | ~2 GiB | ~2 GiB |
| **→ KV 풀** | **~16 GiB** | **~7.5 GiB** |

[`performance.md`](performance.md) §4.1 대로 CUDA 그래프는 **켠다** (디코드 3.8배).
KV 풀 1~2 GiB 를 그래프가 먹는 것은 감수한다.

### 3.2 호스트 RAM 30 GiB

여기엔 **모델이 아무것도 상주하지 않는다.** PLE 테이블 39 GB 파일이
mmap 으로 열려 있고, 커널이 남는 RAM(vLLM 내리면 ~26 GiB)을 페이지 캐시로 쓴다.

**이게 스왑과 결정적으로 다른 점:** mmap 파일 백드 페이지는 메모리 압박이 오면
**그냥 버려진다**(clean page). 원본 GGUF 에서 다시 읽으면 그만이고 **쓰기가 0**이다.
익명 메모리였다면 스왑에 써서 내보냈을 것이고, 그건 4 KB 랜덤 25 MB/s 에 TBW 까지 먹는다.

정상상태 페이지 캐시 히트율이 이 계획의 핵심 미지수다. n-gram 분포는 심하게
편향돼 있으니(자주 나오는 2/3-gram) 26 GiB 캐시로 39 GB 테이블의 히트율이
꽤 높게 나올 것으로 본다 — **예측 70~90%**, 측정은 §8 M5.

## 4. 빌드

### 4.1 요구사항

- **PR [#27742](https://github.com/ggml-org/llama.cpp/pull/27742) 이후 판본.**
  `qwen4exp` 아키텍처 · QSA · GDN · PLE 가 **2026-08-27 19:32** 에 머지됐다(`6c84c7d5`).
- CUDA: nvcc 13.3 (miniconda) · gcc 15.2 (CUDA 13.3 은 gcc ≤15 허용)
- 아키텍처: **sm_80**

**아키텍처 이름은 `qwen4exp` 다 — 밑줄이 없다.** `qwen4_exp` 는 HF 쪽 `model_type` 이고,
llama.cpp 의 GGUF `general.architecture` 값은 `src/llama-arch.cpp:43` 의 `"qwen4exp"` 다.
검색할 때 이걸 틀리면 정상 빌드에서도 0건이 나온다.

### 4.2 어느 판본을 받는가 — 릴리스로는 안 된다 (확인함)

llama.cpp 태그는 두 종류다. CI 가 하루에도 여러 번 찍는 `bNNNN` 은 **prerelease** 라
GitHub `/releases/latest` 에 안 잡히고, 드물게 나오는 `vX.Y.Z` 만 잡힌다.
`build_llama_server.sh` 는 그 엔드포인트를 쓴다 → **`v0.3.0` (2026-08-25)** 을 받는다.
머지보다 이틀 빠르다. 소스에서 직접 셌다:

| ref | 날짜 | `src/llama-arch.cpp` 의 `qwen4exp` |
|:---|:---|---:|
| `v0.3.0` ← 옵션 없이 돌리면 이것 | 2026-08-25 | **0 — 안 됨** |
| `b10717` | 2026-08-31 | 1 ✅ |
| `master` | (매일 이동) | 1 ✅ |

**`b10717` 같은 bNNNN 태그를 박는다.** `master` 는 내일 받으면 다른 코드라 §11 의
기록이 재현 불가능해진다.

### 4.3 명령

```bash
cd ~/Developments/llamacpp
./build_llama_server.sh --ref b10717 --gpu-arch 80
```

- `--ref` / `--gpu-arch` 는 **인자**다(환경변수 아님). 예전 문서의 `CLONE_REF=master` 는
  스크립트가 읽지 않아 조용히 무시됐다 — 지금은 인자로 받는다.
- 설치 위치는 두 옵션을 준 흔적이 이름에 남는다 → **`llama_server_cuda-sm80_b10717`**.
  기존 `llama_server_cuda`(안정 릴리스본)를 덮어쓰지 않는다.
- `--gpu-arch 80` 은 사실 생략해도 된다. llama.cpp 가 `GGML_NATIVE` 로 이 머신의 GPU 를
  보고 sm_80 하나만 만든다(현 설치본을 `cuobjdump --list-elf` 로 확인함). 다만 그건
  **빌드 시점에 GPU 가 보일 때**만 성립하므로 못박는 편이 안전하다.
- 백엔드 선택 프롬프트를 건너뛰려면 `GGML_BACKEND=cuda NONINTERACTIVE=1` 을 앞에 붙인다.

⛔ **`apt` 로 kernel / `nvidia-*` 를 건드리지 않는다** — 언락이 소멸한다
([`hardware.md`](hardware.md) 최상단). cmake·gcc·smartmontools 는 무관하므로 안전하다.

### 4.4 확인

스크립트가 끝에서 **자동으로** 실행 검증을 한다(9c): `--version` 으로 링크·심볼을,
`--list-devices` 로 CUDA 백엔드가 실제로 장치를 잡는지 본다. 실패하면 exit 1 이다.
빌드한 커밋·실측 sm 아키텍처·cmake 인자는 `llama_server_cuda-sm80_b10717/BUILD_INFO`
에 남으므로 §11 기록에 그대로 옮기면 된다.

아키텍처 지원 여부만 직접 볼 거라면:

```bash
strings llama_server_cuda-sm80_b10717/libllama.so* | grep -x qwen4exp
```

⚠️ **`llama-server` 를 뒤지면 안 된다.** 그 실행파일은 `main.cpp` 하나뿐인 17 KB 짜리
런처이고(`tools/server/CMakeLists.txt`), 아키텍처 이름표는 `libllama.so` 에 있다.
리눅스는 `BUILD_SHARED_LIBS` 가 기본 ON 이라 이 구조가 유지된다.

안 나오면 **ref 가 PR 이전이다.** 여기서 멈추고 §4.2 표로 돌아간다.

## 5. 기동

```bash
llama-server \
  -m ~/Developments/llamacpp/models/Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS.gguf \
  -ngl 99 \
  -ot "per_layer_token_embd.weight=CPU" \
  -c 32768 \
  --jinja \
  --host 127.0.0.1 --port 8080
```

| 플래그 | 왜 |
|:---|:---|
| `-ngl 99` | 전문가·어텐션·GDN 전부 VRAM. 64 GiB 있으니 아낄 이유가 없다 |
| `-ot "per_layer_token_embd.weight=CPU"` | **PLE 테이블만** CPU 쪽에 남긴다. 이것 하나가 전체 계획이다 |
| `-c 32768` | 1차 게이트값. KV 여유 확인 후 §8 M4 에서 올린다 |
| `--jinja` | Qwen 채팅 템플릿 · 툴 콜 |

### ⛔ 금지 플래그

| | 왜 |
|:---|:---|
| `--no-mmap` | **테이블의 SSD 페이징이 죽는다.** 39 GB 를 RAM 에 올리려다 OOM |
| `--load-mode none` | 〃 |
| `--mlock` | 〃 — 게다가 핀 메모리라 스왑도 못 한다 |
| `per_layer_token_embd` 에 다른 `-ot`/`--override-tensor` | 테이블을 메모리로 끌어올린다 |

### 사전 조치

```bash
sudo sysctl vm.swappiness=10   # mmap clean page 를 버리는 쪽을 커널이 선호하게
nvidia-smi                     # vLLM 이 56 GiB 물고 있으면 먼저 내린다
```

## 6. 참조 성능 — 남의 박스에서 나온 값

| 박스 | 빌드 | 디코드 | 프리필 | 비고 |
|:---|:---|---:|---:|:---|
| MacBook Pro **M5 Max 64 GB** | AD-3.84bpw | **36 tok/s** | 517.9 tok/s | 통합메모리 · 테이블 SSD 페이징 |
| **DGX Spark (GB10)** 128 GB | UD-Q4_K_XL | **25 tok/s** | 76.7 tok/s | `-ngl 999` + `-ot ...=CPU` · 로딩 1.5분 |

**둘 다 통합메모리 박스다.** 그쪽은 PLE 게더가 공짜인 대신 가중치 대역폭이 낮고,
이 카드는 정반대다(HBM 1592 GB/s 인데 게더가 PCIe Gen2 x4 를 건넌다).
**직접 비교가 안 되는 관계**라서 예측 밴드를 넓게 잡는다.

## 7. 게이트 — 순서대로, 하나씩

각 게이트는 **통과/실패가 명확**해야 하고, 실패하면 다음으로 안 넘어간다.

| | 게이트 | 통과 기준 | 실패 시 |
|:---|:---|:---|:---|
| **G0** | 빌드 | 스크립트 9c 검증 통과 + `strings libllama.so* \| grep -x qwen4exp` 가 잡힌다 | ref 를 `b10717` 이상으로 다시 (§4.2) |
| **G1** | 다운로드 | 3.84bpw 84.9 GB · 샤드 해시 일치 | 재개 다운로드 |
| **G2** | 로딩 | OOM 없이 서버가 ready. `nvidia-smi` VRAM ≈ 46 GiB, **RSS 가 40 GB 를 안 넘는다** | RSS 가 크면 mmap 이 안 걸린 것 — 금지 플래그 확인 |
| **G3** | 정합성 | 짧은 프롬프트가 **한국어·영어로 말이 되는 출력**. 반복·깨짐 없음 | IQ4_XS CUDA 경로 의심 → 4.27bpw Q4_K_M 로 교체 |
| **G4** | **디코드 속도** | **≥ 25 tok/s** (DGX Spark 동급) | §9 진단 |
| **G5** | 콜드/웜 격차 | 캐시 웜 대비 콜드 디코드 저하 **< 2배** | SSD 게더가 지배 → §9 |

**G4 예측 밴드: 25~80 tok/s.**
근거 — 활성 6B @4.27bpw = 3.2 GB/token, HBM 1592 GB/s 면 이론 2.0 ms(494 tok/s).
이 박스의 dense 실효율은 54%([`performance.md`](performance.md): 27B AWQ 이론 8.75 ms vs
실측 16.1 ms). 그러나 MoE 는 top-10 짜리 작은 GEMV 로 쪼개져 dense 대비 효율이
1/3~1/2로 떨어지고, 거기에 GDN·HC·QSA·PLE 게더가 더 붙는다.
**밴드 아래로 떨어지면 원인은 대역폭이 아니라 PLE 게더 동기화다** — 그게 G5 의 존재 이유다.

## 8. 측정 — 무엇을, 어떻게

기존 도구를 쓴다: `bench/bench_manga.py`(워크로드 모양) · `bench_decode_pl.py`(전력캡별
정상상태 디코드) · `bench_accuracy.py`(PPL·top-1) · `llamacpp/bench_backends.py`.
[`performance.md`](performance.md) 의 기록 규율을 그대로 따른다 — **날짜·전력캡·판본을 항상 같이 적는다.**

| | 측정 | 방법 | 왜 |
|:---|:---|:---|:---|
| **M1** | 로딩 시간 (콜드/웜) | `time` + `echo 3 > drop_caches` 로 콜드 | DGX Spark 1.5분이 기준선 |
| **M2** | **3.84 vs 4.27 동일 조건** | 같은 프롬프트·같은 `-c`·같은 전력캡 | Q4_K_M(MMQ)이 IQ4_XS 를 이기는지 |
| **M3** | 디코드 tok/s (동시 1·4·16) | `bench_manga.py` | §7 G4. 동시성 스케일링은 [`performance.md`](performance.md) §4.3 형식 |
| **M4** | **KV 한계 컨텍스트** | `-c` 를 올리며 OOM 지점 | 어텐션 1/4 + sparse 라 길게 나올 것 |
| **M5** | **PLE 페이지 캐시 히트율** | 실행 전후 `/sys/block/nvme0n1/stat` 읽기 섹터 차 ÷ (토큰수 × 2.7 KB) | 이 계획의 핵심 미지수 |
| **M6** | **콜드 vs 웜 디코드** | drop_caches 직후 vs 5분 warm-up 후 | §7 G5 |
| **M7** | 프리필 tok/s (1k·4k·32k) | `bench_manga.py` 입력 스윕 | 프리필 배치 N × 16행 랜덤 게더가 SSD IOPS 에 걸리는지 |
| **M8** | 전력캡별 (180/250/300W) | `bench_decode_pl.py` | [`performance.md`](performance.md) §0 형식. 상시 180W 권장 유지 여부 |
| **M9** | SSD 읽기 총량 / 쓰기 총량 | `/sys/block/nvme0n1/stat`, `smartctl` | 쓰기가 0 에 가까운지 확인 (수명 검증) |

### M7 의 사전 계산 — 프리필이 SSD 에 걸리는가

4,096 토큰 프리필 = 4,096 × 16 = **65,536 행 랜덤 게더**.

| 캐시 미스율 | 큐 깊이 | SSD 시간 | 프리필 환산 |
|---:|:---|---:|---:|
| 50% | QD32 (43,847 op/s) | 0.75 s | 5,461 tok/s 상당 — **병목 아님** |
| 100% | QD32 | 1.49 s | 2,742 tok/s 상당 — 아직 여유 |
| 100% | **QD1** (6,063 op/s) | **10.8 s** | **379 tok/s 상당 — 병목** |

**즉 llama.cpp 가 게더를 병렬로 던지느냐(QD)가 프리필을 가른다.** M7 이
M5(히트율)와 함께 이 표의 어느 줄에 앉는지 알려준다.

## 9. 실패 모드와 진단

| 증상 | 1순위 원인 | 확인 | 대응 |
|:---|:---|:---|:---|
| 로딩 중 OOM (호스트) | mmap 미적용 | `ps -o rss` 가 40 GB 초과 | 금지 플래그(§5) 확인 |
| 로딩 중 OOM (VRAM) | 테이블이 GPU 로 갔다 | `nvidia-smi` 가 60 GiB 초과 | `-ot` 정규식 오타 |
| 디코드 < 15 tok/s, GPU 사용률 낮음 | **PLE 게더 동기화 스톨** | `nvidia-smi dmon` 에서 SM 이 톱니 | CUDA 그래프 on/off 비교 · 캐시 웜 상태에서 재측정 (M6) |
| 디코드 < 15 tok/s, **디스크 read 높음** | 페이지 캐시 히트율 낮음 | M5 | RAM 증설이 답 (§10) |
| 디코드 < 15 tok/s, GPU 사용률 높음 | MoE 커널 효율 | — | 3.84↔4.27 교체 (M2) · 전력캡 (M8) |
| 출력이 깨짐 | IQ4_XS CUDA 경로 | G3 | 4.27bpw Q4_K_M |
| 첫 토큰만 느리고 이후 정상 | 정상 — 콜드 캐시 | M6 | 조치 불필요 |
| 스왑 사용량 증가 | 익명 메모리 압박 | `swapon --show` | swappiness 10 · vLLM 완전 종료 |

## 10. 이후 분기

- **G4 통과** → 4.27bpw 상주, `bench/runs.tsv` 에 기록, [`performance.md`](performance.md) 에 절 추가
- **G5 실패 (SSD 지배)** → **RAM 증설이 직접적인 답**이다. TUF Z390-PLUS 는 4 DIMM
  공식 최대 128 GB. 다만 4-DIMM 듀얼랭크는 2666 이하로 떨어지고 **대역폭은
  32 GB/s 그대로**(듀얼채널)다. 페이지 캐시 용량만 사는 것이므로 M5 가
  낮게 나왔을 때만 정당화된다
- **G3 실패** → 이 경로 폐기. 64 GiB 에 통째로 들어가는 모델
  (Qwen3.6-35B-A3B NVFP4 24 GB · Gemma-4-26B-A4B NVFP4 18 GB)로 복귀

## 11. 기록 양식

측정마다 [`performance.md`](performance.md) 규율대로 조건을 같이 남긴다.

```
날짜        2026-__-__
빌드        llama.cpp <sha> · CUDA 13.3 · sm_80      ← 설치 디렉터리의 BUILD_INFO 에서 복사
모델        AD-_.__bpw-____  (파일 __._ GB)
플래그      -ngl 99 -ot "per_layer_token_embd.weight=CPU" -c _____
전력캡      ___ W   ·   SM ____ MHz   ·   코어 __°C / HBM __°C
캐시 상태   콜드 / 웜(__분)
VRAM        __._ GiB / 64.0     호스트 RSS __._ GB     스왑 __._ GB
결과        프리필 ___._ tok/s   디코드 __._ tok/s   TTFT ___ ms
디스크      읽기 __._ GB   쓰기 __._ GB   (토큰당 ___ KB)
```

## 출처

- [llama.cpp PR #27742 — qwen4_exp 지원 (2026-08-27 머지)](https://github.com/ggml-org/llama.cpp/pull/27742)
- [AtomicChat/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/AtomicChat/Qwen3.8-Flash-Next-GGUF) · [빌드 가이드](https://atomic.chat/blog/guides/how-to-run-qwen-3-8-flash-next-locally)
- [DGX Spark 실행 보고 (25 tok/s)](https://forums.developer.nvidia.com/t/qwen3-8-flash-next-ud-q4-k-xl-gguf-on-dgx-spark-with-llama-cpp-gpu-experts-ple-n-gram-table-streamed-from-disk-25-tok-s-up-to-1m-context/381720)
- [vLLM 레시피 — VLLM_PLE_CPU_OFFLOAD](https://recipes.vllm.ai/Qwen/Qwen3.8-Flash-Next) · [FreeToken](https://github.com/FlashML-org/FreeToken)
