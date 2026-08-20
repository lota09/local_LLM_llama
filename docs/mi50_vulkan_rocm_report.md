# AMD Radeon Instinct MI50(gfx906)에서의 llama.cpp 백엔드 실증 연구

**Vulkan(RADV)과 ROCm/HIP 백엔드의 구축 과정, 트러블슈팅, 성능 특성 비교**

*작성일: 2026-07-29 · 대상 하드웨어: AMD Radeon Instinct MI50 32GB (Vega 20 / gfx906)*

---

## 초록 (Abstract)

공식 ROCm 지원이 종료된 AMD MI50(gfx906) GPU에서 llama.cpp를 구동하기 위해 Vulkan(Mesa RADV)과 ROCm/HIP 두 백엔드를 각각 구축하고 성능을 비교 측정했다.

주요 결과는 세 가지다.

1. **전력 관리 정책이 성능을 2.5배 좌우한다.** 기본 `auto` DPM 정책에서 이 카드는 추론 부하를 감지하지 못하고 메모리 클럭을 최대치의 35%(350MHz)에 고정한다. `high`로 강제하면 토큰 생성이 6.28 → 15.9 t/s(2.5배), 프롬프트 처리가 41.8 → 346.7 t/s(8.3배)로 상승한다.

2. **Vulkan 백엔드는 특정 조건에서 토큰 생성이 10배 가까이 무너진다.** 채운 토큰을 고정한 통제 실험에서 두 가지 독립적인 조건을 확인했다. (a) 양자화 KV(`q4_0`)와 컨텍스트 20,480 이상의 조합에서 69.9 → 8.9 t/s, (b) 슬롯 2개 이상(`--parallel > 1`)에서 55.1 → 5.5 t/s. 두 경우 모두 저하된 값이 컨텍스트 크기와 무관하게 일정해, 연산량 증가가 아니라 고정 비용의 느린 경로로 빠지는 것으로 보인다. **ROCm/HIP는 두 조건 어디에도 영향받지 않는다**(슬롯 4개에서 52.33, 1개에서 52.60 t/s).

3. **공식 지원 종료는 바이너리 부재와 동의어가 아니다.** ROCm 7.14는 25개 아키텍처용 rocBLAS 커널 2,153개를 포함하지만 gfx906용은 0개다. 반면 ROCm 6.2.0 패키지에는 gfx906 커널 156개가 그대로 존재하여, 버전을 선택적으로 조합하면 HIP 백엔드 구축이 가능하다.

최종적으로 두 백엔드 모두 구축에 성공했으며, 이 과정에서 확인된 10건의 실패 원인과 해결책을 기록했다.

---

## 1. 실험 환경

### 1.1 하드웨어

| 항목 | 사양 |
|:---|:---|
| **GPU** | AMD Radeon Instinct MI50 32GB |
| GPU PCI ID | `1002:66a0` — Vega 20 [Radeon Pro/Radeon Instinct] |
| GPU 아키텍처 | gfx906 (`gfx906:sramecc+:xnack-`) |
| VRAM | 34,342,961,152 bytes (32,752 MiB), HBM2 |
| Compute Unit | 60 CU × 4 SIMD, Wave Size 64 |
| L2 캐시 | 8,192 KB |
| 최대 코어클럭(sclk) | 1,800 MHz |
| 최대 메모리클럭(mclk) | 1,000 MHz |
| **VBIOS** | `113-D1640200-043` (V420) |
| **전력 상한** | 178.0 W |
| PCIe 링크 | **PCIe 3.0 ×4** (칩셋 경유 슬롯) — 아래 참고 |
| CPU | Intel Core i7-9700K @ 3.60GHz (8C/8T) |
| 시스템 RAM | 31 GiB |
| 보조 GPU | Intel UHD Graphics 630 (`8086:3e98`, iGPU) |

> **참고 — PCIe 배치:** GPU는 CPU 직결 x16 슬롯이 아니라 칩셋(PCH) 루트포트를 경유하는 x4 슬롯에 연결되어 있다.
> ```
> 00:1b.4  Cannon Lake PCH 루트포트      최대 8.0 GT/s ×4    ← 실제 병목
> 02:00.0  MI50 카드 업스트림 브리지      최대 16.0 GT/s ×16
> 04:00.0  GPU                           16.0 GT/s ×16
> ```
> 카드 자체는 PCIe 4.0 ×16(~31.5 GB/s)이 가능하나 슬롯이 PCIe 3.0 ×4(~3.9 GB/s)로 제한한다.
> 추론 중에는 모델이 VRAM에 상주하므로 영향이 작지만, 21 GB 모델의 초기 로딩 시간에는 직접적으로 작용한다.
> (`rocm-smi`가 보고하는 `pcie clock level`은 DPM 전력 상태이지 링크 상한이 아니다.)

> **참고 — VBIOS에 관한 관찰:** 이 카드는 디스플레이 출력이 가능한 V420 VBIOS가 적용되어 있으며 전력 상한이 178W로 보고된다. 판매자가 제시한 스크린샷의 VBIOS 문자열(`113-D1640200-043`)과 완전히 일치했다. 후술하듯 V420 VBIOS는 저전력 상태 고정 현상을 방지하지 못한다(§4.1).

### 1.2 소프트웨어

| 항목 | 버전 |
|:---|:---|
| OS | Ubuntu 24.04.2 LTS (noble) |
| 커널 | 7.0.0-28-generic |
| 커널 드라이버 | in-tree `amdgpu` |
| **Vulkan 스택** | |
| Mesa Vulkan 드라이버 (RADV) | 25.2.8-0ubuntu0.24.04.2 |
| libvulkan1 / libvulkan-dev | 1.3.275.0-1build1 |
| glslc (shaderc) | 2023.8-1build1 |
| glslang-tools | 15.1.0-2~ubuntu0.24.04.2 |
| spirv-headers | 1.6.1+1.4.309.0 |
| **ROCm 스택 (최종 채택 조합)** | |
| hip-runtime-amd / hip-dev | 6.2.41133.60200-66~24.04 |
| rocblas | 4.2.0.60200-66~24.04 (ROCm 6.2.0) |
| hipblas | 2.2.0.60200-66~24.04 |
| hipcc | 1.1.1.60200-66~24.04 |
| rocm-device-libs | 1.0.0.60200-66~24.04 |
| rocm-llvm (HIP clang) | 18.0.0.24292.60200 (AMD clang 18.0.0git, roc-6.2.0) |
| (설치되었으나 미사용) amdrocm-base | 7.14.0~pre3-29052710811 |
| **llama.cpp** | 릴리스 태그 `b10176`, 커밋 `f5b9bd3` (ggml 0.17.0) |

### 1.3 시험 모델

| 항목 | 값 |
|:---|:---|
| 모델 | Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive |
| 아키텍처 | `qwen35moe` — MoE, 총 34.66 B / 활성 약 3 B (A3B) |
| 양자화 | Q4_K_M |
| 파일 크기 | 19.70 GiB (21,166,758,016 bytes) |
| 학습 컨텍스트(`context_length`) | **262,144** |
| 레이어 수(`block_count`) | 40 |
| 어텐션 헤드 | 16 (KV 헤드 2 — GQA 8:1) |
| K/V 길이 | 각 256 |
| 전문가 수 | 256개 중 8개 활성 |
| 멀티모달 프로젝션 | `mmproj-…-f16.gguf` (858 MB, 일부 실험에서만 사용) |
| 보조 시험 모델 | Qwen2.5-0.5B-Instruct Q4_K_M (469 MB) — 초기 파이프라인 검증용 |

---

## 2. 방법론

### 2.1 측정 도구와 지표

두 가지 경로로 측정했으며, 이 둘의 불일치가 본 연구의 핵심 발견으로 이어졌다(§4.2).

- **`llama-bench`**: 합성 벤치마크. `pp512`(프롬프트 512토큰 처리), `tg128`(128토큰 생성). 컨텍스트는 측정에 필요한 최소값만 자동 할당.
- **`llama-server` + HTTP 요청**: 실사용 경로. `/v1/chat/completions`의 `timings.predicted_per_second`를 채택. 컨텍스트를 `-c`로 명시 할당.

지표는 **tg (token generation, t/s)** 와 **pp (prompt processing, t/s)** 로 구분한다. 전자는 지연시간 지배적, 후자는 처리량 지배적이므로 병목 해석이 다르다.

### 2.2 통제 변인

모든 비교 측정에서 다음을 고정했다.

- GPU 클럭 정책: `power_dpm_force_performance_level = high` (§4.1 발견 이후 전 구간 적용)
- 동일 모델 파일 (하드링크로 단일 inode 공유, 파일 차이 원천 배제)
- `-ngl 99` (전 레이어 GPU 오프로드)
- 서버 측정 시: `-fa on`, 동일 프롬프트, `temperature=0`

  KV 타입과 슬롯 수는 **처음에는 `-ctk/-ctv q4_0`, `--parallel 1`로 고정**했으나, 이후 이 둘이 각각 성능을 좌우하는 변수임이 드러나 §5.3·§5.4에서는 의도적으로 변화시켰다. 각 표에 해당 조건을 명시한다.

### 2.3 재현용 스크립트

컨텍스트 크기와 백엔드를 파라미터로 받아 서버 기동 → 헬스체크 → 단일 요청 → 타이밍 추출 → 정리를 자동화했다.

