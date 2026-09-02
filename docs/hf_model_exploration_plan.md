# HuggingFace 모델 탐험 계획 (MI50 32GB 기준)

*작성일: 2026-08-09 · 대상 하드웨어: AMD Radeon Instinct MI50 32GB (Vega 20 / gfx906)*

---

## 0. 시작 전에 — 이 문서의 전제

이 계획의 절반은 "어떤 모델이 좋은가"이고, 나머지 절반은 **"이 GPU에서 그게 실제로 돌아가는가"** 입니다.
후자가 이 박스에서는 훨씬 어려운 문제이므로 먼저 정리합니다.

### 0.1 실측된 현재 환경

| 항목 | 값 | 이 계획에 주는 영향 |
|:---|:---|:---|
| GPU | MI50 32GB, gfx906 | VRAM 용량은 넉넉. **문제는 소프트웨어 지원** |
| VRAM | 32,752 MiB (HBM2, 1TB/s급) | 24GB 소비자 카드보다 용량 우위 |
| CPU / RAM | i7-9700K 8C/8T · 31 GiB | RAM 31GB는 대형 모델 CPU 오프로드에 빠듯 |
| 디스크 여유 | **769 GB** | 모델 수집에 전혀 부족하지 않음 |
| PCIe | **3.0 ×4** (칩셋 경유) | 모델 로딩·CPU 오프로드가 느림. VRAM에 다 올려야 함 |
| Python | 3.14.6 (conda base) | **PyTorch 미설치. 3.14는 torch 휠이 아직 없음 → 3.11/3.12 venv 필요** |
| Docker | **미설치** | 트랙 B를 하려면 먼저 설치 |
| llama.cpp | ROCm/HIP · Vulkan 양쪽 빌드 완료 | 5번 RAG는 오늘 바로 시작 가능 |

### 0.2 gfx906의 핵심 제약 — 반드시 이해하고 갈 것

1. **공식 ROCm은 gfx906을 버렸다.** 이미 `setup_rocm_tensile.sh`로 rocBLAS 커널을 이식해 llama.cpp는 살렸지만,
   PyTorch 생태계는 그것만으로 부족합니다. 공식 PyTorch ROCm 휠은 gfx906 코드를 빌드하지 않습니다.
2. **하드웨어 세대가 낮다.** Vega 20에는 bf16 연산, fp8, Tensor Core 상당물이 없습니다.
   fp16 26.5 TFLOPS는 나쁘지 않지만, **FlashAttention·xformers·Triton 커널 대부분이 gfx906 미지원**입니다.
   즉 "VRAM은 충분한데 느리다"가 이 카드의 일관된 패턴입니다.
3. **커스텀 CUDA 커널에 의존하는 프로젝트는 사실상 불가.** 3D 생성(TRELLIS, Hunyuan3D)이 대표적입니다.

### 0.3 두 개의 실행 트랙

이 계획의 모든 과제는 아래 둘 중 하나로 굴러갑니다.

| | **트랙 A — 네이티브 C++ (Vulkan/HIP)** | **트랙 B — PyTorch (Docker)** |
|:---|:---|:---|
| 구성 | llama.cpp, stable-diffusion.cpp, whisper.cpp | `mixa3607/ML-gfx906` 커뮤니티 도커 이미지 |
| 장점 | 이미 검증됨, 의존성 없음, GGUF 양자화로 VRAM 절약 | ComfyUI·diffusers·transformers 전부 사용 가능 |
| 단점 | 지원 모델이 최신 논문 대비 몇 달 뒤처짐 | 3자 빌드 의존, 이미지 크기 20GB+, 커스텀 커널은 여전히 불가 |
| 적용 과제 | 1(일부), 2(일부), 3, 5 | 1, 2, 4(시도), 6+ |

