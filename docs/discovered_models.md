# 발견한 모델 목록 및 실전 평가

OpenClaw 에이전트용 로컬 LLM을 찾는 과정에서 발견하고 테스트한 모든 모델을 기록합니다.
**실제로 돌려보고 평가한 모델만** 포함합니다.

---

## 테스트 환경

| 항목 | 사양 |
|:---|:---|
| **GPU** | NVIDIA RTX 4060 Ti 16GB (SNU_SERVER) |
| **Ollama** | v0.17.0 |
| **llama.cpp** | 소스 빌드 (CUDA 12.6) |
| **클라이언트** | OpenClaw (openai-completions API) |
| **평가 항목** | 한국어 응답, 도구 호출(`tool_calls` 필드 파싱), VRAM 사용량 |

---

## 실전 테스트 결과 요약

| # | 모델 | 엔진 | 한국어 | 도구 호출 | VRAM | 종합 |
|:---:|:---|:---:|:---:|:---:|:---:|:---:|
| 1 | qwen2.5-coder:14b (공식) | Ollama | ✅ | ❌ | ✅ | ⭐⭐ |
| 2 | dagbs/qwen2.5-coder-14b:q4_k_m | Ollama | ✅ | ❌ | ✅ | ⭐⭐ |
| 3 | dagbs/qwen2.5-coder-14b:iq4_xs | Ollama | ✅ | ❌ | ✅ | ⭐ |
| 4 | qwen14b-abliterated-fixed | Ollama | ✅ | ❌ | ✅ | ⭐⭐ |
| 5 | mistral-24b-snu (수동 GGUF) | Ollama | ✅ | ❌ | ⚠️ | ⭐ |
| 6 | Mistral 24B IQ4_XS | llama.cpp | ✅ | ⚠️ | ⚠️ | ⭐⭐ |
| 7 | Qwen3.5-35B-A3B-Uncensored (MoE) | llama-server | ✅ | ❌ | ✅ | ⭐ (속도 전용) |
| 8 | OmniCoder-9B-Claude-Opus-Distill | llama-server | ⚠️ | - | ✅ | ❌ (심각한 할루시네이션) |
| 9 | Huihui-Qwen3.5-35B-A3B (i1) | llama-server | ✅ | ⚠️ | ✅ | ⭐⭐⭐ (속도+무검열) |
| 10 | Qwen3.5-35B-Claude-Distill (i1) | llama-server | ✅ | ✅ | ✅ | ⭐⭐⭐⭐ (지능+정직) |

---

## 상세 평가

### 1. qwen2.5-coder:14b (Ollama 공식)

| 항목 | 결과 |
|:---|:---|
| **출처** | `ollama pull qwen2.5-coder:14b` |
| **양자화** | Q4_K_M (Ollama 기본) |
| **용량** | ~9.0GB |
| **한국어** | ✅ 정상 응답. 자연스러운 한국어 대화 가능. |
| **도구 호출** | ❌ `tool_calls: null`. content 필드에 JSON 텍스트 출력. 네이티브 `/api/chat`에서도 동일. |
| **비고** | Ollama 공식 레지스트리에서 pull → TEMPLATE 포함. 그러나 모델 자체가 `<tool_call>` 태그를 안정적으로 출력하지 않아 도구 호출 파싱 실패. |

### 2. dagbs/qwen2.5-coder-14b-instruct-abliterated:q4_k_m

| 항목 | 결과 |
|:---|:---|
| **출처** | `ollama pull dagbs/qwen2.5-coder-14b-instruct-abliterated:q4_k_m` |
| **양자화** | Q4_K_M |
| **용량** | ~9.0GB |
| **한국어** | ✅ 정상 응답. 공식 모델과 유사한 품질. |
| **도구 호출** | ❌ `tool_calls: null`. 공식 TEMPLATE을 씌운 후에도 동일. 모델이 태그 없이 순수 JSON만 출력. |
| **검열 해제** | ✅ Abliterated (dagbs 커뮤니티 제작) |
| **비고** | 커뮤니티 모델이라 TEMPLATE이 원래 없었으나, 공식 qwen2.5-coder:14b의 TEMPLATE을 추출하여 `qwen14b-abliterated-fixed`로 재등록 테스트. 결과 동일 — 모델 자체의 한계. |

### 3. dagbs/qwen2.5-coder-14b-instruct-abliterated:iq4_xs

| 항목 | 결과 |
|:---|:---|
| **출처** | `ollama pull dagbs/qwen2.5-coder-14b-instruct-abliterated:iq4_xs` |
| **양자화** | IQ4_XS |
| **용량** | ~8.1GB |
| **한국어** | ✅ 응답 가능하나 q4_k_m 대비 약간 불안정. |
| **도구 호출** | ❌ content에 `<tools>` 태그 자체를 그대로 출력하는 등 q4_k_m보다 형식이 더 엉뚱함. |
| **검열 해제** | ✅ Abliterated |
| **비고** | IQ4_XS 양자화로 인한 지능 하락이 도구 호출 형식 준수에 영향을 준 것으로 추정. |