```bash
#!/usr/bin/env bash
# test_be.sh <vulkan|hip> <context_size>
BE="${1:-vulkan}"; CTX="${2:-4096}"
if [ "$BE" = "hip" ]; then
  BIN=/tmp/llama_build_hip/build/bin; LDP="$BIN:/opt/rocm-6.2.0/lib"; DEVARG="--device ROCm0"
else
  BIN=/tmp/llama_build/build/bin;     LDP="$BIN";                    DEVARG="--device Vulkan1"
fi
pkill -9 -f llama-server 2>/dev/null; sleep 2
export LD_LIBRARY_PATH="$LDP"
nohup "$BIN/llama-server" -m "$MODEL" $DEVARG -ngl 99 \
  --port 8099 --host 127.0.0.1 -c "$CTX" --parallel 1 -fa on -ctk q4_0 -ctv q4_0 > "$LOG" 2>&1 &
# … /health 폴링 후 …
curl -s http://127.0.0.1:8099/v1/chat/completions -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Count from 1 to 100, one number per line."}],
       "max_tokens":200,"temperature":0}' \
  | python3 -c "import sys,json; t=json.load(sys.stdin)['timings']; \
                print(f\"tg={t['predicted_per_second']:.2f} t/s\")"
```

---

## 3. 구축 과정

### 3.1 1단계 — 하드웨어 인식 확인

초기 상태에서 GPU는 커널 드라이버에 의해 정상 인식되었으나 ROCm 유저스페이스 스택은 전무했다.

```
$ lspci | grep -i vga
00:02.0 VGA compatible controller: Intel Corporation CoffeeLake-S GT2 [UHD Graphics 630] (rev 02)
04:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Vega 20 [Radeon Pro/Radeon Instinct]

$ lsmod | grep amdgpu
amdgpu              21188608  1

$ cat /sys/class/drm/card2/device/mem_info_vram_total
34342961152                      # = 32 GiB 확인

$ rocm-smi
rocm-smi: command not found      # ROCm 미설치
```

### 3.2 2단계 — Vulkan 백엔드 구축

ROCm 설치 부담(수 GB, gfx906 지원 불확실)을 회피하기 위해 Vulkan을 먼저 선택했다. Mesa RADV는 벤더 SDK 없이 동작하므로 구형 AMD GPU에 이식성이 높다.

필요 패키지는 `libvulkan-dev`, `glslang-tools`에 더해 **`glslc`와 `spirv-headers`가 별도 패키지로 분리**되어 있어 순차적으로 두 번의 configure 실패를 겪었다(§4.3, §4.4).

```
$ cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
-- Found Vulkan: /usr/lib/x86_64-linux-gnu/libvulkan.so (found version "1.3.275")
       found components: glslc glslangValidator
-- Vulkan found
-- GL_KHR_cooperative_matrix supported by glslc
-- Including Vulkan backend
```

빌드 결과 디바이스 인식:

```
$ ./llama-cli --list-devices
Available devices:
  Vulkan0: Intel(R) UHD Graphics 630 (CFL GT2) (23947 MiB, 19538 MiB free)
  Vulkan1: AMD Radeon Graphics (RADV VEGA20) (32768 MiB, 32737 MiB free)
```

```
ggml_vulkan: 1 = AMD Radeon Graphics (RADV VEGA20) (radv) | uma: 0 | fp16: 1 | bf16: 0 |
             fp4: 0 | warp size: 64 | shared memory: 65536 | int dot: 0 | matrix cores: none
```

> `matrix cores: none` — gfx906은 행렬 연산 전용 유닛이 없는 마지막 세대 GCN이다. 이 사실은 §6.3·§6.4의 성능 해석에서 다시 언급한다.

### 3.3 3단계 — ROCm/HIP 백엔드 구축

Vulkan 성능이 기대에 못 미치자(§4.2) 비교군으로 ROCm을 구축했다. 이 과정은 본 연구에서 가장 많은 트러블슈팅을 요구했다(§4.5 ~ §4.10).

**핵심 난점: 버전 선택.** AMD 공식 저장소가 제공하는 최신 ROCm 7.14는 gfx906을 지원하지 않는다. 이는 문서상 "지원 종료" 표기를 넘어 **바이너리 커널의 물리적 부재**로 나타났다.

```
$ ls /opt/rocm/lib/rocblas/library/ | wc -l                    # ROCm 7.14
2153                                    # 총 커널 파일 수
$ ls /opt/rocm/lib/rocblas/library/*gfx906* 2>/dev/null | wc -l
0                                       # gfx906 커널: 전무

$ ls /opt/rocm/lib/rocblas/library/ | grep -oE 'gfx[0-9a-z]+' | sort -u | tr '\n' ' '
gfx1010 gfx1011 gfx1012 gfx1030 gfx1031 gfx1032 gfx1033 gfx1034 gfx1035 gfx1036
gfx1100 gfx1101 gfx1102 gfx1103 gfx1150 gfx1151 gfx1152 gfx1153 gfx1200 gfx1201
gfx1250 gfx908 gfx90a gfx942 gfx950
```

반면 ROCm 6.2.0 패키지를 내려받아 검사하니 gfx906 커널이 온전히 존재했다.

```
$ dpkg-deb -x rocblas_4.2.0.60200-66~24.04_amd64.deb extracted
$ find extracted -iname "*gfx906*" | wc -l
156
```

따라서 **ROCm 6.2 저장소를 별도로 추가**해 rocBLAS/hipBLAS/HIP 런타임을 6.2.0으로 확보하는 전략을 취했다. llama.cpp가 `HIP >= 6.1`을 요구하므로(§4.6) 배포판 기본 제공 ROCm 5.7.1은 사용할 수 없었고, 6.2가 "llama.cpp 요구사항"과 "gfx906 지원"을 동시에 만족하는 유일한 구간이었다.

최종 configure 및 인식 결과:

```
$ HIP_PATH=/opt/rocm-6.2.0 ROCM_PATH=/opt/rocm-6.2.0 cmake -B build \
    -DGGML_HIP=ON -DCMAKE_HIP_COMPILER=/opt/rocm-6.2.0/llvm/bin/clang++ \
    -DAMDGPU_TARGETS=gfx906 -DCMAKE_HIP_ARCHITECTURES=gfx906 \
    -Dhip_DIR=/opt/rocm-6.2.0/lib/cmake/hip \
    -Dhipblas_DIR=/opt/rocm-6.2.0/lib/cmake/hipblas \
    -Drocblas_DIR=/opt/rocm-6.2.0/lib/cmake/rocblas
-- The HIP compiler identification is Clang 18.0.0
-- HIP and hipBLAS found
-- Including HIP backend

$ ./llama-cli --list-devices
Available devices:
  ROCm0: AMD Radeon Graphics (32752 MiB, 32732 MiB free)

ggml_cuda_init: found 1 ROCm devices (Total VRAM: 32752 MiB):
  Device 0: AMD Radeon Graphics, gfx906:sramecc+:xnack- (0x906), VMM: no, Wave Size: 64
```

---

## 4. 트러블슈팅 기록

발생 순서대로 10건을 기록한다. 각 항목은 **증상 → 원인 → 해결**로 구성한다.

### 4.1 GPU 클럭이 저전력 상태에 고정 (성능 영향 최대)

**증상.** GPU 사용률이 100%인데도 35B-A3B 모델의 토큰 생성이 6.28 t/s에 머물렀다. MoE 구조를 고려하면 비정상적으로 낮은 수치.

```
$ cat /sys/class/drm/card2/device/gpu_busy_percent
100                                     # GPU는 포화 상태

$ cat /sys/class/drm/card2/device/pp_dpm_sclk
0: 925Mhz
1: 938Mhz *                             # ← 최대 1800MHz의 52%에 고정
...
8: 1800Mhz

$ cat /sys/class/drm/card2/device/pp_dpm_mclk
0: 350Mhz *                             # ← 최대 1000MHz의 35%에 고정
1: 800Mhz
2: 1000Mhz

$ cat /sys/class/drm/card2/device/power_dpm_force_performance_level
auto
```

**원인.** MI50은 헤드리스 컴퓨트 카드로 설계되었고, `auto` DPM 정책의 부하 감지 휴리스틱이 LLM 추론 워크로드(짧고 끊어지는 커널 디스패치의 연속)를 "클럭을 올릴 만한 부하"로 인식하지 못한다. 특히 메모리 클럭이 35%에 묶인 것이 치명적인데, MoE 모델은 토큰마다 서로 다른 전문가(expert) 가중치를 VRAM에서 새로 읽어야 하므로 메모리 대역폭 민감도가 매우 높기 때문이다.

**해결.**

```bash
echo high | sudo tee /sys/class/drm/card2/device/power_dpm_force_performance_level
```

적용 후:

```
$ cat /sys/class/drm/card2/device/pp_dpm_sclk | grep '\*'
8: 1800Mhz *                            # 100%
$ cat /sys/class/drm/card2/device/pp_dpm_mclk | grep '\*'
2: 1000Mhz *                            # 100%
```

| 지표 | auto | high | 배율 |
|:---|---:|---:|---:|
| 프롬프트 처리 (pp) | 41.8 t/s | 346.7 t/s | **8.3배** |
| 토큰 생성 (tg) | 6.28 t/s | 15.9 t/s | **약 2.5배** |

**부가 관찰 — VBIOS와의 무관성.** 판매자는 "V420 VBIOS 적용으로 SCLK가 잘 유지된다"고 기술했으나, 본 시스템은 동일한 VBIOS(`113-D1640200-043`)임에도 저전력 고정 현상을 그대로 겪었다. 또한 판매자가 제공한 `rocm-smi` 스크린샷에서도 `sclk 938MHz / mclk 350MHz` 및 `WARNING: AMD GPU device(s) is/are in a low-power state`가 동일하게 관찰된다. **VBIOS는 전력 상한과 DPM 레벨 테이블의 상한선을 정할 뿐, 드라이버의 클럭 상승 판단 정책과는 독립적**이라고 결론지었다. 재플래싱은 불필요하며 `high` 강제가 확실한 해법이다.

### 4.2 벤치마크와 실사용 서버의 극심한 성능 불일치 (핵심 발견)

**증상.** 동일 모델·백엔드·클럭 조건에서 `llama-bench`는 73 t/s를 안정적으로(±0.08) 보고하는 반면, `llama-server` 실사용은 8.9 ~ 17.4 t/s에 그쳤다. 4~8배 격차.