**트랙 B 핵심 링크:** `mixa3607/ML-gfx906` 가 gfx906 패치 ROCm 7.14 + PyTorch + ComfyUI 도커 이미지를
데일리로 빌드합니다. 이게 없으면 이 카드로 이미지 생성 생태계에 진입하는 길이 사실상 막힙니다.

```bash
# 트랙 B 진입 (Docker 설치 후)
docker run --rm --device=/dev/kfd --device=/dev/dri \
  --group-add video --group-add render \
  -p 8188:8188 -e PERSISTENCE_PATH=/data \
  -v $HOME/comfy-data:/data \
  docker.io/mixa3607/comfyui-gfx906:<ver>-rocm-7.14
```
(현재 `video`/`render` 그룹에 이미 속해 있으므로 권한 문제는 없을 것입니다.)

---

## 1. VRAM 등급 정의

과제별 표에서 쓰는 세 등급의 의미를 먼저 고정합니다.

| 등급 | 뜻 | 대표 하드웨어 |
|:---|:---|:---|
| **최소** | "결과물이 나오긴 한다." 해상도·길이·정밀도를 타협. 학습·체험 목적으로는 충분 | 8GB (RTX 3060 12GB / 4060 Ti 8GB) |
| **양호** | "실사용 품질." 커뮤니티 표준 설정을 타협 없이 돌릴 수 있는 지점 | 16–24GB (4080 / 3090 / 4090 / **MI50 32GB**) |
| **최적(프론티어)** | "정밀도·크기·배치 어디도 양보하지 않음." 연구·프로덕션 급 | 48–96GB+ (RTX PRO 6000 96GB / H100 / A100 80GB) |

> **중요:** MI50 32GB는 **용량 기준으로는 대부분의 과제에서 "양호"~"최적" 사이**에 들어갑니다.
> 하지만 **속도와 소프트웨어 호환성 기준으로는 "최소"에 가깝습니다.**
> 그래서 각 과제마다 `MI50 현실` 항목을 따로 둡니다. 이게 이 문서에서 제일 중요한 칸입니다.

---

## 2. 과제 1 — Text-to-Image (언센서드 포함)

### 2.1 모델 지형 (2026년 8월 기준)

| 모델 | 파라미터 | 성격 | 검열 |
|:---|:---|:---|:---|
| **SDXL 파생** (Illustrious XL, NoobAI-XL, Pony v6, Juggernaut XL) | 2.6B | 애니/실사, **LoRA·ControlNet 생태계가 압도적으로 큼** | 파인튜닝 단계에서 제거됨 |
| **Z-Image (Turbo)** | 6B | 신형 경량. 8스텝급 고속, 품질 대비 VRAM 효율이 좋음 | 베이스는 필터 없음 |
| **Chroma** | 8.9B | **Flux.1-schnell 기반 + 검열 해제 재학습.** "언센서드 + Flux급 품질"의 현재 정답 | 명시적으로 제거 |
| **FLUX.1 [dev]** | 12B | 프롬프트 이해력·사실감 최상위권 | 가중치에 필터 없음(런타임 언센서드) |
| **Qwen-Image** | 20B | 텍스트 렌더링(한글 포함)이 압도적 | 필터 없음 |
| **FLUX.2 [klein]** | 4B | 신형 경량 Flux, 저지연 로컬용 | — |

### 2.2 VRAM 등급표

| 등급 | VRAM | 구성 | 얻는 것 |
|:---|:---|:---|:---|
| **최소** | **6–8 GB** | SDXL 파생 fp16, 또는 Chroma Q4 GGUF | 1024², 20–30스텝. LoRA 1–2개. 충분히 재미있음 |
| **양호** | **16 GB** | Chroma Q8 / FLUX.1-dev Q8 GGUF + T5-XXL Q8, 또는 Z-Image fp16 | 프롬프트 충실도 높은 1024–1536², ControlNet 동시 사용 |
| **최적** | **48 GB+** | FLUX.1-dev fp16 + T5-XXL fp16 상주, Qwen-Image 20B bf16, 배치 4, LoRA 학습 병행 | 양자화 손실 0, 2048², 반복 실험 속도 |

