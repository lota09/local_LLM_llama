# local_LLM_llama 빌드 및 다운로드 문제 해결 가이드

## 📋 해결된 이슈

### 이슈 #1: CMake 자동 설치 실패 ✅

**문제**: 빌드가 `apt install cmake` 단계에서 수동 입력을 기다리며 멈춤

**원인**: 스크립트가 대화형 apt 설치를 지원하지 않음

**해결책** (자동 적용됨):
```bash
# 1. conda 환경에서 cmake 자동 탐색
# 2. 시스템 cmake 자동 탐색  
# 3. apt-get으로 자동 설치 (sudo 비밀번호 미리 설정 필요)
# 4. yum으로 자동 설치 (RedHat/CentOS)
```

**수동 설치 (선택사항)**:
```bash
# Debian/Ubuntu
sudo apt-get update && sudo apt-get install -y cmake

# CentOS/RHEL
sudo yum install -y cmake

# macOS
brew install cmake

# Conda
conda install -c conda-forge cmake
```

---

### 이슈 #2: 다운로드 재개 로직 부족 ✅

**문제**: 다운로드 중단 후 처음부터 다시 시작 필요 (시간 낭비)

**원인**: 다운로드 함수가 resume 플래그를 지원하지 않음

**해결책** (자동 적용됨):
```bash
# download_model.sh:
# - curl: -C - (resume 자동 활성화)
# - wget: -c (resume 자동 활성화)
# - 최대 3회 자동 재시도
# - 재시도 간 지수 백오프 (10초, 20초, 30초)

# download_model.py:
# - HTTP Range 헤더 사용
# - 파일 크기 기반 자동 resume
# - 최대 3회 자동 재시도
```

**사용 방법**:
```bash
# 중단된 다운로드는 자동으로 재개됨
bash download_model.sh

# Python 버전도 동일하게 작동
python3 download_model.py
```

---

### 이슈 #3: 링킹 오류 (libstdc++) ✅

**문제**: 
```
/usr/bin/ld: undefined reference to `std::__throw_bad_array_new_length()'
```

**원인**: 
- CUDA와 호스트 GCC의 libstdc++ ABI 불일치
- C++ 표준 버전 불일치
- libstdc++ 버전 불일치

**해결책** (자동 적용됨):

1. **CMake 플래그 자동 추가**:
   ```cmake
   -DCMAKE_CXX_STANDARD=17
   -DGLIBCXX_USE_CXX11_ABI=1
   -DCMAKE_CXX_FLAGS=-fPIC
   ```

2. **conda 환경에서 컴파일러 일관성 보장**:
   ```bash
   conda install -y -c conda-forge gxx=13 libstdcxx-ng cxx-compiler
   ```

3. **빌드 스크립트의 자동 대응**:
   - CUDA/GCC 호환성 검사
   - GCC >13일 경우 nvcc wrapper로 자동 해결
   - 호스트 GCC 자동 선택 (≤13 버전 우선)

---

## 🚀 빠른 시작 가이드

### 1단계: CMake 설치 확인
```bash
cmake --version

# 설치되지 않았으면:
sudo apt-get install -y cmake
# 또는 conda install -c conda-forge cmake
```

### 2단계: 빌드 실행
```bash
cd local_LLM_llama
bash build_llama_server.sh
```

### 3단계: 모델 다운로드
```bash
# Shell 버전
bash download_model.sh

# Python 버전
python3 download_model.py
```

---

## 🔧 문제 해결

### CPU-only 빌드로 재시도
```bash
BUILD_DIR=/tmp/llama_build_cpu bash build_llama_server.sh
```

### 깨끗한 빌드 시작
```bash
rm -rf /tmp/llama_build
bash build_llama_server.sh
```

### 빌드 로그 확인
```bash
cat /tmp/llama_build/build.log | tail -100
```

### CUDA 빌드 비활성화
```bash
# nvcc를 찾을 수 없으면 자동으로 CPU-only로 폴백됨
```

---

## 📊 개선사항 요약

| 이슈 | 이전 | 개선 후 |
|------|------|--------|
| CMake 설치 | 수동 설치 필요 | 자동 설치 (apt/yum/conda) |
| 다운로드 | 중단 시 처음부터 | 자동 resume + 3회 재시도 |
| 링킹 오류 | 스크립트 수정 필요 | 자동으로 ABI 호환성 설정 |
| 빌드 실패 | 모호한 에러 메시지 | 상세한 진단 정보 + 해결책 |

---

## 💡 팁

- **대역폭 제한 있을 때**: 다운로드 중단 후 재개는 자동으로 처리됨
- **여러 모델 다운로드**: 각각 독립적으로 실행 가능
- **CUDA 컴파일 오류**: `--allow-unsupported-compiler` 자동 추가됨
- **환경 변수 설정**:
  ```bash
  export BUILD_DIR="/custom/path"
  export INSTALL_DIR="/custom/install"
  bash build_llama_server.sh
  ```

---

## 📞 추가 도움

빌드 로그에서:
- `build.log` 파일 확인: `/tmp/llama_build/build.log`
- CMake 버전 확인: `cmake --version`
- GCC 버전 확인: `gcc --version`
- CUDA 설치 확인: `nvcc --version` 또는 `nvidia-smi`