**가설 검증 과정.** 용의자를 하나씩 배제했다.

| 가설 | 검증 방법 | 결과 | 판정 |
|:---|:---|:---|:---:|
| KV 캐시 양자화 오버헤드 | bench에 `-fa 1 -ctk q4_0 -ctv q4_0` 적용 | 73.06 → 71.21 t/s | ❌ 기각 |
| 컨텍스트 깊이(누적 토큰) | bench에 `-d 2257` 적용 | 65.29 t/s | ❌ 기각 |
| 슬롯 병렬화(`n_slots=4`) | 서버에 `--parallel 1` 적용 | 8.90 t/s (변화 없음) | ❌ 기각 |
| GPU 클럭 재하락 | 측정 직후 클럭 확인 | `high`, 1800/1000MHz 유지 | ❌ 기각 |
| 시스템 전역 변화 | bench 재실행(대조군) | 73.06 t/s 재현 | ❌ 기각 |
| **할당 컨텍스트 크기** | 서버 `-c` 값만 변경 | **8.90 → 69.70 t/s** | ✅ **채택** |

> **이 표의 판정은 이후 두 번 수정되었다.** §5.3에서 "할당 컨텍스트"는 단독 원인이 아니라 **양자화 KV와의 조합**임이 밝혀졌고, §5.4에서는 여기서 기각했던 **슬롯 병렬화가 실제로는 독립적인 원인**임이 확인되었다. 당시 기각된 이유는 컨텍스트 32,768 + q4_0 조건에서 이미 절벽에 빠져 있어 슬롯 효과가 가려졌기 때문이다.

**원인.** `-c`로 **할당**한 컨텍스트가 임계값을 넘으면 Vulkan 백엔드의 토큰 생성 성능이 붕괴한다. 결정적으로, **실제로 채운 토큰 수는 225개로 모든 조건에서 동일**했다. 즉 연산량이 아니라 KV 캐시 버퍼의 할당 크기 자체가 원인이다.

```
$ grep print_timing /tmp/srv_ctx_32768_p1.log
prompt eval time =   813.99 ms /  25 tokens ( 32.56 ms/token,  30.71 t/s)
       eval time = 22464.05 ms / 200 tokens (112.32 ms/token,   8.90 t/s)
      total time = 23278.04 ms / 225 tokens
   graphs reused =      199
```

**영향과 해결.** 이 프로젝트의 `run_llama_server.sh`는 여유 VRAM으로부터 컨텍스트를 자동 산출했는데, 32GB 카드에서 **175,126 토큰**이라는 값을 내놓아 정확히 이 붕괴 구간에 진입시키고 있었다. 당시에는 자동 산출값에 상한(기본 32,768)을 씌우는 것으로 대응했다.

> **이 잠정 조치는 이후 폐기되었다.** §5.3에서 원인이 컨텍스트 크기가 아니라 KV 타입임이 드러났고, 하필 그 상한값 32,768 자체가 q4_0 붕괴 구간 한복판이었다(§5.3 표). 최종적으로는 KV를 q8_0으로 바꿔 절벽 자체를 회피하고 자동 상한은 두지 않는다(`MAX_AUTO_CTX`로 선택적 제한만 가능). 상세는 §5.2 → §5.3 → §5.4 순으로 이어진다.

### 4.3 Vulkan configure 실패 — `glslc` 부재

```
CMake Error at FindPackageHandleStandardArgs.cmake:230 (message):
  Could NOT find Vulkan (missing: glslc) (found version "1.3.275")
```

**원인.** Ubuntu/Debian에서 `glslc`(shaderc)는 `libvulkan-dev`, `glslang-tools`와 **별개 패키지**로 분리되어 있다. `glslang-tools`를 설치해도 `/usr/bin/glslang`, `glslangValidator`만 제공되고 `glslc`는 포함되지 않는다.

**해결.** `sudo apt install -y glslc`

### 4.4 Vulkan configure 실패 — `SPIRV-Headers` 부재

```
CMake Error at ggml/src/ggml-vulkan/CMakeLists.txt:14 (find_package):
  Could not find a package configuration file provided by "SPIRV-Headers"
```

**해결.** `sudo apt install -y spirv-headers`

> §4.3과 §4.4는 연쇄 실패였다. 이 경험을 반영해 빌드 스크립트가 `libvulkan-dev glslang-tools glslc spirv-headers`를 한 번에 설치하도록 수정했다.

### 4.5 ROCm 자동 설치기의 BAR 크기 경고

```
$ sudo amdgpu-install -y --usecase=rocm,hiplibsdk --no-dkms
WARNING: Skipping device: 0000:04:00.0 Bar size smaller than needed for binary header.
Common fixes in BIOS: 1. Enable "Above 4G Decoding"  2. Enable "Resizable BAR"
ERROR: All AMD devices failed IP discovery.
WARNING: No AMD GPU detected for auto-detection. Using generic rocm packages.
```

**원인.** `amdgpu-install`이 설치할 아키텍처 패키지를 자동 판별하기 위해 GPU의 BAR 영역에서 헤더를 읽으려 시도하다 실패한 것.

**판정 — 무해.** 이는 설치기의 편의 기능일 뿐, ROCm 컴퓨트 런타임 자체와는 무관하다. 실제로 BIOS 설정 변경 없이 `rocminfo`/`rocm-smi`가 GPU를 정상 인식했고 HIP 커널 디스패치도 문제없이 동작했다. BIOS의 Above 4G Decoding / Resizable BAR 활성화는 모델 초기 로딩 시 호스트→VRAM 전송 속도에만 영향을 주며, 추론 속도에는 실질적 영향이 없어 본 연구에서는 변경하지 않았다.

### 4.6 llama.cpp의 HIP 최소 버전 요구

```
CMake Error at ggml/src/ggml-hip/CMakeLists.txt:55 (message):
  At least ROCM/HIP V6.1 is required
```

**원인.** 배포판(Ubuntu universe)이 제공하는 `hipcc` 5.7.1 / `librocblas-dev` 5.5.1은 gfx906을 정식 지원하던 마지막 세대지만, llama.cpp의 최소 요구 버전(6.1)에 미달한다.

**해결.** "gfx906을 지원하면서 동시에 6.1 이상"인 구간을 찾아야 했다. AMD 저장소의 6.2 패키지를 직접 검사(§3.3)해 gfx906 커널 156개 존재를 확인하고 ROCm 6.2를 채택했다.

### 4.7 ROCm 6.2 저장소 GPG 서명 오류

```
Err:7 https://repo.radeon.com/rocm/apt/6.2 noble InRelease
  The following signatures couldn't be verified because the public key is not available:
  NO_PUBKEY 9386B48A1A693C5C
E: The repository '...' is not signed.
```

**해결.**

```bash
sudo mkdir -p /etc/apt/keyrings
curl -sL https://repo.radeon.com/rocm/rocm.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/rocm-6.2.gpg
echo "deb [signed-by=/etc/apt/keyrings/rocm-6.2.gpg] https://repo.radeon.com/rocm/apt/6.2 noble main" \
  | sudo tee /etc/apt/sources.list.d/rocm-6.2.list
sudo apt update
```

### 4.8 HIP 컴파일러 지정과 device bitcode 부재

세 개의 연쇄 오류를 거쳤다.

**(a) hipcc 래퍼 거부**

```
CMake Error: CMAKE_HIP_COMPILER is set to the hipcc wrapper: /usr/bin/hipcc
  This is not supported. Use Clang directly, or let CMake pick a default.
```

CMake는 Perl 스크립트인 `hipcc` 래퍼를 HIP 컴파일러로 받지 않는다 → 실제 `clang++` 바이너리를 직접 지정해야 한다.

**(b) device library 부재**

```
clang++: error: cannot find ROCm device library; provide its path via '--rocm-path'
  or '--rocm-device-lib-path', or pass '-nogpulib'
```

`rocm-llvm`(컴파일러)만 설치되고 device-side bitcode가 누락된 상태였다.
→ `sudo apt install -y rocm-device-libs` (6.2 버전) 설치로 `/opt/rocm-6.2.0/lib/llvm/lib/clang/18/lib/amdgcn/bitcode/*.bc` 확보.

**(c) hip-config.cmake가 참조하는 hipcc 부재**

```
CMake Error at /opt/rocm-6.2.0/lib/cmake/hip/hip-config.cmake:31 (message):
  File or directory /opt/rocm-6.2.0/bin/hipcc referenced by variable
  hip_HIPCC_EXECUTABLE does not exist !
```

배포판 hipcc(5.7.1)가 `/usr/bin`에 설치되어 있었고 `/opt/rocm-6.2.0/bin/hipcc`는 없었다.
→ 6.2 저장소의 hipcc로 교체(다운그레이드): `sudo apt install --allow-downgrades hipcc=1.1.1.60200-66~24.04`

### 4.9 헤더 충돌 — 구버전 `/usr/include` vs ROCm 6.2

```
/opt/rocm/include/hip/amd_detail/amd_hip_bf16.h:1904: error:
  use of undeclared identifier '__MEMORY_SCOPE_DEVICE'
/usr/include/hip/hip_runtime_api.h:2211: note: candidate function not viable:
  requires 3 arguments, but 2 were provided        # hipStreamWaitEvent 시그니처 불일치
```

**원인.** 배포판 패키지(`libamdhip64-dev` 5.7.1 등)가 설치한 `/usr/include/hip`, `/usr/include/hipblas`, `/usr/include/rocblas`가 시스템 기본 include 경로에 있어, cmake로 지정한 `/opt/rocm-6.2.0`의 헤더보다 먼저 해석되었다. 6.2 헤더의 `hipStreamWaitEvent`는 세 번째 인자에 기본값(`__dparm(0)`)이 있으나 5.7 헤더에는 없어 2-인자 호출이 실패한다.