### 2.3 MI50 현실

- **용량:** 32GB이므로 FLUX.1-dev를 **fp16 통짜로** 올릴 수 있습니다. 양자화가 아예 필요 없습니다.
- **속도(추정):** SDXL 1024² 30스텝 ≈ 25–45초, FLUX.1-dev 20스텝 ≈ 2–5분.
  *(fp16 TFLOPS 대비 추정치이며, FlashAttention 부재로 어텐션 구간 손해를 반영했습니다. 반드시 직접 측정하세요.)*
- **권장 진입:** 트랙 A의 `stable-diffusion.cpp` **Vulkan 백엔드**. SDXL / Flux / Qwen-Image / SD3.5를 지원하고,
  llama.cpp와 같은 ggml 기반이라 이 박스에서 이미 검증된 경로입니다.
  ComfyUI(트랙 B)는 그다음에, LoRA·ControlNet 생태계가 필요해질 때 붙입니다.

### 2.4 실행 순서

1. `stable-diffusion.cpp` Vulkan 빌드 → SDXL 계열 1개로 "그림이 나온다" 확인 (반나절)
2. Chroma GGUF로 교체 → 언센서드 + Flux급 품질 확인 (반나절)
3. FLUX.1-dev fp16 → 32GB의 이점을 실제로 쓰는 지점 (하루)
4. 만족스러우면 ComfyUI 도커로 넘어가 LoRA / ControlNet / 워크플로 그래프 (2–3일)

> **한 줄 요약:** 언센서드 목적이면 **Chroma**가 현재 최선의 단일 선택. 생태계(LoRA 종류)가 목적이면 **SDXL 파생**.

---

## 3. 과제 2 — Image-to-Image: 흑백 사진 컬러화

이건 세 가지 접근이 완전히 다른 난이도를 가집니다. **셋 다 해보는 게 학습 효과가 가장 큽니다.**

| 접근 | 모델 | VRAM | 특징 |
|:---|:---|:---|:---|
| **(a) 전용 모델** | **DDColor** (ICCV 2023, dual decoder) | **~2 GB** (CPU도 가능) | 즉시 실행, 자연스러운 피부톤·하늘·초목. 제어 불가 |
| **(b) 확산 + 조건부** | SDXL + **ControlNet Recolor** | 8–12 GB | 프롬프트로 색을 지시 가능("빨간 코트, 흐린 오후") |
| **(c) 지시형 편집** | **FLUX.1 Kontext [dev]** (12B), Qwen-Image-Edit (20B) | 12 GB(Q8) / 24 GB(fp16) | "이 사진을 컬러로" 한 문장. 현재 품질 최상위 |

### 3.1 VRAM 등급표

| 등급 | VRAM | 구성 |
|:---|:---|:---|
| **최소** | **2–4 GB** | DDColor 단독. 결과는 놀랍게 괜찮습니다 |
| **양호** | **12–16 GB** | DDColor로 베이스 컬러 → SDXL+ControlNet으로 리파인 → Real-ESRGAN 업스케일 |
| **최적** | **24–48 GB** | FLUX.1 Kontext fp16 / Qwen-Image-Edit. 얼굴 복원(GFPGAN·CodeFormer) + SUPIR 업스케일 파이프라인 전체 상주 |

### 3.2 MI50 현실 & 추천 프로젝트

- DDColor는 순수 PyTorch 컨브넷이라 **커스텀 커널이 없어 gfx906에서 돌 확률이 높습니다.** 트랙 B의 첫 테스트로 이상적.
- 진짜 재미있는 결과물: **"오래된 가족사진 복원 파이프라인"**
  `스캔 → 스크래치 제거 → GFPGAN 얼굴 복원 → DDColor 컬러화 → Kontext로 색 보정 지시 → Real-ESRGAN 4× 업스케일`
  단계별로 before/after를 남기면 각 모델이 뭘 하는지 눈으로 배웁니다.

