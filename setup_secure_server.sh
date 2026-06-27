#!/bin/bash
# =============================================================================
# setup_secure_server.sh  —  llama-server 보안 접속 자동 설정
# =============================================================================
# 동작:
#   1. run_llama_server.sh 의 --host 를 127.0.0.1 로 변경 (외부 HTTP 차단)
#   2. Caddy 설치 확인 및 자동 설치
#   3. HTTPS + Basic Auth 리버스 프록시 설정 및 실행
#
# 사용법:
#   bash setup_secure_server.sh --password <비밀번호>
#   bash setup_secure_server.sh --password <비밀번호> --port 9443 --user myname
#   bash setup_secure_server.sh --stop
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="$SCRIPT_DIR/run_llama_server.sh"
LLAMA_PORT=8080   # run_llama_server.sh 의 기본 포트와 일치
CADDY_DIR="$SCRIPT_DIR/.caddy"
CADDYFILE="$CADDY_DIR/Caddyfile"
CADDY_PID_FILE="$CADDY_DIR/caddy.pid"
CADDY_LOG="$CADDY_DIR/caddy.log"
CADDY_DATA_DIR="$CADDY_DIR/data"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()     { echo -e "${RED}[ERR]${RESET}  $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
사용법: bash setup_secure_server.sh [옵션]

옵션:
  --port PORT         외부 HTTPS 포트 (기본값: 8443)
  --llama-port PORT   llama-server 내부 포트 (기본값: 8080, run_llama_server.sh 와 맞춰야 함)
  --user USER         Basic Auth 사용자명 (기본값: admin)
  --password PASS     Basic Auth 비밀번호 (생략 시 대화형 입력)
  --force             기존 Caddyfile 덮어쓰기 확인 생략
  --stop              실행 중인 Caddy 종료
  -h, --help          도움말

예시:
  bash setup_secure_server.sh --password MySecret123
  bash setup_secure_server.sh --port 9443 --user john --password MySecret123
  bash setup_secure_server.sh --password secret --llama-port 1234   # run이 --port 1234 사용 시
  bash setup_secure_server.sh --stop
EOF
  exit 0
}

# ── 인자 파싱 ─────────────────────────────────────────────────────────────────
HTTPS_PORT=8443
USERNAME="admin"
PASSWORD=""
FORCE=false
STOP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)        HTTPS_PORT="$2"; shift 2 ;;
    --llama-port)  LLAMA_PORT="$2"; shift 2 ;;
    --user)        USERNAME="$2"; shift 2 ;;
    --password)    PASSWORD="$2"; shift 2 ;;
    --force)       FORCE=true; shift ;;
    --stop)        STOP=true; shift ;;
    -h|--help)     usage ;;
    *) die "알 수 없는 옵션: $1  (--help 참조)" ;;
  esac
done

