# abliterated Flash-Next 자가 양자화 — 리마인더

**충분한 컴퓨팅(B200 4장급 · 수 시간)이 확보됐을 때** 꺼내 보는 문서다.
지금 당장 할 일이 아니고, 아래 §0 을 먼저 통과해야 시작할 가치가 있다.

관련: [`flash_next_plan.md`](flash_next_plan.md) · [`flash_next_run.md`](flash_next_run.md)

## 0. 시작 전 — 이거부터 확인 (공짜)

이 셋 중 하나라도 "예" 면 **이 프로젝트는 필요 없다.**

1. AtomicChat 3.84/4.27 이 실제 용도에서 거부하지 않는다 → 그냥 그걸 쓴다
2. `mradermacher i1-Q3_K_S` (88.8 GB, 본체 60.0 GB) 품질이 충분하다 → 끝
3. 애초에 uncensored 가 필요 없었다 → AtomicChat 4.27 이 정답

## 1. 왜 하는가

**아무도 안 만든 조합 하나** — abliterated 가중치 + 비대칭 레시피.

공개된 abliterated 빌드는 전부 **균일 양자화**라 본체를 올리면 64 GiB 를 넘긴다.
그래서 이 박스에 들어가는 건 IQ3 급뿐이다.

| 빌드 | 총 | 본체 (VRAM) | 64 GiB = 68.72 GB |
|:---|---:|---:|:---|
| orcarouter IQ4_XS · mradermacher i1-IQ4_XS | 97.5 GB | 68.7 | ✗ |
| cygnal IQ4XS-NGQ4 | 98.4 GB | ~69.4 | ✗ |
| orcarouter IQ3_M | 89.5 GB | 60.7 | ✓ |
| mradermacher i1-Q3_K_S | 88.8 GB | 60.0 | ✓ ← 현재 최선 |
| **직접 만든다면** | ~90 GB | **~61** | ✓ **품질만 다름** |

핵심은 **테이블에 비트를 더 주고 전문가에서 아끼는 것**이다. 테이블은 SSD 에
페이징되므로(실측 속도 대가 <1%) 그쪽 비트는 사실상 공짜고, VRAM 에 상주하는
전문가가 진짜 희소 자원이다. 공개 빌드 중 이걸 한 건 base 모델의 AtomicChat 뿐이다.

기대 상금: AtomicChat 이 같은 파일 크기에서 측정한 **KLD −63% · top-1 +6.8%p**.

## 2. 컴퓨팅이 푸는 것 / 안 푸는 것

| | 로컬만 | B200 4장 |
|:---|:---|:---|
| abliterated BF16 로 imatrix | ✗ 360 GB · 몇 주 | ✓ 768 GB HBM · **~3 시간** |
| **BF16 참조 로짓 = 검증 수단** | ✗ 같은 이유 | ✓ **같은 박스에 BF16 이 있다** |
| 밴드 배치용 활성도 통계 | ✗ | ✓ `llama-imatrix --show-statistics` |

두 번째가 진짜 이득이다. 이게 없으면 "좋아졌는지 모르는 채로" 끝난다.

**하드웨어로 안 풀리는 것 두 개** — 설계 제약이라 그냥 받아들인다.

- **PLE 테이블은 imatrix 를 못 받는다.** `GET_ROWS` 텐서라 수집기가
  `MUL_MAT`/`MUL_MAT_ID` 만 보고 지나친다(`tools/imatrix/imatrix.cpp:246`).
  51.2B 는 영구히 눈감고 양자화 → 대신 **날 비트로 때운다**(Q5_1, 6.0 bpw).
- **`moe_intermediate_size=640` 바닥.** `ffn_down_exps`(모델의 23%)는 블록-32
  타입만 되고 **4.25비트가 하한**이다. 본체를 얼마나 줄일 수 있는지의 물리 한계.

## 3. 순서

```
① orcarouter/Qwen3.8-Flash-Next-Uncensored  BF16 safetensors 360 GB  →  빌린 박스
② convert_hf_to_gguf.py  →  BF16 GGUF
③ llama-imatrix          →  내 imatrix (abliterated 기준)     ~3 h
④ --show-statistics      →  이 모델의 에너지가 몰린 레이어 확인
⑤ llama-quantize --imatrix + --tensor-type  →  목표 본체 ~61 GB
⑥ 같은 박스에서 KLD/top-1 비교  →  내 빌드 vs i1-Q3_K_S vs IQ3_M
⑦ 최종 GGUF ~90 GB 만 내려받는다
```

**전부 빌린 박스에서 한다.** 로컬로 내려오는 건 ⑦ 하나뿐이다.

### 출발점 레시피

AtomicChat 이 공개한 것(base 모델용)을 **뼈대로만** 쓴다. 밴드 위치는 ④ 로 다시 정한다 —
abliteration 이 잔차 스트림을 건드렸으니 base 의 "0-3, 40-47" 이 그대로일 이유가 없고,
**그걸 확인하는 것 자체가 이 프로젝트에서 유일하게 새로운 데이터다.**

```bash
llama-quantize --imatrix <내_imatrix>.gguf \
  --tensor-type 'blk\.(<④에서 정한 밴드>)\.ffn_(gate|up)_exps=iq3_s' \
  --tensor-type 'ffn_down_exps=iq4_nl' \
  --tensor-type 'ffn_gate_exps=iq2_s' \
  --tensor-type 'ffn_up_exps=iq2_s' \
  --tensor-type 'per_layer_token_embd=q5_1' \
  <BF16>.gguf out.gguf q8_0
llama-gguf-split --split --split-max-size 2G out.gguf split/prefix
```

목표: **본체 ≤ 61 GB** (VRAM 68.72 GB − 컨텍스트/컴퓨트 실측 1.7 GB − 여유).
테이블은 Q5_1 로 고정 38.4 GB, SSD 로 간다.

## 4. 챙길 것

- **코퍼스.** AtomicChat 이 공개했다(`AtomicChat/calib-corpora`, 497만 토큰).
  같은 채팅 템플릿이라 그대로 쓸 수 있지만, **abliterated 모델에는 거부가 제거된
  방향을 실제로 태우는 코퍼스가 맞다.** 안 그러면 imatrix 가 정확히 abliteration 이
  바꾼 부분을 과소평가한다. 이건 블로커가 아니라 설계 선택.
- **디스크.** 빌린 박스에 최소 800 GB (safetensors 360 + BF16 GGUF 360 + 출력 90).
- **llama.cpp.** PR #27742 이후 판본(`qwen4exp`). 로컬은 b10717 로 검증됨.
- **파일 이름.** `llama-gguf-split` 결과의 `-NNNNN-of-NNNNN.gguf` 접미사는 규약이다.
  떼면 `invalid split file name` 으로 죽는다.

## 5. 성공 기준

"현존 최고"라는 말은 **"64 GiB VRAM 에 들어가는 abliterated 중"** 이라는 뜻이다.
128 GB 있는 사람은 orcarouter Q4_K_M 을 그냥 돌려서 이긴다. 그래도 이건 진짜 주장이고,
⑥ 에서 **같은 BF16 참조**에 대고 잰 KLD·top-1 로 뒷받침할 수 있다.

숫자를 남길 때는 [`flash_next_plan.md`](flash_next_plan.md) §11 양식을 따른다 —
참조·코퍼스·기계를 같이 안 적으면 나중에 비교가 안 된다.