---

## 4. 과제 3 — STT / TTS

**이 과제가 MI50에서 가장 마찰이 적습니다.** 모델이 작고, C++ 구현이 성숙해 있습니다.

### 4.1 STT (음성 → 텍스트)

| 등급 | VRAM | 모델 | 비고 |
|:---|:---|:---|:---|
| **최소** | **1–2 GB** | whisper.cpp `base` / `small` (Vulkan) | 한국어는 small부터 쓸 만함 |
| **양호** | **6 GB** | **Whisper large-v3-turbo** (809M 디코더) | 한국어 실사용 기준선. 속도·정확도 균형 최상 |
| **최적** | **10–16 GB** | Whisper large-v3 fp16 + **pyannote 화자분리** + Parakeet TDT(초고속 영어) 이중 구성 | 회의록 수준. 화자 라벨 + 타임스탬프 |

- **MI50 현실:** whisper.cpp Vulkan으로 large-v3-turbo까지 여유. 이 과제는 사실상 "그냥 됩니다."
- **한국어 주의:** Parakeet 계열은 영어 중심 최적화입니다. **한국어는 Whisper 계열이 여전히 안전한 선택.**

### 4.2 TTS (텍스트 → 음성)

| 등급 | VRAM | 모델 | 비고 |
|:---|:---|:---|:---|
| **최소** | **0 GB (CPU)** | **Kokoro** (82M) | 라즈베리파이에서도 돎. **단 한국어 미지원** |
| **양호** | **4–6 GB** | **Chatterbox Multilingual** (한국어 포함 23개 언어, 제로샷 보이스 클로닝), XTTS-v2, CosyVoice 2 | 한국어 + 음성 복제를 동시에 원하면 여기 |
| **최적** | **12–24 GB** | Higgs Audio v2, OpenAudio S1, VibeVoice(멀티스피커 장시간 대화 생성) | 팟캐스트·오디오북 급 |

- **한국어가 필요하면 Kokoro는 탈락**입니다. Chatterbox Multilingual부터 시작하세요.
- **MI50 현실:** 전부 PyTorch(트랙 B)이지만 모델이 작고 커스텀 커널 의존이 적어 성공 확률이 높습니다.
  최악의 경우 CPU 추론으로도 실용적입니다(Kokoro는 CPU로 실시간 초과).

### 4.3 추천 결과물

**"로컬 음성 어시스턴트"** — 3번과 5번을 하나로 잇는 프로젝트:
`마이크 → whisper.cpp → llama.cpp(RAG 붙임) → Chatterbox TTS → 스피커`
전부 로컬, 전부 이 박스에서. 이게 이 계획 전체의 자연스러운 최종 목적지입니다.

---

## 5. 과제 4 — 3D 모델링 AI

**솔직하게 씁니다: 이 과제는 MI50에서 가장 어렵고, 유일하게 "포기 권고"가 붙는 항목입니다.**

### 5.1 모델 지형

| 모델 | 성격 | VRAM |
|:---|:---|:---|
| **Stable Fast 3D / TripoSR** | 1초급 image→mesh. 품질은 낮지만 압도적으로 빠름 | 6 GB |
| **TRELLIS / TRELLIS.2-4B** | image→3D 충실도 선두. 3D Gaussian + mesh | 8 GB(최적화판) ~ 16 GB |
| **Hunyuan3D 2.0** | 형상만 6 GB / 형상+텍스처 16 GB | 6–16 GB |
| **Hunyuan3D 2.1 / 3.x** | PBR 텍스처, 최고 디테일. **텍스트/멀티뷰 입력도 지원** | 24 GB+ |

### 5.2 VRAM 등급표