**해결.** 구버전 헤더 디렉터리를 임시 비활성화(가역적):

```bash
sudo mv /usr/include/hip      /usr/include/hip.disabled
sudo mv /usr/include/hipblas  /usr/include/hipblas.disabled
sudo mv /usr/include/rocblas  /usr/include/rocblas.disabled
```

### 4.10 ROCm 6.2의 FP8 타입 불일치

```
ggml/src/ggml-cuda/vendors/hip.h:249:9: error: unknown type name '__hip_fp8_e4m3'
```

**원인.** llama.cpp는 `HIP_VERSION >= 60200000`이면 표준 이름의 `__hip_fp8_e4m3` 타입이 존재한다고 가정한다.

```c
#if HIP_VERSION >= 60200000
#include <hip/hip_fp8.h>
typedef __hip_fp8_e4m3 __nv_fp8_e4m3;
#define FP8_AVAILABLE
#endif
```

그러나 ROCm 6.2.0 헤더를 검사하면 **fnuz 변형만 존재**한다.

```
$ grep -c '\(struct\|class\)[[:space:]]\+__hip_fp8_e4m3[^_a-zA-Z]' \
    /opt/rocm-6.2.0/include/hip/amd_detail/amd_hip_fp8.h
0                                        # 비-fnuz 정의 없음
$ grep -n '__hip_fp8_e4m3_fnuz {' /opt/rocm-6.2.0/include/hip/amd_detail/amd_hip_fp8.h
636:struct __hip_fp8_e4m3_fnuz {         # fnuz 변형만 존재
```

표준 이름 타입은 ROCm 6.3부터 추가되었다. 즉 llama.cpp의 버전 가드가 한 마이너 버전 이르다.

**해결.** 가드 임계값을 6.3으로 상향해 해당 블록을 비활성화. FP8 경로는 `#ifdef FP8_AVAILABLE`로 감싸져 있어 안전하며, gfx906은 애초에 FP8 하드웨어 지원이 없다.

```bash
sed -i 's/HIP_VERSION >= 60200000/HIP_VERSION >= 60300000/g' \
  "$BUILD_DIR/ggml/src/ggml-cuda/vendors/hip.h"
```

---

## 5. 실험 결과

### 5.1 합성 벤치마크 (llama-bench)

35B-A3B Q4_K_M, `-ngl 99`, 클럭 `high` 고정.

```
$ ./llama-bench -m Qwen3.6-35B-A3B…Q4_K_M.gguf -ngl 99 -p 512 -n 128     # HIP
| model                    |   size | params | backend | ngl |  test |            t/s |
| qwen35moe 35B.A3B Q4_K_M | 19.70G | 34.66B | ROCm    |  99 | pp512 | 903.24 ± 4.67 |
| qwen35moe 35B.A3B Q4_K_M | 19.70G | 34.66B | ROCm    |  99 | tg128 |  63.51 ± 0.22 |

$ ./llama-bench … --device Vulkan1 -ngl 99 -p 512 -n 128                 # Vulkan
| qwen35moe 35B.A3B Q4_K_M | 19.70G | 34.66B | Vulkan  |  99 | pp512 | 454.07 ± 4.33 |
| qwen35moe 35B.A3B Q4_K_M | 19.70G | 34.66B | Vulkan  |  99 | tg128 |  73.08 ± 0.09 |
```

| 지표 | Vulkan (RADV) | ROCm/HIP | 우세 |
|:---|---:|---:|:---:|
| pp512 (프롬프트 처리) | 454.07 t/s | **903.24 t/s** | HIP **1.99배** |
| tg128 (토큰 생성) | **73.08 t/s** | 63.51 t/s | Vulkan 1.15배 |

합성 벤치마크만 보면 "프롬프트는 HIP, 생성은 Vulkan"이라는 결론이 나온다. **이 관계 자체는 설정을 올바로 맞춘 실사용에서도 유지되지만(§6.3), 설정이 어긋나면 Vulkan 쪽이 10배 가까이 무너져 관계가 뒤집힌다.** 아래 §5.2~§5.4는 그 "어긋난 설정"이 무엇이었는지 추적하는 과정이다.

### 5.2 할당 컨텍스트에 따른 토큰 생성 속도 (핵심 결과)

동일 모델·클럭·플래그(`-fa on -ctk q4_0 -ctv q4_0 --parallel 1`), **채운 토큰 225개 고정**, `-c` 값만 변경.

| 할당 컨텍스트 | Vulkan (RADV) | ROCm/HIP |
|---:|---:|---:|
| 4,096 | **69.70 t/s** | 57.75 t/s |
| 8,192 | 69.58 t/s | — |
| 16,384 | 69.63 t/s | — |
| **32,768** | **8.90 t/s** ⚠️ | **59.47 t/s** |
| 175,126 *(스크립트 자동 산출값)* | 17.41 t/s † | **59.98 t/s** |

† 이 행만 `--parallel 4`로 측정되어 다른 행(`--parallel 1`)과 조건이 다르다. Vulkan 값 17.41이 32,768의 8.90보다 오히려 높은 비단조성은 이 조건 차이 때문이며, 슬롯 수의 영향은 §5.4에서 별도로 다룬다.

```
$ bash test_ctx.sh 4096  1   →  ctx=4096   parallel=1  tg=69.70 t/s
$ bash test_ctx.sh 8192  1   →  ctx=8192   parallel=1  tg=69.58 t/s
$ bash test_ctx.sh 16384 1   →  ctx=16384  parallel=1  tg=69.63 t/s
$ bash test_ctx.sh 32768 1   →  ctx=32768  parallel=1  tg=8.90 t/s
$ bash test_ctx.sh 175126 4  →  ctx=175126 parallel=4  tg=17.41 t/s

$ bash test_be.sh hip 4096   →  hip  ctx=4096   tg=57.75 t/s
$ bash test_be.sh hip 32768  →  hip  ctx=32768  tg=59.47 t/s
$ bash test_be.sh hip 175126 →  hip  ctx=175126 tg=59.98 t/s
```

**해석 (1차).**

- Vulkan은 16,384까지 완전히 평탄(69.6 ± 0.1)하다가 32,768에서 **87% 급락**한다. 절벽형 저하이며 점진적 열화가 아니다.
- ROCm/HIP는 4,096 ~ 175,126 전 구간에서 57.8 ~ 60.0 t/s로 **완전히 평탄**하다. 편차 4% 이내.
- 채운 토큰이 동일하므로 이는 연산량 증가가 아니다.

이 시점의 잠정 결론은 "할당 컨텍스트 크기가 원인"이었으나, **§5.3의 추가 실험에서 이 해석이 불완전함이 드러났다.**

### 5.3 원인 분리 실험 — KV 캐시 타입의 결정적 영향

§5.2의 모든 측정이 `-ctk/-ctv q4_0`을 고정한 상태였다는 점에 착안해, 컨텍스트와 KV 타입을 분리해 재측정했다. (채운 토큰 175개 고정)

| ctx | `-fa` | KV 타입 | tg |
|---:|:---:|:---:|---:|
| 16,384 | on | q4_0 | 69.92 t/s |
| 20,480 | on | q4_0 | **8.89 t/s** ⚠️ |
| 24,576 | on | q4_0 | **8.89 t/s** ⚠️ |
| 32,768 | on | q4_0 | **8.89 t/s** ⚠️ |
| **32,768** | on | **f16** | **71.27 t/s** ✅ |
| **65,536** | on | **f16** | **70.67 t/s** ✅ |
| **32,768** | on | **q8_0** | **69.96 t/s** ✅ |
| **65,536** | on | **q8_0** | **69.99 t/s** ✅ |
| 32,768 | off | q4_0 | *컨텍스트 생성 실패* |

**핵심 발견.** 컨텍스트를 32,768로 고정한 채 **KV 타입만 q4_0 → f16으로 바꾸면 8.89 → 71.27 t/s로 완전히 회복된다.** 즉 절벽의 원인은 컨텍스트 크기 자체가 아니라 **Vulkan 백엔드와 양자화 KV 캐시의 상호작용**이다.

부가 관찰:

- **실제 임계값은 32,768이 아니라 16,384와 20,480 사이**에 있다. §5.2가 32,768을 임계값으로 지목한 것은 그 사이를 측정하지 않았기 때문이다.
- **20,480 / 24,576 / 32,768의 측정값이 소수점까지 동일한 8.89 t/s**다. 비용이 KV 크기에 비례하지 않는다는 뜻이며, 크기 비례 연산이 아니라 **고정 비용의 느린 경로**로 빠짐을 시사한다.
- `-fa off`는 성능 문제가 아니라 컨텍스트 생성 자체가 거부된다(양자화 KV는 flash attention을 요구). 따라서 "FA를 끄면 회피된다"는 선택지는 존재하지 않는다.
- f16 KV는 32,768과 65,536 모두에서 70~71 t/s로 평탄하다. **q4_0보다 오히려 빠르다**(69.9 vs 71.3).

**메커니즘 미규명.** 소스 검토 결과 다음은 배제되었다.

| 후보 | 검증 | 판정 |
|:---|:---|:---:|
| 미지원 op → CPU 폴백 | `ggml-vulkan.cpp`의 `fa_kv_ok()`에 `GGML_TYPE_Q4_0` 포함됨 | ❌ |
| 시스템 메모리 폴백 | `allow_sysmem_fallback`은 `GGML_VK_ALLOW_SYSMEM_FALLBACK` 환경변수 필요, 미설정 | ❌ |
| `maxStorageBufferRange` 초과 | 한계 4 GiB, 32K KV는 0.75 GB | ❌ |
| VRAM 부족 | 32 GB 중 여유 11 GB, 필요량 0.75 GB | ❌ |
| 크기 비례 연산량 | 20,480/24,576/32,768이 동일 수치 | ❌ |