### 4. qwen14b-abliterated-fixed (커스텀)

| 항목 | 결과 |
|:---|:---|
| **출처** | dagbs GGUF (q4_k_m) + 공식 qwen2.5-coder:14b TEMPLATE → `ollama create` |
| **양자화** | Q4_K_M |
| **용량** | ~9.0GB |
| **한국어** | ✅ 정상 응답. |
| **도구 호출** | ❌ `tool_calls: null`. Ollama `/v1/chat/completions`와 네이티브 `/api/chat` 모두에서 파싱 실패. content에 JSON만 출력. |
| **비고** | **핵심 실험 결과:** 공식 TEMPLATE을 씌워도 Qwen2.5 Coder 모델 자체가 `<tool_call>` 태그를 학습하지 못했기 때문에 해결 불가. 이를 통해 "템플릿 문제 vs 모델 문제"를 확정할 수 있었음. |

### 5. mistral-24b-snu (수동 GGUF 등록)

| 항목 | 결과 |
|:---|:---|
| **출처** | HuggingFace에서 Mistral-Small-24B-Instruct-2501-abliterated IQ4_XS GGUF 다운로드 → `ollama create` |
| **양자화** | IQ4_XS |
| **용량** | ~12GB |
| **한국어** | ✅ 한국어 매우 우수. Qwen 14B보다 자연스러운 한국어. |
| **도구 호출** | ❌ `"does not support tools"` 에러. 수동 GGUF 등록이라 Ollama Manifest에 도구 지원 플래그가 없음. |
| **VRAM** | ⚠️ 모델 12GB + KV 캐시 → 16GB VRAM에서 빡빡. 32k 컨텍스트는 OOM 발생. |
| **비고** | TEMPLATE 없이 등록했으므로 도구 기능이 아예 비활성화됨. 공식 Mistral TEMPLATE을 씌우면 해결 가능하나, VRAM 여유가 부족하여 에이전트 용도로는 한계. |

### 6. Mistral Small 24B (IQ4_XS) — llama.cpp 서빙

| 항목 | 결과 |
|:---|:---|
| **출처** | mradermacher/Mistral-Small-24B-Instruct-2501-abliterated-GGUF (HuggingFace) |
| **양자화** | IQ4_XS |
| **용량** | ~12GB |
| **엔진** | llama.cpp (소스 빌드, `--chat-template chatml`) |
| **한국어** | ✅ 매우 우수. 자연스럽고 유창한 한국어. |
| **도구 호출** | ⚠️ llama.cpp는 Ollama처럼 `tool_calls` 파싱을 하지 않음. 클라이언트(OpenClaw)가 직접 파싱해야 함. OpenClaw의 `openai-completions` API 타입에서는 동작 미확인. |
| **VRAM** | ⚠️ 모델 12GB + KV 캐시. `-c 8192`(8k 컨텍스트)에서는 안정. 20k까지는 가능하나 32k는 OOM. |
| **비고** | Mistral의 내장 Jinja 템플릿이 `tool`/`developer` role을 거부하여 `--chat-template chatml` 필수. chatml 적용 후 OpenClaw와 통신은 성공했으나, 도구 호출 파싱은 미완성. |

### 7. Qwen3.5-35B-A3B-Uncensored (HauhauCS-Aggressive)

| 항목 | 결과 |
|:---|:---|
| **출처** | HauhauCS (GGUF: IQ2_M) |
| **엔진** | llama-server (llama.cpp 기반) |
| **한국어** | ✅ 가능하나 가끔 문맥이 어긋날 수 있음. |
| **속도** | 🔥 **극단적으로 빠름 (약 99 tok/s)** — RTX 4060 Ti 환경에서 모델 체급(35B) 대비 압도적인 성능. |
| **검열** | 🔓 **기계적 거부 없음** — 폭탄 제조 방법 등 민감한 질문에도 거부 없이 답변을 시작함 (단, 답변의 사실 정보 신뢰도는 낮음). |
| **문제점 1** | ⚠️ **Overthinking** — 답변 과정이 비정상적으로 길어지거나 무한 루프에 빠짐. |
| **문제점 2** | ⚠️ **무한 토큰 생성** — 특정 문단이나 태그가 수동으로 응답을 중단하기 전까지 무한 반복 출력됨. |
| **비고** | MoE(Mix of Experts) 구조의 장점(속도)과 무검열의 특징이 극대화된 모델이나, 통제가 어려운 생성 불안정성 때문에 에이전트 자동화 용도로 쓰기엔 부적합. 단순 "지식/아이디어 브레인스토밍" 용도로 적합. |
### 8. OmniCoder-9B-Claude-Opus-Distill (armand0e)