| 등급 | VRAM | 구성 |
|:---|:---|:---|
| **최소** | **6–8 GB** | TripoSR / Stable Fast 3D / Hunyuan3D-2 형상 전용 |
| **양호** | **16 GB** | TRELLIS 또는 Hunyuan3D 2.0 형상+텍스처 |
| **최적** | **24–48 GB** | Hunyuan3D 3.x PBR 풀 파이프라인, TRELLIS.2-4B, 멀티뷰 정제 |

### 5.3 MI50 현실 — 여기가 문제

TRELLIS와 Hunyuan3D는 **`diff-gaussian-rasterization`, `nvdiffrast`, `flash-attn` 같은 커스텀 CUDA 커널**에
의존합니다. 이들은 HIP 포팅이 없거나 gfx906을 타깃하지 않습니다. VRAM 32GB는 여기서 아무 도움이 안 됩니다.

**권고 (난이도 순):**
1. **TripoSR부터 시도.** 순수 PyTorch에 가까워 트랙 B에서 돌 가능성이 실제로 있습니다. 여기서 3D 생성의 개념을 배우세요.
2. **고품질은 클라우드로.** HuggingFace Spaces(ZeroGPU 무료 티어)에 TRELLIS·Hunyuan3D 공식 데모가 있습니다.
   **"모델 실행"이 아니라 "결과물 활용"(메시 정리, 리토폴로지, Blender 임포트)에 시간을 쓰는 게 학습 효율이 훨씬 높습니다.**
3. 로컬 고품질 3D를 진심으로 원한다면 → 이건 **GPU 교체를 정당화하는 유일한 항목**입니다(24GB NVIDIA).

---

## 6. 과제 5 — RAG (제한된 컨텍스트에서 방대한 문서 참조)

**이 과제가 이 박스의 홈그라운드입니다.** llama.cpp가 이미 빌드돼 있고, 32GB VRAM이 온전히 강점으로 작용합니다.

### 6.1 파이프라인 설계

```
문서 수집 ──▶ 파싱/정제 ──▶ 청킹 ──▶ 임베딩 ──┐
 (위키 덤프)   (HTML→MD)   (구조 인식)         ├─▶ 벡터DB
                                              │
질문 ──▶ 쿼리 확장 ──▶ 하이브리드 검색(BM25 + 밀집) ──▶ 리랭커 ──▶ 상위 5개만 ──▶ LLM ──▶ 답변+출처
```

**핵심은 "LLM에 뭘 넣느냐"가 아니라 "뭘 안 넣느냐"입니다.** 리랭커 단계가 품질의 절반을 결정합니다.

### 6.2 구성 요소 선택

| 역할 | 추천 | 대안 |
|:---|:---|:---|
| **임베딩** | **BGE-M3** (568M, 100+ 언어, 8192 ctx, **밀집·희소·멀티벡터 동시 출력**, MIT) | Qwen3-Embedding-0.6B / 4B / 8B |
| **리랭커** | **bge-reranker-v2-m3** | Qwen3-Reranker-0.6B |
| **벡터DB** | **sqlite-vec** 또는 **LanceDB** (파일 기반, 서버 불필요) | Qdrant (규모가 커지면) |
| **생성 LLM** | 보유 중인 **Qwen3.6-35B-A3B (MoE)** Q4 — MoE라 활성 파라미터가 작아 MI50에서도 빠름 | Qwen3 14B / 32B Dense Q4 |
| **오케스트레이션** | 직접 구현 권장 (200줄이면 됨) | LlamaIndex / Haystack |

> BGE-M3의 "한 모델로 밀집+희소 둘 다" 특성은 하이브리드 검색을 별도 BM25 인덱스 없이 구현하게 해줘서
> 첫 프로젝트로 특히 좋습니다.

### 6.3 VRAM 등급표

