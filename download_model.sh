#!/usr/bin/env bash
# 얇은 진입점. 선택·이어받기·검증 로직은 전부 download_model.py 한 곳에만 둔다.
#
# 예전에는 셸판과 파이썬판 두 벌이 나란히 있었고 규칙이 조금씩 어긋났다(이름 짓기,
# 재시도, gated 저장소 처리…). 그래서 셸판이 파이썬판을 exec 하도록 바꿨는데,
# 그때 아래 남겨 둔 옛 셸 구현 470줄은 exec 뒤라 한 번도 실행되지 않는 죽은 코드였다.
# 읽는 사람이 그걸 현재 동작이라고 믿게 되므로 지운다(내용은 git 이력에 남아 있다).
#
# 사용법:
#   bash download_model.sh          # 대화형. 저장소 URL → 양자화/mmproj/MTP 선택
#
# 환경변수 (전부 download_model.py 가 읽는다):
#   HF_TOKEN=hf_…    gated 저장소 토큰 (HUGGING_FACE_HUB_TOKEN, huggingface-cli 로그인도 인식)
#   REDOWNLOAD=1     이미 다 받은 파일도 지우고 새로 받는다 (기본: 건너뜀)
#   VERIFY_ALL=1     건너뛴 파일까지 sha256 검증 (기본: 이번에 받은 것만)
#   SKIP_VERIFY=1    sha256 검증 생략
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/download_model.py" "$@"