즉 q4_0은 "지원되는 경로 안에서" 느려지는 것이며, 정확한 내부 원인 규명에는 셰이더 수준 프로파일링이 추가로 필요하다.

**실용적 결론.** 절벽을 피하려면 **q4_0 대신 q8_0 또는 f16을 쓰면 된다.** 추가 측정에서 q8_0이 f16과 속도가 사실상 같으면서 VRAM은 절반만 쓰는 것이 확인되어(위 표), **q8_0을 양쪽 백엔드 공통 기본값**으로 채택했다. ROCm은 q4_0으로도 평탄하지만 q8_0에서도 손해가 없어 백엔드별로 나눌 이유가 없다.

> 이 절의 초기 결론은 "Vulkan → f16"이었으나, q8_0 측정을 추가하면서 위와 같이 수정했다. VRAM 절반은 실질적 차이다 — 같은 여유 VRAM에서 담을 수 있는 컨텍스트가 약 2배가 된다.

### 5.4 원인 분리 실험 2 — 슬롯 수(--parallel)의 결정적 영향

§5.3 이후 실사용 서버에서 Vulkan 백엔드가 5.5 t/s 로 다시 무너지는 현상이 보고되었다.
KV 타입은 이미 q8_0 으로 바꾼 뒤였으므로 §5.3 의 설명으로는 해명되지 않았다.

> **컨텍스트 값이 93,184로 바뀐 이유.** KV 타입을 q4_0에서 q8_0으로 바꾸면 토큰당 KV 크기가
> 약 1.9배가 되므로, 같은 여유 VRAM에서 담을 수 있는 컨텍스트가 줄어든다. 스크립트의
> 추정 계수도 이에 맞춰 16 → 8.5 tokens/MB로 조정했고, 그 결과 자동 산출값이
> 175,126(q4_0) → 93,035(q8_0)로 바뀌었다(llama.cpp가 내부적으로 93,184로 정렬).

`run_llama_server.sh` 가 `--parallel` 을 넘기지 않아 llama-server 기본값인 슬롯 4개가
적용되고 있었다는 점에 착안해, 슬롯 수만 분리해 재측정했다. (KV 타입 q8_0 고정)

| 백엔드 | 할당 ctx | `--parallel` | tg |
|:---|---:|---:|---:|
| Vulkan | 65,536 | 4 | **5.49 t/s** ⚠️ |
| Vulkan | 93,184 | 4 | **5.49 t/s** ⚠️ |
| Vulkan | 93,184 | 1 | **55.14 t/s** ✅ |
| ROCm/HIP | 93,184 | 4 | 52.33 t/s |
| ROCm/HIP | 93,184 | 1 | 52.60 t/s |

**핵심 발견.**

- Vulkan 은 슬롯이 2개 이상이면(`kv_unified = true`) 토큰 생성이 **10배 느려진다**.
  컨텍스트를 65,536 → 93,184 로 바꿔도 **정확히 같은 5.49 t/s** 가 나온다.
  §5.3 의 q4_0 절벽이 크기와 무관하게 8.89 로 고정됐던 것과 동일한 양상이며,
  연산량 증가가 아니라 고정 비용의 느린 경로로 빠짐을 시사한다.
- **ROCm/HIP 는 슬롯 수에 사실상 영향받지 않는다** (52.33 vs 52.60, 편차 0.5%).
- 슬롯을 1로 되돌린 Vulkan 값 55.14 t/s 는 §5.2·§5.3의 69~71 t/s 보다 20% 낮은데, 이는
  절벽과 무관하게 **컨텍스트가 93,184로 커지면서 KV 캐시 읽기량이 늘어난 정상적인 비용**이다
  (§6.3의 깊이별 KV 읽기 표 참고).
- 즉 §5.3 의 KV 타입 문제와 이 슬롯 문제는 **서로 독립적인 두 개의 Vulkan 한정 현상**이다.
  q8_0 으로 바꿔 앞의 절벽을 피해도 이 문제는 그대로 남는다.

**해석의 수정.** §5.2 는 "할당 컨텍스트가 원인"이라 했고 §5.3 은 "KV 타입이 원인"이라 했는데,
둘 다 부분적으로만 옳았다. 세 실험을 종합하면 Vulkan 백엔드에는 **특정 조건에서 느린
경로로 빠지는 성질**이 있고, 그 조건이 최소 두 가지(양자화 KV + 큰 컨텍스트, 다중 슬롯)다.
어느 경우든 저하된 값이 크기와 무관하게 일정하다는 공통점이 있다.

**반영.** `run_llama_server.sh` 가 `--parallel` 을 명시하도록 수정했다(기본값 1,
`PARALLEL` 환경변수로 조정). 개인용 서버는 동시 요청이 드물어 슬롯 1개가 지연시간 면에서
유리하며, Vulkan 에서는 사실상 필수다.

### 5.5 전력 정책의 영향 (재수록)

| 지표 | `auto` | `high` | 배율 |
|:---|---:|---:|---:|
| sclk | 938 MHz | 1,800 MHz | 1.92× |
| mclk | 350 MHz | 1,000 MHz | 2.86× |
| pp | 41.8 t/s | 346.7 t/s | 8.3× |
| tg | 6.28 t/s | 15.9 t/s | 2.5× |

> pp가 클럭 상승률(1.9 ~ 2.9배)을 크게 상회하는 8.3배 개선을 보인 것은, `auto` 상태에서는 배치 행렬곱조차 메모리 대역폭에 심하게 병목되어 있었음을 시사한다.

### 5.6 최종 실사용 구성에서의 검증

Vulkan 백엔드, 컨텍스트 4,096, 실제 채팅 API 호출:

```
$ curl -s localhost:8099/v1/chat/completions -d '{"messages":[…],"max_tokens":200}'
ctx=4096  parallel=1  predicted_n=200  tg=69.70 t/s  pp=81.85 t/s
# (pp 가 낮은 것은 프롬프트가 25토큰뿐이라 고정 오버헤드가 지배하기 때문이다.
#  긴 프롬프트 기준 처리량은 §5.1 의 pp512 를 참고할 것.)
```

초기 상태(6.28 t/s) 대비 **11.1배** 개선.

---

## 6. 논의

### 6.1 판매자 벤치마크와의 정합성 검토

판매자는 2장 구성(TP2) Gemma 4 26B A4B Q8_0 기준 `tg128: 74.61 t/s`를 제시했다. 이를 1장 기준으로 환산할 때 단순히 절반(37 t/s)으로 보는 것은 과소평가다. 텐서 병렬은 GPU 간 통신·동기화 오버헤드로 인해 토큰 생성에서 통상 1.3~1.7배 스케일링에 그치므로, 1장 성능은 **45~55 t/s** 범위로 추정된다.

여기에 활성 파라미터 차이(A4B vs 본 실험의 A3B, 약 4/3배)를 보정하면 **60~70 t/s대**가 기대되며, 이는 본 실험의 HIP 측정값(59.5~60.0 t/s) 및 Vulkan 소컨텍스트 측정값(69.7 t/s)과 **잘 부합한다**. 판매자 주장은 과장이 아닌 것으로 판단된다.

### 6.2 백엔드 선택 지침

측정 결과에 근거한 권고는 다음과 같다.

| 사용 조건 | 권장 구성 | 근거 |
|:---|:---|:---|
| 단일 사용자, 생성 속도 최우선 | **Vulkan + q8_0 KV + `--parallel 1`** | tg 70.0 t/s(ctx 32~65K), 55.1 t/s(ctx 93K) |
| 긴 프롬프트/문서 처리 위주 | **ROCm/HIP** | pp 903 vs 454 t/s (합성 벤치 1.99배)<br>실사용 650 vs 364 t/s (1.78배) |
| 동시 요청 여러 개 처리 | **ROCm/HIP** | 슬롯을 늘려도 저하 없음(52.33 vs 52.60) |
| 설치 간편성 우선 | **Vulkan** | Mesa만으로 동작, ROCm 수 GB 불필요 |
| 안정성/예측가능성 우선 | **ROCm/HIP** | 알려진 성능 절벽이 없음 |
| **피해야 할 조합** | ~~Vulkan + q4_0 KV (ctx ≥ 20K)~~<br>~~Vulkan + `--parallel > 1`~~ | 각각 8.9 / 5.5 t/s 로 붕괴 |

### 6.3 prefill과 decode에서 백엔드 우열이 뒤집히는 이유

실사용 측정에서 두 백엔드의 우열이 지표에 따라 반대로 나타났다.

| 지표 | ROCm/HIP | Vulkan | 우세 |
|:---|---:|---:|:---|
| prefill (프롬프트 처리) | **650.11 t/s** | 364.35 t/s | HIP **1.78배** |
| decode (토큰 생성) | 44.76 t/s | **47.52 t/s** | Vulkan 1.06배 |

> 이 수치는 `run_llama_server.sh`를 통한 실사용 측정으로, §5의 통제 측정과 조건이 다르다.
> 자동 산출 컨텍스트(약 93K), `-ctk/-ctv q8_0`, mmproj 로드, 실제 대화 프롬프트 기준이다.
> §5.4의 통제 측정(93,184 / q8_0 / `--parallel 1`)에서 ROCm 52.60, Vulkan 55.14였던 것과
> 절대값은 다르나 **Vulkan이 decode에서 근소하게 앞선다는 관계는 동일**하다.
> 아래 대역폭 계산은 이 실사용 수치를 입력으로 쓰지만, §5.4 값(52~55 t/s)을 넣어도
> 이용률은 5.9~6.2%로 결론(한 자릿수 퍼센트)은 바뀌지 않는다.

두 지표는 연산의 성격이 근본적으로 다르며, 그 차이가 백엔드 특성과 맞물린 결과다.