| 등급 | VRAM | 구성 |
|:---|:---|:---|
| **최소** | **6–8 GB** | BGE-M3(1GB) + 8B LLM Q4(5GB) + 8k 컨텍스트. 리랭커는 CPU |
| **양호** | **16 GB** | BGE-M3 + 리랭커 상주 + 14B Q4 + 32k 컨텍스트(KV q8_0) |
| **최적** | **32 GB+** | 임베딩·리랭커·생성 LLM(30B급 MoE) **전부 동시 상주** + 128k 컨텍스트. **← MI50이 여기 해당** |

### 6.4 MI50 현실

**과제 5는 MI50 32GB가 24GB RTX 4090보다 유리한 유일한 항목입니다.** 세 모델을 동시에 올려두고
스왑 없이 굴릴 수 있기 때문입니다. `docs/mi50_vulkan_rocm_report.md`의 결론대로
**다중 슬롯 서빙이 필요하면 ROCm/HIP 백엔드, 단일 요청 최고속도면 Vulkan + `KV_TYPE=q8_0` + `--parallel 1`** 로 갈라 쓰세요.

### 6.5 데이터셋: Create 모드 / 스타듀밸리

| 소스 | 수집 방법 | 규모(추정) |
|:---|:---|:---|
| Create 모드 위키 (fandom/공식) | MediaWiki API 덤프 또는 정중한 레이트리밋 크롤 | 수천 페이지 |
| Create 모드 인게임 데이터 | **모드 jar의 `.json` 레시피/태그를 직접 파싱** — 위키보다 정확하고 최신 | 수천 개 |
| 스타듀밸리 위키 | MediaWiki API (`Special:Export`) | 2,000+ 페이지 |
| 스타듀밸리 게임 데이터 | `Content/Data/*.xnb` 언팩 → JSON | 정형 데이터 |

> **청킹 팁:** 게임 위키는 표가 핵심 정보를 담습니다. 표를 통짜로 자르면 RAG 품질이 무너집니다.
> **표는 행 단위로 자연어화**(예: "철 주괴는 용광로에서 철 원석 1개로 10초에 제작된다")해서 별도 청크로 만드세요.
> 이 전처리 하나가 리트리버 성능을 가장 크게 바꿉니다.

> **라이선스 주의:** Fandom·스타듀밸리 위키 문서는 대체로 CC BY-NC-SA입니다.
> 개인 로컬 학습/사용은 문제없지만 **인덱스나 파생물을 공개 배포하지 마세요.** 크롤링 시 레이트리밋 준수.

### 6.6 평가 — 이 과제에서 제일 중요하고 제일 자주 생략되는 단계

질문 30~50개와 정답(또는 정답이 있는 문서)을 손으로 만들어 두세요.
`Recall@5`(정답 문서가 상위 5개에 들어왔는가)와 답변 정확도를 측정하면,
청킹 전략·임베딩 모델·리랭커 유무를 **감이 아니라 숫자로** 비교할 수 있습니다.
이게 RAG 학습의 본체입니다.

---

## 7. 추가로 해볼 만한 과제

우선순위 순으로, **이 박스에서의 실현 가능성**을 함께 표기했습니다.