| 항목 | 결과 |
|:---|:---|
| **출처** | [armand0e](https://huggingface.co/armand0e/OmniCoder-9B-Claude-Opus-High-Reasoning-Distill-GGUF) (GGUF: Q4_K_M) |
| **엔진** | llama-server (llama.cpp) |
| **한국어** | ⚠️ **보통 (할루시네이션 심각)** — 유창하게 말하지만 사실과 다른 답변을 늘어놓음. |
| **문제점 1** | 🚨 **지독한 자아 분열** — 스스로를 **"Qwen 3.5 (MoE)"**라 소개하며, 있지도 않은 오디오/이미지 분석 기능이 있다고 주장함. |
| **문제점 2** | ⚠️ **기술적 허위 답변** — 툴 사용 능력 질문에 대해 실제 구현 여부와 상관없이 마케팅 문구만 나열함. |
| **장점** | ✅ **Overthinking 없음** — 헛소리는 하지만 답변 속도는 매우 일정함. |
| **비고** | 9B Dense 모델임에도 35B MoE 모델인 척하는 등 신뢰도가 매우 낮음. 에이전트 자동화 용도로는 **사용 불가(Unusable)** 판정. |

### 9. Huihui-Qwen3.5-35B-A3B-abliterated (mradermacher)

| 항목 | 결과 |
|:---|:---|
| **출처** | [mradermacher](https://huggingface.co/mradermacher/Huihui-Qwen3.5-35B-A3B-abliterated-i1-GGUF) (GGUF: IQ2_M) |
| **엔진** | llama-server (MoE 최적화: 16k 컨텍스트) |
| **속도** | 🚀 **~100 tok/s** — RTX 4060 Ti 16GB에서 매우 쾌적. |
| **한국어** | ✅ **우수** — 자연스럽고 풍부한 답변. 사고 과정(Reasoning)이 탄탄함. |
| **비고** | 무검열(Abliterated) 버전으로 검열 없이 자유로운 답변이 가능. 다만 간혹 "실시간" 기능을 가진 척하는 가벼운 할루시네이션 있음. |

### 10. Qwen3.5-35B-A3B-Claude-Distill (mradermacher)

| 항목 | 결과 |
|:---|:---|
| **출처** | [mradermacher](https://huggingface.co/mradermacher/Qwen3.5-35B-A3B-Claude-4.6-Opus-Reasoning-Distilled-i1-GGUF) (GGUF: IQ2_M) |
| **엔진** | llama-server (16k 컨텍스트) |
| **특이사항** | 💎 **높은 정직성(Honesty)** — 툴 사용 능력을 물었을 때, 있지도 않은 툴이 있다고 속이지 않고 "텍스트 모델이라 외부 툴 접근이 안 된다"라고 정확히 답변함. |
| **성능** | 🚀 **~101 tok/s** — 추론 품질과 속도의 균형이 매우 뛰어남. |
| **비고** | 현재까지 테스트한 로컬 모델 중 에이전트 자동화(MCP 등) 활용도가 가장 높을 것으로 기대되는 **최고의 모델**. |

---

## 💡 Lessons Learned (추가)

-   **Persona Hallucination 주의**: 모델 체급(9B vs 35B)이나 아키텍처(Dense vs MoE)를 모델이 스스로 다르게 인지하고 있을 수 있음 (특히 OmniCoder). 모델의 자기 소개는 믿지 말고 메타데이터로 확인 필수.
-   **정직함(Honesty)의 가치**: 인공지능이 "몰라요" 혹은 "불가능해요"를 정확히 말해주는 것이 에이전트 설계에서 훨씬 중요함 (Claude-Distill 버전의 압승 사유).
-   **양자화 무결성**: 다운로드 도중 `wget -c` 등으로 인해 파일 용량이 비대해지면(11GB -> 17GB) 추론 결과에 `?` 루프 등 쓰레기 토큰이 섞일 수 있으므로 파일 크기 검증 필수.
---

## 미테스트 후보 모델

실제로 돌려보진 않았지만 유력한 후보로 발견한 모델들입니다.

### Tesslate OmniCoder-9B (bartowski)
- **출처**: [bartowski/Tesslate_OmniCoder-9B-GGUF](https://huggingface.co/bartowski/Tesslate_OmniCoder-9B-GGUF)
- **기대**: OmniCoder 9B의 GGUF 버전.

### OmniCoder-9B Uncensored (LuffyTheFox) ⭐
- **출처**: [LuffyTheFox/Omnicoder-Claude-4.6-Opus-Uncensored-GGUF](https://huggingface.co/LuffyTheFox/Omnicoder-Claude-4.6-Opus-Uncensored-GGUF)
- **양자화**: Q8_0 (~9.7GB 추정)
- **다운로드**: `https://huggingface.co/LuffyTheFox/Omnicoder-Claude-4.6-Opus-Uncensored-GGUF/resolve/main/omnicoder-9b-q8_0.gguf?download=true`
- **기대**: 기존 armand0e 버전의 **무검열(Abliterated)** 파생 모델. Q8_0은 거의 FP16 수준의 정밀도로, 양자화로 인한 지능 손실이 최소화됨. 이전에 경험한 Persona Hallucination이 줄어들 수 있음.
- **주의**: RTX 4060 Ti 16GB에서 9.7GB + 16k KV 캐시 → 약 11GB 예상으로 여유 있게 돌아갈 것으로 보임.

### OmniCoder-9B i1-IQ4_NL (mradermacher) ⭐
- **출처**: [mradermacher/OmniCoder-9B-i1-GGUF](https://huggingface.co/mradermacher/OmniCoder-9B-i1-GGUF)
- **양자화**: i1-IQ4_NL (~6GB 추정)
- **다운로드**: `https://huggingface.co/mradermacher/OmniCoder-9B-i1-GGUF/resolve/main/OmniCoder-9B.i1-IQ4_NL.gguf?download=true`
- **기대**: mradermacher의 **i1 Imatrix 최적화** 양자화로, 동일 용량 대비 Q4_K_M보다 중요한 가중치가 더 잘 보존됨. 현재 쓰는 armand0e Q4_K_M 버전의 할루시네이션이 양자화 품질 문제라면 이 버전에서 개선될 수 있음.

### Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-v2 (Jackrong)
- **출처**: [Jackrong/Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-v2-GGUF](https://huggingface.co/Jackrong/Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-v2-GGUF)
- **기대**: Qwen3.5 9B 기반 추론 증류 v2 GGUF.


### Qwen3-14B-Claude-4.5-Opus-Distill (TeichAI) ⭐
- **출처**: `TeichAI/Qwen3-14B-Claude-4.5-Opus-High-Reasoning-Distill-GGUF`
- **양자화**: Q4_K_M (~9GB)
- **기대**: Qwen3의 몸체에 **Claude 4.5 Opus**의 사고방식을 이식(Distill). 현재 모델보다 더 높은 지능과 인격적인 답변 기대.
- **참고**: 도구 호출 안정성을 유지하면서 지능만 업그레이드할 수 있는 가장 유력한 후보.

### Tri-21B-Think (TrillionLabs)
- **출처**: `trillionlabs/Tri-21B-Think` (GGUF 확인 필요)
- **체급**: 21B (14B와 24B 사이의 절묘한 밸런스)
- **기대**: "Think"가 붙은 만큼 DeepSeek-R1 스타일의 고도화된 추론 능력 제공.

### Dolphin-Mistral-24B (Venice Edition)
- **출처**: `dphn/Dolphin-Mistral-24B-Venice-Edition`
- **기대**: 전통의 무검열/지시 이행 강자 Dolphin 시리즈. 16GB VRAM에서 돌릴 수 있는 거의 최대 체급.

### Gemma 3 12B IT Heretic
- **출처**: `p-e-w/gemma-3-12b-it-heretic`
- **기대**: 구글 Gemma 3 12B의 또 다른 무검열(Heretic) 버전. mlabonne 버전과 비교 테스트 가치 있음.

---

## 교훈 요약

1. **Qwen2.5 Coder는 도구 호출 불가**: 공식이든 abliterated든, TEMPLATE을 씌우든 안 씌우든, `<tool_call>` 태그를 안정적으로 출력하지 않음. 모델 학습의 한계.
2. **수동 GGUF 등록 시 TEMPLATE 필수**: Ollama에 GGUF를 `FROM`만으로 등록하면 "does not support tools" 에러. 공식 모델의 TEMPLATE을 추출하여 씌워야 함.
3. **24B 모델은 16GB VRAM에서 빡빡**: Mistral 24B IQ4_XS(12GB)는 돌아가지만 컨텍스트 윈도우를 20k 이하로 제한해야 함.
4. **Qwen3.5-35B MoE의 양면성**: MoE 구조 덕분에 99 tok/s라는 경이로운 속도를 보여주나, 무한 루프와 생성 반복(Overthinking) 이슈가 심각하여 에이전트 용도로는 제어가 어려움.
5. **다음 테스트 우선순위**: Qwen3 14B abliterated (도구 호출 해결 기대) → Gemma 3 12B abliterated-v2 (가벼운 백업)

---
마지막 업데이트: 2026-03-20