**prefill — 연산 처리량이 지배한다.** 프롬프트의 여러 토큰을 한 번에 처리하므로 행렬×행렬(GEMM) 형태가 되고, GEMM은 타일링·레지스터 할당·메모리 접근 패턴 튜닝의 효과가 큰 대표적 연산이다. ROCm 경로는 여기서 rocBLAS/Tensile의 **gfx906 전용으로 사전 컴파일된 커널**을 쓴다 — §3.3에서 ROCm 6.2를 굳이 찾아낸 이유였던 그 156개 커널이 실제로 일하는 지점이다. Vulkan은 벤더 튜닝 없이 범용 SPIR-V 셰이더로 같은 일을 하므로 밀린다.

**decode — 연산량도 대역폭도 병목이 아니다.** 토큰을 하나씩 생성하므로 모든 행렬 연산이 행렬×벡터(GEMV)로 축퇴한다. 이 모델의 메타데이터로 토큰당 실제로 읽는 가중치를 계산하면:

```
레이어당  어텐션(Q/K/V/O, GQA 16:2)      18.87 M
          활성 전문가 8개 (256개 중)      25.17 M
          공유 전문가 + 라우터             3.67 M
                                        ─────────
                                          47.71 M  × 40층 = 1.908 B

Q4_K_M(≈4.83 bit/param) 기준 ≈ 1.15 GB / 토큰
  44.76 t/s → 51.6 GB/s   = HBM2 대역폭 1,024 GB/s 의 5.0%
  47.52 t/s → 54.8 GB/s   = 5.3%
```

**즉 이 GPU의 메모리 대역폭을 5%밖에 쓰지 못하고 있다.** 연산량 역시 GEMV라 미미하다. 그렇다면 남는 병목은 **커널 디스패치 오버헤드**다. MoE 구조상 토큰 하나마다 대략

```
40 레이어 × (활성 전문가 8개 × 행렬 3개 + 공유 전문가 + 라우터 + 어텐션) ≳ 1,000회
```

의 작은 커널 실행이 일어나고, 각각은 계산이 하찮은 대신 실행·동기화 비용이 상대적으로 크다. rocBLAS는 이 구간에 거의 관여하지 않는다(ggml이 GEMV용 자체 커널을 쓴다). 따라서 **decode에서는 두 백엔드가 같은 오버헤드 벽에 부딪히고**, 남는 6% 차이는 BLAS 품질이 아니라 커맨드 제출 경로의 효율 차이로 보인다.

**단서 하나 — 깊은 컨텍스트에서는 양상이 달라진다.** 위 계산은 가중치 읽기만 센 것이고, KV 캐시 읽기는 채운 컨텍스트 깊이에 비례해 늘어난다.

| 채운 깊이 | KV 읽기(q8_0) |
|---:|---:|
| 3,000 | 0.13 GB/토큰 |
| 32,768 | 1.43 GB/토큰 |
| 93,184 | 4.06 GB/토큰 |

깊이 3만을 넘어서면 KV 읽기가 가중치 읽기(1.15 GB)를 앞지르고, 그 지점부터는 decode도 점차 대역폭 지배적으로 바뀐다. 본 절의 "5%"는 대화 초반(얕은 깊이) 기준이며, 긴 문맥을 채운 상태에서는 대역폭 이용률이 올라가고 백엔드 간 격차도 다르게 나타날 수 있다.

**실용적 정리.**

- 긴 프롬프트·문서 처리·RAG·코드베이스 질의처럼 **입력이 큰** 용도 → ROCm/HIP (1.78배)
- 짧은 프롬프트에 **긴 답변을 생성**하는 용도 → Vulkan (1.06배), 단 `--parallel 1` + `q8_0` 필수
- 두 백엔드를 함께 설치해 두고 용도에 따라 고르는 것이 합리적이며, 이를 위해 백엔드별 설치 디렉터리 분리와 `--backend` 선택 기능을 구현했다.

### 6.4 하드웨어 세대의 영향

`matrix cores: none`이 보여주듯 gfx906은 전용 행렬 연산 유닛이 없는 마지막 세대 GCN이다. 그럼에도 MoE 모델에서 60~70 t/s를 기록한 것은, A3B(활성 3B) 구조 덕분에 실제 연산량이 총 파라미터(34.66B) 대비 매우 작기 때문이다. 32GB HBM2의 대용량과 결합하면, 이 카드는 **"큰 모델을 올려서 적당한 속도로 돌리는"** 용도에 여전히 유효한 선택지다.

### 6.5 한계

- 단일 카드(1장) 환경이며 텐서 병렬(TP2) 구성은 검증하지 못했다. §6.1의 환산은 문헌적 추정치에 의존한다.
- Vulkan + 양자화 KV 절벽의 **근본 메커니즘을 규명하지 못했다.** §5.3에서 CPU 폴백·시스템메모리 폴백·버퍼 한계·VRAM 부족·크기 비례 연산량은 모두 배제했으나, 지원되는 경로 안에서 왜 느려지는지는 셰이더 수준 프로파일링이 필요하다.
- 측정은 각 조건 1회 실행 기준이다(단, `llama-bench`는 내부 반복 평균 및 표준편차 제공, 편차 ±0.1 수준으로 매우 안정적).
- 모델 1종(MoE)에 대한 결과이며, Dense 모델에서 동일한 성능 절벽(§5.3·§5.4)이 나타나는지는 미검증이다.
- §6.3의 토큰당 가중치 계산은 GGUF 메타데이터에서 유도한 추정치다. 임베딩·출력 레이어와 실제 캐시 적중률은 반영하지 않았으므로 절대값보다는 자릿수를 보는 용도로 해석해야 한다.

### 6.6 향후 연구 과제

**1. 디스패치 오버헤드 해소 — 가장 큰 미개척 여지.** §6.3에서 decode가 HBM2 대역폭의 5%(51.6 GB/s / 1,024 GB/s)만 사용하고 있음을 확인했다. 연산량도 대역폭도 병목이 아니고 커널 디스패치 횟수가 지배한다면, 디스패치당 처리량을 늘리는 방향에 상당한 개선 여지가 있다. 검증할 만한 축은 다음과 같다.

- **배치 파라미터 조정** (`-b`, `-ub`): 물리 배치와 마이크로 배치 크기가 커널 실행 횟수와 직접 연결된다. 특히 이 모델처럼 레이어·전문가 수가 많아 커널 수가 1,000회를 넘는 구조에서는 영향이 클 수 있다.
- **투기적 디코딩(speculative decoding)**: 작은 초안 모델로 여러 토큰을 미리 생성하고 본 모델이 한 번에 검증하는 방식. 검증 단계가 배치 연산이 되므로 디스패치당 확정 토큰 수가 늘어난다. 대역폭 여유가 95%나 남아 있는 현 상황과 원리적으로 잘 맞는다.
- **CUDA Graph 상당 기능**: 반복되는 디스패치 시퀀스를 미리 기록해 재생하는 방식. 현재 로그에 `graphs reused = 199`가 관측되므로 이미 부분적으로 작동 중이며, 그 적용 범위와 효과를 정량화할 가치가 있다.

**2. Vulkan 성능 절벽의 근본 원인.** §5.3·§5.4에서 두 개의 독립적인 절벽(양자화 KV + 큰 컨텍스트, 다중 슬롯)을 확인했고 소거법으로 여러 후보를 배제했으나, 지원되는 코드 경로 안에서 왜 느려지는지는 규명하지 못했다. 두 경우 모두 저하값이 크기와 무관하게 일정하다는 공통점은 같은 뿌리를 시사한다. RenderDoc이나 RGP 같은 도구로 셰이더 단위 프로파일링이 필요하다.

**3. 저장장치 병목 제거 후의 재측정.** 현 시스템은 SATA SSD(실측 430 MB/s)에 모델이 있어 22GB 로딩에 약 50초가 걸린다. NVMe로 교체하면 8~10초로 줄어들 것으로 추정되나, GPU가 칩셋(PCH) 경유 슬롯에 있어 NVMe와 DMI 3.0 상향 링크를 공유한다는 점이 실제 개선폭을 제한할 수 있다. 실측으로 확인할 가치가 있다.

**4. ROCm 6.3.3 적용 검토.** 본 연구는 ROCm 6.2를 채택했으나, 이후 확인 결과 **6.3.3에도 gfx906 rocBLAS 커널 156개가 동일하게 존재**한다(6.4 이상은 0개). 더 새로운 Tensile 커널이 prefill 성능에 영향을 주는지 비교할 여지가 있다.

**5. Dense 모델에서의 재현성.** 본 연구의 발견 중 상당수(디스패치 오버헤드 지배, §5.3·§5.4의 성능 절벽)는 MoE 특유의 "작은 커널 다수" 구조와 관련이 있을 수 있다. Dense 모델에서도 같은 양상이 나타나는지 확인하면 결론의 일반성을 판단할 수 있다.

---

## 7. 결론

> **주의 — §8에서 일부 정정됨.** 아래 2번의 "회피 후에는 Vulkan이 ROCm보다 빠르다"가 성립하지 않는 모델이 확인됐다(시퀀스 34토큰부터 7배 하락, `GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1` 로 회복). 어떤 모델이 걸리는지 판별하는 기준은 아직 없으므로 모델별 실측이 필요하다. §6.4의 "Resizable BAR는 추론 속도와 무관"이라는 판정도 재검토 대상이다. 자세한 근거는 §8 참조.

1. **초기 6.28 t/s → 최종 69.70 t/s, 총 11.1배 개선을 달성했으며 원인은 전부 설정이었다.** 기여 요인은 세 가지다. (a) GPU 전력 정책 `auto`→`high` (2.5배), (b) KV 캐시 타입 `q4_0`→`q8_0` — Vulkan에서 큰 컨텍스트와 결합해 절벽을 만들던 요인, (c) 슬롯 수 `4`→`1` (Vulkan 한정 10배). 초기 실행은 세 조건이 모두 불리하게 겹친 상태였다. **하드웨어 성능 부족은 어느 단계에서도 원인이 아니었다.**