| # | 과제 | 내용 | VRAM (최소/양호/최적) | MI50 |
|:---|:---|:---|:---|:---|
| 6 | **VLM (이미지→텍스트)** | Qwen3-VL을 llama.cpp로. 게임 스크린샷을 보여주고 "이 기계 뭐야?" → 5번 RAG와 결합 | 8 / 16 / 32 GB | ◎ 매우 유망 |
| 7 | **문서 OCR / 파싱** | dots.ocr, olmOCR, PaddleOCR로 PDF·스캔본을 RAG 입력으로. 5번의 전처리 강화 | 4 / 8 / 16 GB | ○ |
| 8 | **로컬 이미지 검색** | CLIP/SigLIP으로 사진 라이브러리 임베딩 → "작년 여름 바닷가 사진" 자연어 검색 | 2 / 6 / 12 GB | ◎ 쉽고 실용적 |
| 9 | **업스케일 / 복원** | Real-ESRGAN, GFPGAN, SUPIR. 과제 2와 합쳐 완전한 사진 복원 파이프라인 | 4 / 12 / 24 GB | ○ |
| 10 | **비디오 생성** | Wan 2.2, LTX-Video. 5초 480p부터 | 12 / 24 / 48 GB | △ 매우 느림, 인내 필요 |
| 11 | **Agentic LLM / 툴 호출** | 로컬 LLM에 함수 호출·파일 조작 권한. llama.cpp 서버 + 직접 만든 툴 루프 | 8 / 16 / 32 GB | ◎ |
| 12 | **음성 더빙 파이프라인** | 영상 → whisper 전사 → 번역 → 보이스 클론 TTS → 재합성. 3번의 확장판 | 8 / 16 / 24 GB | ○ |
| 13 | **파인튜닝 / LoRA** | SDXL LoRA나 LLM QLoRA 직접 학습 | 12 / 24 / 80 GB | ✗ **gfx906에서 사실상 불가** (bitsandbytes·unsloth·Triton 미지원). 클라우드 권장 |

**범례:** ◎ 적극 추천 · ○ 가능 · △ 되지만 고통스러움 · ✗ 비권장

---

## 8. 권장 실행 순서

각 과제를 독립적으로 벌이지 말고, **환경 리스크가 낮은 것부터 쌓아 올리는 순서**를 제안합니다.

### 1주차 — 확실히 되는 것부터 (트랙 A)
- [ ] **과제 5 RAG 뼈대**: BGE-M3 GGUF + llama.cpp로 임베딩 → sqlite-vec → 기존 35B MoE로 답변.
      문서는 일단 작은 세트(스타듀밸리 위키 100페이지)로 시작.
- [ ] **과제 3 STT**: whisper.cpp Vulkan 빌드 → large-v3-turbo로 한국어 음성 전사.
- [ ] **과제 1 진입**: stable-diffusion.cpp Vulkan 빌드 → SDXL로 첫 이미지. **여기서 실제 생성 시간을 측정해 기록.**

> 1주차가 끝나면 이 박스로 뭘 할 수 있는지에 대한 실측 데이터가 생깁니다. 이후 계획은 그 숫자를 보고 조정하세요.

### 2주차 — PyTorch 생태계 열기 (트랙 B)
- [ ] Docker 설치 → `mixa3607/comfyui-gfx906` 기동 → **`torch.cuda.is_available()` 확인이 첫 관문**
- [ ] **과제 2**: DDColor로 흑백 사진 컬러화 (PyTorch가 gfx906에서 도는지 검증하는 가장 가벼운 테스트)
- [ ] **과제 1 심화**: ComfyUI에서 Chroma / FLUX.1-dev fp16, LoRA·ControlNet
- [ ] **과제 3 TTS**: Chatterbox Multilingual 한국어 음성 합성

### 3주차 — 통합과 확장
- [ ] **과제 5 본편**: Create 모드 + 스타듀밸리 전체 문서, 하이브리드 검색 + 리랭커, **평가셋 50문항 구축**
- [ ] **과제 6 VLM** 붙여서 스크린샷 질의
- [ ] **과제 4는 여기서**: TripoSR 로컬 시도 → 실패 시 미련 없이 HF Spaces로 전환
- [ ] 최종: **로컬 음성 어시스턴트** (STT → RAG LLM → TTS) 통합

---

## 9. 공통 인프라 준비물

```bash
# 1) PyTorch용 별도 파이썬 (conda base의 3.14는 torch 휠이 없음)
conda create -n ml python=3.12 -y

# 2) 모델 다운로드 — hf CLI가 재개·병렬 지원으로 가장 안전
pip install -U "huggingface_hub[cli]"
export HF_HOME=/home/myubuntu/llamacpp/models/.hf   # 769GB 여유 있는 곳으로

# 3) MI50 전력 정책은 매 부팅 후 반드시 high로 (auto면 성능 2.5배 손실 — 실측)
sudo ./mi50_high.sh
```