# ── --stop 처리 ───────────────────────────────────────────────────────────────
if $STOP; then
  echo -e "${BOLD}Caddy 종료 중...${RESET}"
  if [[ -f "$CADDY_PID_FILE" ]]; then
    PID=$(cat "$CADDY_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
      kill "$PID"
      rm -f "$CADDY_PID_FILE"
      success "Caddy 종료됨 (PID $PID)"
    else
      warn "PID $PID 는 이미 종료됨"
      rm -f "$CADDY_PID_FILE"
    fi
  else
    pkill -f "caddy run" 2>/dev/null \
      && success "caddy 프로세스 종료됨" \
      || warn "실행 중인 caddy 프로세스 없음"
  fi
  exit 0
fi

# ── 비밀번호 대화형 입력 ──────────────────────────────────────────────────────
if [[ -z "$PASSWORD" ]]; then
  echo -ne "${BOLD}Basic Auth 비밀번호 입력: ${RESET}"
  read -rs PASSWORD
  echo
  [[ -n "$PASSWORD" ]] || die "비밀번호는 필수입니다."
fi

echo
echo -e "${BOLD}${CYAN}══ llama-server 보안 접속 설정 ══${RESET}"
echo -e "  llama-server: localhost:${LLAMA_PORT} (로컬 전용으로 변경)"
echo -e "  HTTPS 포트:   ${HTTPS_PORT}"
echo -e "  사용자명:     ${USERNAME}"
echo

# ── Step 1: run_llama_server.sh 패치 (외부 HTTP 차단) ─────────────────────────
echo -e "${BOLD}▶ Step 1: HTTP 바인딩을 로컬 전용으로 수정${RESET}"

[[ -f "$RUN_SCRIPT" ]] || die "run_llama_server.sh 없음: $RUN_SCRIPT"

if grep -q -- '--host 0\.0\.0\.0' "$RUN_SCRIPT"; then
  cp "$RUN_SCRIPT" "${RUN_SCRIPT}.bak"
  sed -i 's/--host 0\.0\.0\.0/--host 127.0.0.1/g' "$RUN_SCRIPT"
  sed -i 's|http://0\.0\.0\.0:|http://127.0.0.1:|g' "$RUN_SCRIPT"
  success "  --host 0.0.0.0 → 127.0.0.1 변경 완료"
  info  "  원본 백업: run_llama_server.sh.bak"
elif grep -q -- '--host 127\.0\.0\.1' "$RUN_SCRIPT"; then
  success "  이미 127.0.0.1 로 설정됨 (변경 없음)"
else
  warn "  --host 설정 미발견 — 수동 확인 필요: $RUN_SCRIPT"
fi

# ── Step 2: Caddy 설치 확인 ───────────────────────────────────────────────────
echo
echo -e "${BOLD}▶ Step 2: Caddy 설치 확인${RESET}"

install_caddy() {
  warn "  Caddy 미설치. 자동 설치를 시도합니다..."
  if command -v apt &>/dev/null; then
    sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl 2>/dev/null || true
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | sudo tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
    sudo apt update -q && sudo apt install -y caddy
  elif command -v pkg &>/dev/null; then
    # Termux
    pkg install -y caddy
  elif command -v brew &>/dev/null; then
    brew install caddy
  else
    die "자동 설치 실패. 수동 설치: https://caddyserver.com/docs/install"
  fi
}

command -v caddy &>/dev/null || install_caddy
success "  $(caddy version 2>/dev/null | head -1)"

# ── Step 3: Basic Auth 비밀번호 해시 생성 ─────────────────────────────────────
echo
echo -e "${BOLD}▶ Step 3: 비밀번호 해시 생성${RESET}"

# caddy hash-password 문법은 버전마다 다름 — 둘 다 시도
HASHED=$(caddy hash-password --plaintext "$PASSWORD" 2>/dev/null) \
  || HASHED=$(caddy hash-password -p "$PASSWORD" 2>/dev/null) \
  || die "caddy hash-password 실패. 'caddy version' 으로 버전 확인 요망."

success "  bcrypt 해시 생성 완료"

# ── Step 4: Caddyfile 생성 ────────────────────────────────────────────────────
echo
echo -e "${BOLD}▶ Step 4: Caddyfile 생성${RESET}"

mkdir -p "$CADDY_DIR" "$CADDY_DATA_DIR"

if [[ -f "$CADDYFILE" ]] && ! $FORCE; then
  warn "  기존 Caddyfile 존재: $CADDYFILE"
  echo -ne "  덮어쓰시겠습니까? [y/N]: "
  read -r yn
  [[ "${yn:-n}" =~ ^[Yy]$ ]] || { info "취소됨."; exit 0; }
fi

# 비밀번호 해시에 $ 기호가 포함되므로 printf로 안전하게 작성
{
  printf "# llama-server HTTPS 리버스 프록시\n"
  printf "# 생성: %s\n\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf "{\n"
  printf "    # Caddy 관리 API 비활성화 (보안)\n"
  printf "    admin off\n"
  printf "\n"
  printf "    # 인증서/데이터 저장 위치\n"
  printf "    storage file_system {\n"
  printf "        root %s\n" "$CADDY_DATA_DIR"
  printf "    }\n"
  printf "}\n\n"
  printf "# 외부 HTTPS 접속 엔드포인트\n"
  printf ":%s {\n" "$HTTPS_PORT"
  printf "    # 자체 서명 인증서 (브라우저에서 경고 발생 — '고급'→'계속' 클릭)\n"
  printf "    tls internal\n"
  printf "\n"
  printf "    # Basic Auth (모든 경로 보호)\n"
  printf "    basicauth /* {\n"
  printf "        %s %s\n" "$USERNAME" "$HASHED"
  printf "    }\n"
  printf "\n"
  printf "    # llama-server 로컬 포트로 프록시\n"
  printf "    reverse_proxy localhost:%s\n" "$LLAMA_PORT"
  printf "\n"
  printf "    log {\n"
  printf "        output file %s/access.log {\n" "$CADDY_DIR"
  printf "            roll_size 10mb\n"
  printf "            roll_keep 3\n"
  printf "        }\n"
  printf "    }\n"
  printf "}\n"
} > "$CADDYFILE"

success "  생성됨: $CADDYFILE"

# ── Step 5: Caddy 검증 및 실행 ────────────────────────────────────────────────
echo
echo -e "${BOLD}▶ Step 5: Caddy 실행${RESET}"

# 기존 인스턴스 정리
if [[ -f "$CADDY_PID_FILE" ]]; then
  OLD_PID=$(cat "$CADDY_PID_FILE" 2>/dev/null || echo "")
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    info "  기존 Caddy (PID $OLD_PID) 종료 중..."
    kill "$OLD_PID"
    sleep 1
  fi
  rm -f "$CADDY_PID_FILE"
fi

# systemd caddy 서비스가 이미 실행 중이면 그쪽에 적용
if systemctl is-active --quiet caddy 2>/dev/null; then
  info "  systemd caddy 서비스 감지됨 — /etc/caddy/Caddyfile 에 복사"
  sudo cp "$CADDYFILE" /etc/caddy/Caddyfile
  sudo systemctl reload caddy
  success "  systemd Caddy 리로드 완료"
else
  # Caddyfile 문법 검증
  caddy validate --config "$CADDYFILE" --adapter caddyfile 2>/dev/null \
    || die "Caddyfile 문법 오류. 파일 확인: $CADDYFILE"

  # 백그라운드로 직접 실행
  nohup caddy run --config "$CADDYFILE" --adapter caddyfile \
    > "$CADDY_LOG" 2>&1 &
  CADDY_PID=$!
  echo "$CADDY_PID" > "$CADDY_PID_FILE"

  # 2초 후 생존 확인
  sleep 2
  if ! kill -0 "$CADDY_PID" 2>/dev/null; then
    die "Caddy 시작 실패. 로그 확인:\n  cat $CADDY_LOG"
  fi

  success "  Caddy 실행 중 (PID $CADDY_PID)"
fi

# ── Step 6: 방화벽 안내 ───────────────────────────────────────────────────────
echo
echo -e "${BOLD}▶ Step 6: 방화벽 설정 안내${RESET}"

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  warn "  ufw 활성화됨. 아래 명령으로 HTTPS 포트를 열어주세요:"
  echo -e "    ${BOLD}sudo ufw allow ${HTTPS_PORT}/tcp${RESET}   # HTTPS 허용"
  echo -e "    ${BOLD}sudo ufw deny  ${LLAMA_PORT}/tcp${RESET}  # llama HTTP 외부 차단 (권장)"
else
  info "  ufw 미사용 환경. 필요 시 OS/라우터 방화벽에서 ${HTTPS_PORT}/tcp 허용 설정 필요."
fi

# ── 완료 요약 ─────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  설정 완료!${RESET}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════${RESET}"
echo
echo -e "  ${BOLD}로컬 HTTP${RESET} (내부 전용):"
echo -e "    http://127.0.0.1:${LLAMA_PORT}"
echo
echo -e "  ${BOLD}외부 HTTPS${RESET} (Basic Auth 보호):"
echo -e "    https://<이 서버의 IP>:${HTTPS_PORT}"
echo
echo -e "  ${CYAN}사용자명${RESET}: ${USERNAME}"
echo -e "  ${YELLOW}비밀번호${RESET}: 입력한 값"
echo
echo -e "  ${YELLOW}브라우저 경고${RESET}: 자체 서명 인증서이므로 '고급' → '안전하지 않음으로 계속' 클릭"
echo -e "  ${CYAN}curl 테스트${RESET}: curl -k -u ${USERNAME}:비밀번호 https://localhost:${HTTPS_PORT}/v1/models"
echo
echo -e "  ${CYAN}Caddy 로그${RESET}:  $CADDY_LOG"
echo -e "  ${CYAN}접속 로그${RESET}:  $CADDY_DIR/access.log"
echo -e "  ${CYAN}Caddy 중지${RESET}: bash $0 --stop"
echo -e "  ${CYAN}설정 재적용${RESET}: bash $0 --password <비밀번호> --force"
echo