2. **Vulkan 백엔드에는 성능이 절벽처럼 무너지는 조건이 최소 두 가지 있으며, 둘 다 설정으로 회피 가능하다.** 양자화 KV(`q4_0`)와 큰 컨텍스트의 조합(8.9 t/s), 그리고 슬롯 2개 이상(5.5 t/s)이다. 각각 `q8_0`과 `--parallel 1`로 해결되며, 회피 후에는 55~71 t/s로 ROCm보다 오히려 빠르다. 두 경우 모두 저하값이 컨텍스트 크기와 무관하게 일정하다는 공통된 특징을 보인다. ROCm/HIP는 두 조건 어디에도 영향받지 않아, 예측 가능성이 필요한 용도에는 이쪽이 안전하다.

3. **공식 지원 종료 하드웨어에서도 버전 조합으로 ROCm 구축이 가능하다.** ROCm 7.14는 gfx906 커널이 0개인 반면 6.2.0에는 156개가 존재했다. 문서상의 지원 매트릭스가 아닌 **실제 바이너리 내용 검사**가 판단 기준이 되어야 한다.

4. 이 과정에서 확인된 사항들을 프로젝트 스크립트에 반영했다. 특히 ROCm 감지 로직을 "hipcc 존재 여부"에서 **"내 GPU 아키텍처용 rocBLAS 커널이 실제로 존재하는 ROCm 루트 탐색"**으로 교체하여, 지원 종료된 버전을 자동 배제하도록 했다.

---

## 8. 추가 조사 — Vulkan에서 특정 모델만 토큰 생성이 7배 무너지는 현상 (2026-08-09)

본 절은 §1–7 이후 별도로 수행한 조사다. 결론부터: **원인은 모델도 양자화도 아니었고, llama.cpp Vulkan 백엔드의 host-visible VRAM 사용 경로였다.** 환경변수 하나로 6.5배가 회복된다. 다만 "왜 시퀀스 34에서 전환되는가"와 "왜 같은 아키텍처의 다른 모델은 무사한가"는 규명하지 못했다(§8.6). §6.4의 "ReBAR는 추론 속도와 무관"이라는 판정은 재검토가 필요하다.

### 8.1 관찰

같은 GPU·같은 백엔드에서 두 모델의 토큰 생성 속도가 10배 차이났다.

| 모델 | 파일 크기 | pp512 | tg128 |
|---|---:|---:|---:|
| Genesis-V7-MTP-APEX-Compact | 17.05 GiB | 815.22 | **6.51** |
| HauhauCS-Aggressive | 19.70 GiB | 965.51 | **66.93** |

측정: `llama-bench --device Vulkan1 -ngl 99 -fa 1 -ctk q8_0 -ctv q8_0 -p 512 -n 128 -r 1`

**프롬프트 처리는 1.18배 차이인데 토큰 생성만 10.3배**라는 비대칭이 조사의 출발점이었다. 같은 파일을 ROCm으로 돌리면 정상이었다(§8.7).

### 8.2 기각된 가설들

그럴듯했지만 측정으로 반증된 것들을 남긴다. 결론만큼 재현에 유용하다.

**(a) 모델 손상** — GGUF 헤더·텐서 구성 정상. ROCm에서 56.74 t/s로 정상 동작.

**(b) 양자화(Q3_K)** — Genesis는 expert 텐서 41개 항목 중 30개가 Q3_K(9.67 GiB, 모델의 56.7%)이고 HauhauCS는 Q4_K/Q6_K뿐이다. 유력해 보였으나 **같은 형태의 연산에서 속도가 같았다**.

```
실행 중 계측 (GGML_VK_PERF_LOGGER=1):
  MUL_MAT_ID_VEC q3_K m=512 n=8 k=2048 n_expert=256 : 22.029 us/호출
  MUL_MAT_ID_VEC q4_K m=512 n=8 k=2048 n_expert=256 : 21.472 us/호출   → 2.6% 차이

연산 격리 (test-backend-ops perf -o MUL_MAT):
  q3_K m=4096 n=1 k=14336 : 87.07 us  (1.35 TFLOPS)
  q4_K m=4096 n=1 k=14336 : 64.09 us  (1.83 TFLOPS)  → 1.36배
```

관측된 10배와 무관하다. **양자화 타입은 원인이 아니다.**

**(c) VRAM 부족·호스트 스필** — 시퀀스 34토큰(KV 캐시 수십 KB), VRAM 20 GB 이상 여유인 조건에서도 그대로 재현됐다. 컨텍스트를 줄여도 해결되지 않는다.

**(d) MTP 레이어** — llama.cpp는 `blk.40.nextn.*`을 전부 무시한다(`unused tensor … ignoring`). 약 856 MiB가 파일에서 낭비될 뿐 계산에 참여하지 않는다. non-MTP 버전도 양자화 배합이 동일해 속도는 같다.

**(e) SSM 아키텍처 자체** — 두 모델 모두 하이브리드 MoE+SSM이며 SSM 레이어 30개, SSM 텐서 차원까지 동일하다(§8.6-(2)). 타입 구성도 거의 같다(Genesis F32 120/F16 2/Q4_K 88, HauhauCS F32 120/Q4_K 90). HauhauCS는 depth 64/512/2048에서 71.95 / 53.69 / 50.56 t/s로 **절벽이 없다**.

**(f) 셰이더 융합·정수내적 경로** — 느린 구간(n=64)에서 `GGML_VK_DISABLE_FUSION=1` → 8.25, `GGML_VK_DISABLE_MMVQ=1` → 8.78. 기준 8.82와 차이 없음.

### 8.3 방아쇠: 총 시퀀스 길이 34

두 가지 독립적인 방법이 같은 값을 가리켰다.

```
생성 토큰만 (-n, -r 3):     n=32 → 58.66    n=33 → 61.02    n=34 →  8.74
미리 채우기 + 생성 (-d/-n): 합 26 → 63.14   합 33 → 61.41   합 34 →  8.78
                            합 36 →  8.87   합 64 →  8.83
```

`-d 18 -n 16`(합 34)이 이미 느리다는 점이 중요하다. **누적 디코드 횟수가 아니라 총 시퀀스 길이가 방아쇠**이며, 이 모델·이 시스템에서 임계는 34다(다른 모델·다른 BAR 크기에서 같은 값일 근거는 없다). 넘긴 뒤에는 값이 8.7~8.9로 고정된다 — 연산량에 비례하는 저하가 아니라 **고정 비용의 다른 경로**라는 뜻이다.

실사용 함의가 크다. 서버 실행 시 첫 프롬프트가 2,651토큰이었으므로 **첫 요청부터 이미 임계를 한참 넘긴 상태**였고, 회피가 불가능했다.

### 8.4 어느 연산이 폭발하는가

임계 양쪽에서 연산별 GPU 시간을 비교했다(`GGML_VK_PERF_LOGGER=1`).

| 연산 | n=33 | n=34 | 배율 | 호출 33/34 |
|---|---:|---:|---:|---:|
| **GATED_DELTA_NET** | 13.8 ms | **1575.9 ms** | **114.6x** | 1020 / 1050 |
| GET_ROWS | 20.3 | 799.6 | 39.5x | 2074 / 2135 |
| CPY | 14.4 | 777.1 | 53.8x | 2040 / 2100 |
| CONCAT | 6.4 | 93.4 | 14.6x | 1020 / 1050 |
| SSM_CONV_SILU | 6.5 | 53.3 | 8.1x | 1020 / 1050 |
| *MUL_MAT_VEC* | *181.5* | *230.7* | *1.3x* | 13634 / 14035 |
| *MUL_MAT_ID_VEC* | *57.4* | *62.5* | *1.1x* | 2720 / 2800 |

**행렬곱은 그대로이고 재귀 상태 경로만 폭발한다.** 위 5개가 전체 4,033 ms 중 3,299 ms(82%)를 차지한다. 호출 횟수는 30 레이어 × (n+1)로 정상이므로 **호출당 시간이 13.5 us → 1,501 us(111배)**가 된 것이다.

GPU가 노는 것이 아니다. 같은 조건에서 잰 가동률은 다음과 같다.

```
n=33 : GPU  547.2 ms / 벽시계  632 ms → 86.6%
n=34 : GPU 4032.8 ms / 벽시계 4116 ms → 98.0%
```

GPU는 쉬지 않고 일하며, **실제로 7.4배 더 많은 일을 한다**. 동기화 횟수도 31,178 / 32,095로 토큰 수에 비례할 뿐 차이가 없다.

### 8.5 확정된 원인: host-visible VRAM 사용

인과를 스위치로 확정했다. `GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1` 하나로 회복된다.

| 조건 | t/s |
|---|---:|
| n=34 기준 | 8.79 |
| n=34 + `GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1` | **56.72** |
| n=128 기준 | 8.84 |
| n=128 + `GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1` | **52.48** |

이 플래그가 바꾸는 것은 버퍼를 어느 메모리 타입에 요청하느냐 하나뿐이다(`ggml-vulkan.cpp`, `ggml_vk_create_buffer_device`).

```cpp
} else {
    // use rebar if available, otherwise fallback to device only visible memory
    buf = ggml_vk_create_buffer(device, size,
        { DeviceLocal | HostVisible | HostCoherent,   // 1순위: BAR 매핑 메모리
          DeviceLocal });                             // 2순위
}
```

즉 llama.cpp Vulkan 백엔드는 **Resizable BAR가 켜져 있다는 전제로** BAR 매핑 메모리를 1순위로 요청한다. 이 시스템의 실제 BAR는 256 MB뿐이다.