**디스크 예산 (769GB 여유):** FLUX.1-dev fp16 ~24GB · Chroma ~18GB · SDXL 파생 여러 개 ~30GB ·
Whisper large-v3 ~3GB · ComfyUI 도커 이미지 ~25GB · RAG 인덱스 ~5GB → **총 100GB 남짓. 전혀 부족하지 않습니다.**

---

## 10. 리스크와 대응

| 리스크 | 가능성 | 대응 |
|:---|:---|:---|
| 커뮤니티 gfx906 도커 이미지가 유지보수 중단 | 중 | 동작 확인된 이미지 태그를 **로컬에 `docker save`로 박제** |
| PyTorch가 gfx906에서 산발적으로 죽음 | 중~높 | 트랙 A(ggml 계열)를 항상 대안으로 유지 |
| 3D·파인튜닝이 끝내 안 됨 | 높 | 예정된 결과. HF Spaces / 클라우드 GPU 시간제 대여 |
| 생성 속도가 너무 느려 흥미 상실 | 중 | 1주차에 실측 후 **Turbo/Lightning 계열(4~8스텝) 모델로 전환** |
| MI50 전력 정책 `auto` 복귀 | 확실 | 부팅 시 `mi50_high.sh` 자동 실행(systemd) 등록 |

---

## 11. 한 문단 요약

**MI50 32GB는 "메모리 부자, 소프트웨어 빈자"입니다.** VRAM 용량이 병목인 과제(**RAG, VLM, 대형 이미지 모델 fp16 상주**)에서는
24GB 소비자 카드를 능가하고, 커스텀 CUDA 커널이나 최신 하드웨어 기능이 병목인 과제(**3D 생성, 파인튜닝, 비디오**)에서는
VRAM이 아무 도움이 되지 않습니다. 따라서 **5번(RAG) → 3번(STT/TTS) → 1번(T2I) → 2번(컬러화) → 4번(3D)** 순서로,
확실한 것에서 불확실한 것 방향으로 진행하는 것이 학습 효율과 좌절 방지 양쪽에서 최선입니다.

---

## 참고 자료

- [ML-gfx906 — gfx906용 ROCm/PyTorch/ComfyUI/llama.cpp 빌드](https://github.com/mixa3607/ML-gfx906)
- [AMD GFX906 위키](https://arkprojects.space/wiki/AMD_GFX906)
- [stable-diffusion.cpp — 백엔드 문서](https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/backend.md)
- [stable-diffusion.cpp — 지원 모델](https://deepwiki.com/leejet/stable-diffusion.cpp/1.2-supported-models)
- [DDColor (공식 구현)](https://github.com/piddnad/ddcolor)
- [Hunyuan3D-2 (Tencent)](https://github.com/Tencent-Hunyuan/Hunyuan3D-2)
- [오픈소스 이미지 생성 모델 가이드 2026 (BentoML)](https://www.bentoml.com/blog/a-guide-to-open-source-image-generation-models)
- [오픈소스 TTS 모델 2026 (BentoML)](https://www.bentoml.com/blog/exploring-the-world-of-open-source-text-to-speech-models)
- [오픈소스 STT 벤치마크 2026 (Northflank)](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks)
- [오픈소스 임베딩 모델 2026 (BentoML)](https://www.bentoml.com/blog/a-guide-to-open-source-embedding-models)
- [ROCm 디바이스 지원 위시리스트 (gfx906 논의)](https://github.com/ROCm/ROCm/discussions/4276)
- 내부 문서: [mi50_vulkan_rocm_report.md](mi50_vulkan_rocm_report.md), [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
