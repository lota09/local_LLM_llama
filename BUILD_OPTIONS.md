# llama.cpp 빌드 옵션 가이드

## 📚 환경 변수를 통한 커스터마이징

`build_llama_server.sh` 스크립트는 다음 환경 변수를 지원합니다:

### 기본 변수

```bash
# 소스 저장소 (기본값: https://github.com/ggerganov/llama.cpp.git)
export REPO_URL="https://github.com/ggerganov/llama.cpp.git"

# 빌드 디렉터리 (기본값: /tmp/llama_build)
export BUILD_DIR="/custom/build/path"

# 설치 디렉터리 (기본값: ./llama_server)
export INSTALL_DIR="/custom/install/path"

# 백업 디렉터리 (기본값: ./llama_server_backup_<timestamp>)
export BACKUP_DIR="/custom/backup/path"

bash build_llama_server.sh
```

---

## 🎯 빌드 시나리오별 가이드

### 1. 표준 CPU-only 빌드 (권장)
```bash
bash build_llama_server.sh
```
- 자동으로 CUDA 미감지 시 CPU-only로 진행
- AVX2/AVX-512 자동 감지
- 가장 안정적

### 2. CUDA 활성화 빌드
```bash
# CUDA 자동 감지 및 활성화
bash build_llama_server.sh

# CUDA가 설치되어 있으면 자동으로 -DGGML_CUDA=ON 적용됨
```

**전제 조건**:
```bash
# CUDA Toolkit 설치 확인
nvcc --version
nvidia-smi

# GCC 호환성 확인 (≤13 권장)
gcc --version
```

### 3. 깨끗한 빌드 (이전 빌드 완전 제거)
```bash
rm -rf /tmp/llama_build
bash build_llama_server.sh
```

### 4. 커스텀 설치 경로
```bash
export INSTALL_DIR="$HOME/llama-server"
bash build_llama_server.sh
```

### 5. 큰 모델을 위한 최적화 빌드
```bash
# 최대 병렬 처리
export JOBS=$(nproc)
bash build_llama_server.sh
```

### 6. 속도 최적화 (AVX-512 활성화)
```bash
# 자동으로 감지되지만, 수동으로도 지정 가능
# AVX-512를 지원하는 CPU는 자동으로 활성화됨
bash build_llama_server.sh
```

---

## 🔨 직접 CMake 옵션 추가

스크립트를 수정하여 추가 CMake 옵션을 사용하려면:

```bash
# build_llama_server.sh에서 CMAKE_EXTRA_FLAGS 수정
# 예: ROCM 지원 추가
CMAKE_EXTRA_FLAGS="-DGGML_ROCM=ON"
```

### 자주 사용되는 CMake 옵션

```cmake
# GPU 지원
-DGGML_CUDA=ON           # NVIDIA CUDA
-DGGML_METAL=ON          # Apple Metal (macOS)
-DGGML_ROCM=ON           # AMD ROCm

# CPU 최적화
-DGGML_AVX2=ON           # AVX2 명령어 세트
-DGGML_AVX512=ON         # AVX-512 명령어 세트
-DGGML_F16C=ON           # F16C 명령어 세트

# 빌드 옵션
-DCMAKE_BUILD_TYPE=Release    # 최적화 빌드
-DLLAMA_BUILD_SERVER=ON       # llama-server 빌드 (기본값)
-DCMAKE_CXX_STANDARD=17       # C++17 표준
```

---

## 📊 빌드 성능 팁

### 병렬 빌드 조정
```bash
# 자동 감지되지만, 수동으로도 설정 가능
export JOBS=8  # CPU 코어 수에 맞춰 조정
bash build_llama_server.sh
```

### 빌드 시간 단축
1. **불필요한 예제 비활성화** (원하면 CMakeLists.txt 수정):
   ```cmake
   set(LLAMA_BUILD_EXAMPLES OFF)  # 기본값: ON
   ```

2. **증분 빌드** (이미 빌드된 부분 재사용):
   ```bash
   # 스크립트가 전체 재빌드를 하므로, 
   # CMake만 재실행하려면:
   cd /tmp/llama_build/build
   cmake --build . --config Release -j$(nproc)
   ```

### 디스크 공간 절약
```bash
# 빌드 완료 후 빌드 디렉터리 삭제
rm -rf /tmp/llama_build

# 설치 디렉터리에서만 필요한 파일 유지
# (llama-server 바이너리와 공유 라이브러리)
```

---

## 🛠️ 문제 해결

### 빌드 로그 확인
```bash
tail -f /tmp/llama_build/build.log
```

### 특정 단계에서 실패
```bash
# 빌드 디렉터리 진입
cd /tmp/llama_build/build

# 실패한 단계 재실행
cmake --build . --config Release -j$(nproc) -v  # verbose 모드
```

### 메모리 부족
```bash
# 병렬 처리 감소
export JOBS=2  # 또는 1
bash build_llama_server.sh
```

### 대역폭 부족 (다운로드 실패)
```bash
# 다운로드 재시도는 자동으로 3회까지 수행
# 네트워크 안정 후 다시 실행하면 재개됨
bash build_llama_server.sh
```

---

## 🚀 빌드 후 실행

### 환경 변수 설정
```bash
# 공유 라이브러리 경로 설정
export LD_LIBRARY_PATH=$HOME/llama-server:$LD_LIBRARY_PATH

# 또는 모든 설치 디렉터리 추가
export LD_LIBRARY_PATH=$INSTALL_DIR:$LD_LIBRARY_PATH
```

### llama-server 실행
```bash
$INSTALL_DIR/llama-server --help

# 모델 로드하여 실행
$INSTALL_DIR/llama-server -m models/model.gguf
```

---

## 📋 시스템별 추천 설정

### Ubuntu/Debian
```bash
# 기본값으로 충분함
bash build_llama_server.sh

# CUDA가 있으면 자동으로 감지되고 사용됨
```

### CentOS/RHEL
```bash
# CMake가 없으면 자동으로 yum으로 설치
bash build_llama_server.sh
```

### macOS
```bash
# Metal 지원 자동 활성화
bash build_llama_server.sh
```

### WSL (Windows Subsystem for Linux)
```bash
# CPU-only 권장 (GPU 지원 제한적)
bash build_llama_server.sh

# CUDA를 사용하려면 WSL2 + NVIDIA CUDA Toolkit 필요
```

---

## ⚡ 최적화 체크리스트

- [ ] CMake 최신 버전 설치됨 (`cmake --version`)
- [ ] GCC 13 이하 설치됨 (`gcc --version`)
- [ ] CUDA 설치 확인 (CUDA 사용 시, `nvcc --version`)
- [ ] 충분한 디스크 공간 (최소 10GB)
- [ ] 충분한 메모리 (병렬 빌드 시 8GB 이상 권장)
- [ ] 안정적인 네트워크 연결

---

## 🔗 추가 리소스

- llama.cpp 공식 저장소: https://github.com/ggerganov/llama.cpp
- 바이너리 다운로드: https://github.com/ggerganov/llama.cpp/releases
- 모델 다운로드: https://huggingface.co/