```
$ lspci -v -s 04:00.0
    Memory at 90000000 (64-bit, prefetchable) [size=256M]     ← VRAM 32GB 중 호스트 가시 영역
$ cat /sys/bus/pci/devices/0000:04:00.0/resource0_resize
    000000000000ff00                                          ← 카드는 ReBAR 지원(256MB~32GB), BIOS 미활성
$ cat .../current_link_width .../current_link_speed
    16 / 16.0 GT/s PCIe
```

**여기까지가 측정으로 뒷받침되는 범위다**: host-visible VRAM 경로를 쓰지 않게 하면 문제가 사라지고, 이 시스템의 host-visible 영역은 256 MB로 작다.

### 8.6 규명하지 못한 부분

정직하게 남긴다. 아래는 **추론이며 검증되지 않았다.**

**(1) 왜 하필 시퀀스 34에서 전환되는가.** "상태 버퍼가 256 MB 창을 초과한다"는 설명을 세웠으나 **할당 로그가 이를 반박한다.** `GGML_VK_MEMORY_LOGGER=1` 기준 n=33과 n=34의 할당은 완전히 동일하다 — 가중치 버퍼 약 900 MiB~1 GiB 15개, 잔존 컴퓨트 버퍼 146.47 MiB, `total host: 0 B`. 크기 변화가 없다. 실제 배치 변화는 ggml 회계 아래, 드라이버(RADV) 내부에서 일어나며 본 조사로는 관측하지 못했다.

**(2) 왜 같은 아키텍처의 다른 모델은 무사한가.** 두 모델의 SSM 텐서 차원은 **완전히 동일**하다.

```
blk.1.ssm_a       [32]        blk.1.ssm_conv1d.weight [4, 8192]
blk.1.ssm_alpha   [2048, 32]  blk.1.ssm_dt.bias       [32]
blk.1.ssm_beta    [2048, 32]  blk.1.ssm_norm.weight   [128]
blk.1.ssm_out     [4096, 2048]
```

`GATED_DELTA_NET` 호출 횟수도 두 모델 모두 17회로 같다. 그럼에도 HauhauCS는 depth 2048까지 절벽이 없다. **구분 요인을 특정하지 못했다.** 따라서 "delta-net 계열이면 위험하다"는 판별 기준은 성립하지 않는다.

**(3) 왜 ROCm은 영향받지 않는가.** 측정상 무사하다는 것은 확실하나(8.7), HIP 백엔드의 메모리 배치 경로는 조사하지 않았다.

**(4) BIOS에서 ReBAR를 켜면 해결되는가.** 소스의 주석(`use rebar if available`)과 하드웨어 제원상 유력하나, **BIOS 설정을 변경해 검증하지 않았다.** 확인된 6.5배 회복은 환경변수에 의한 것이다.

### 8.7 ROCm 비교

| 모델 | Vulkan tg128 | ROCm tg128 |
|---|---:|---:|
| Genesis | 6.51 | **56.74** |
| HauhauCS | 66.93 | 59.34 |

같은 파일·같은 GPU에서 ROCm은 정상이다. **§7-2의 "회피 후에는 Vulkan이 ROCm보다 빠르다"는 결론은 이 조건에서는 성립하지 않는다.**

### 8.8 §6.4·§7에 대한 정정

1. **"Resizable BAR는 모델 초기 로딩에만 영향, 추론 속도와 무관"은 재검토가 필요하다.** host-visible VRAM 경로가 이 현상의 원인임이 확인됐고 그 경로는 BAR 크기에 직접 좌우되므로, "추론 속도와 무관"은 유지하기 어렵다. 다만 위 8.6-(4)대로 BIOS 변경 자체는 검증하지 않았다.
2. **"GPU가 칩셋 경유 x4 슬롯에 연결"은 현재 상태와 다르다.** 커널은 x16 @ 16 GT/s (PCIe 4.0)로 보고한다.
3. **§7-2의 Vulkan 절벽 두 건과 본 건은 원인이 다르다.** `q4_0` KV + depth 20480 조건을 재현 시도했으나 47.40 t/s로 정상이었고, `GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1`을 줘도 48.74로 차이가 없었다. 절벽 세 건을 하나의 메커니즘으로 묶으려던 가설은 기각한다.

### 8.9 실행 권고

판별 기준을 아직 모르므로 **모델별로 실측하는 것이 유일하게 확실한 방법이다.**

```bash
# 판별: 임계 양쪽에서 재본다. 값이 급락하면 해당 모델은 이 현상에 걸린다.
llama-bench -m <model> --device Vulkan1 -ngl 99 -fa 1 -ctk q8_0 -ctv q8_0 -p 0 -n 32
llama-bench -m <model> --device Vulkan1 -ngl 99 -fa 1 -ctk q8_0 -ctv q8_0 -p 0 -n 64

# 걸리는 모델을 Vulkan 으로 돌릴 때 (즉시 적용, 부작용 확인되지 않음)
GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1 ./run_llama_server.sh --backend vulkan

# 또는 ROCm 백엔드 (이 현상에 영향받지 않음)
./run_llama_server.sh --backend rocm

# 시도해볼 것: BIOS 의 Above 4G Decoding + Resizable BAR (미검증)
```

---

## 부록 A. 재현 절차 요약

```bash
# ── A.1 GPU 접근 권한 (재로그인 필요) ──────────────────────────
sudo usermod -aG render,video "$USER"

# ── A.2 GPU 클럭 고정 (성능 2.5배, 재부팅 시 초기화됨) ─────────
echo high | sudo tee /sys/class/drm/card2/device/power_dpm_force_performance_level

# ── A.3 Vulkan 백엔드 ──────────────────────────────────────────
sudo apt install -y libvulkan-dev glslang-tools glslc spirv-headers
cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"

# ── A.4 ROCm 6.2 백엔드 (gfx906) ───────────────────────────────
sudo mkdir -p /etc/apt/keyrings
curl -sL https://repo.radeon.com/rocm/rocm.gpg.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/rocm-6.2.gpg
echo "deb [signed-by=/etc/apt/keyrings/rocm-6.2.gpg] https://repo.radeon.com/rocm/apt/6.2 noble main" \
  | sudo tee /etc/apt/sources.list.d/rocm-6.2.list
sudo apt update
sudo apt install -y rocblas rocblas-dev hipblas hipblas-dev hip-runtime-amd hip-dev \
                    rocm-device-libs
sudo apt install --allow-downgrades hipcc=1.1.1.60200-66~24.04

# 구버전 헤더 충돌 회피
sudo mv /usr/include/hip     /usr/include/hip.disabled
sudo mv /usr/include/hipblas /usr/include/hipblas.disabled
sudo mv /usr/include/rocblas /usr/include/rocblas.disabled

# FP8 타입 가드 상향 (ROCm 6.2 한정)
sed -i 's/HIP_VERSION >= 60200000/HIP_VERSION >= 60300000/g' \
  ggml/src/ggml-cuda/vendors/hip.h

HIP_PATH=/opt/rocm-6.2.0 ROCM_PATH=/opt/rocm-6.2.0 cmake -B build \
  -DCMAKE_BUILD_TYPE=Release -DGGML_HIP=ON \
  -DCMAKE_HIP_COMPILER=/opt/rocm-6.2.0/llvm/bin/clang++ \
  -DAMDGPU_TARGETS=gfx906 -DCMAKE_HIP_ARCHITECTURES=gfx906 \
  -Dhip_DIR=/opt/rocm-6.2.0/lib/cmake/hip \
  -Dhip-lang_DIR=/opt/rocm-6.2.0/lib/cmake/hip-lang \
  -Dhipblas_DIR=/opt/rocm-6.2.0/lib/cmake/hipblas \
  -Drocblas_DIR=/opt/rocm-6.2.0/lib/cmake/rocblas
cmake --build build -j"$(nproc)"

# ── A.5 실행 시 권고 ───────────────────────────────────────────
#   공통    : -ctk q8_0 -ctv q8_0  (기본값. q4_0 은 Vulkan 에서 절벽을 만든다)
#   Vulkan  : --parallel 1 필수 (2 이상이면 생성 속도 10배 하락)
#   위 두 조건을 지키면 컨텍스트 크기 제약은 없다 (93K 에서 55 t/s 확인)
#   HIP     : 두 조건 모두 무관하나 q8_0/--parallel 1 이어도 손해 없음
#
#   [§8 추가] 일부 모델은 Vulkan 에서 시퀀스 34토큰부터 생성이 7배 느려진다.
#            어떤 모델이 걸리는지 판별하는 기준은 아직 없다 — 아래로 실측한다.
#              llama-bench -m <model> --device Vulkan1 -ngl 99 -fa 1 \
#                          -ctk q8_0 -ctv q8_0 -p 0 -n 32   (그리고 -n 64)
#            급락하면 아래 중 하나를 쓴다:
#              GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1  (6.5배 회복 확인)
#              또는 ROCm 백엔드 (이 현상 없음)
#            BIOS 의 Above 4G Decoding + Resizable BAR 는 유력하나 미검증.
```

## 부록 B. 주요 진단 명령

```bash
# GPU 인식 및 아키텍처
rocminfo | grep -E 'Name:|gfx'
./llama-cli --list-devices

# 클럭/전력 상태 (별표가 현재 레벨)
cat /sys/class/drm/card2/device/pp_dpm_sclk
cat /sys/class/drm/card2/device/pp_dpm_mclk
cat /sys/class/drm/card2/device/power_dpm_force_performance_level
rocm-smi --showclocks --showpower --showmaxpower --showvbios

# 실시간 사용률 / VRAM
cat /sys/class/drm/card2/device/gpu_busy_percent
cat /sys/class/drm/card2/device/mem_info_vram_used

# 내 아키텍처용 rocBLAS 커널 존재 확인 (지원 종료 여부 실질 판단)
ls /opt/rocm*/lib/rocblas/library/*gfx906* | wc -l
```

---

*본 문서의 모든 수치는 §1에 기술된 단일 시스템에서 직접 측정한 값이다.*
