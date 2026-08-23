#!/usr/bin/env bash
set -euo pipefail

# 다운로드 선택/검증 로직은 Python판을 단일 기준으로 사용한다.
# 셸 진입점은 기존 사용법을 유지하면서 두 구현의 동작 차이를 없앤다.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/download_model.py" "$@"

print() { printf '%s\n' "$*"; }

# ─────────────────────────────────────────────────────────────────────────────
# [FIX 1] 비-tty 진행표시
# '-q --show-progress' 는 터미널이 아니면 점(dot) 모드로 떨어진다. 235MB 파일 하나에
# stderr 274KB 를 쏟는 것을 실측했다(dot:giga 는 같은 파일에 311바이트).
# 로그로 리다이렉트하거나 nohup 으로 돌리면 로그가 통째로 망가진다.
# 게다가 이 스크립트는 여러 다운로드를 **동시에** 돌리므로 점 출력이 서로 섞여 더 나쁘다.
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# [FIX 5] HF 토큰
#
# gated 저장소(Llama, Gemma, FLUX 계열 등)는 토큰이 있어야 받아진다. 예전에는
# 토큰을 환경변수로만 받았고, 게다가 **다운로드에만** 붙였다. 그래서 sha256 정답지를
# 가져오는 HF API 호출이 401 을 받고 빈 문자열을 돌려줬고, 화면에는
# "sha256 정보 없음 — 검증 생략" 만 떴다. 정작 검증이 가장 필요한 gated 20GB 짜리에서
# 검증이 조용히 사라지는 셈이다. 이제 API 호출에도 같은 토큰을 붙인다.
#
# 출처 우선순위: HF_TOKEN → HUGGING_FACE_HUB_TOKEN → huggingface-cli 로그인 파일
# ─────────────────────────────────────────────────────────────────────────────
_resolve_hf_token() {
  if [ -n "${HF_TOKEN:-}" ]; then printf '%s' "$HF_TOKEN"; return 0; fi
  if [ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]; then printf '%s' "$HUGGING_FACE_HUB_TOKEN"; return 0; fi
  local f="${HF_HOME:-$HOME/.cache/huggingface}/token"
  [ -r "$f" ] && tr -d '[:space:]' < "$f"
  return 0
}
HF_TOKEN="$(_resolve_hf_token)"

# 토큰이 필요한 요청 두 종류(wget/curl)의 인자를 만든다.
_auth_args() {  # $1: wget|curl
  [ -n "${HF_TOKEN:-}" ] || return 0
  case "$1" in
    wget) printf '%s\n' "--header=Authorization: Bearer ${HF_TOKEN}" ;;
    curl) printf '%s\n' "-H" "Authorization: Bearer ${HF_TOKEN}" ;;
  esac
}

_wget_progress() {
  if [ -t 2 ]; then printf '%s\n' "--show-progress"
  else printf '%s\n' "--show-progress" "--progress=dot:giga"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# [FIX 2] 재시도 로직이 죽어 있던 문제
#
# 예전 코드는 이랬다:
#     curl -L --fail ... -o "$dest" "$url"
#     if [ $? -eq 0 ]; then ... ; fi
#
# 이 파일은 맨 위에서 'set -e' 를 켜므로, curl 이 실패하는 순간 **그 자리에서 셸이 죽는다.**
# 다음 줄의 `if [ $? -eq 0 ]` 는 실행되지 않고, 아래의 "재시도" 도, "최대 재시도 초과" 도
# 영원히 도달하지 않는다. 실제로 재현해 확인했다:
#     set -e; false; if [ $? -eq 0 ]; then echo 성공; fi; echo "재시도"   → '재시도' 안 찍힘
# 다운로드는 백그라운드(&)로 도니 서브셸만 죽고 wait 가 실패를 정상 보고해서
# "실패했다"는 것만 보이고, 정작 **3회 재시도와 이어받기가 한 번도 동작하지 않았다.**
# 10GB 짜리를 받는 스크립트에서 이건 있으면 안 되는 상태다.
#
# 해결: 종료코드를 $? 로 나중에 보지 말고 `if cmd; then` 형태로 조건에 넣는다.
# (set -e 는 조건절 안의 실패를 무시한다)
# ─────────────────────────────────────────────────────────────────────────────
download() {
  local url="$1" dest="$2" max_retries=3 attempt=1
  local -a prog; mapfile -t prog < <(_wget_progress)
  # gated 저장소(Llama, Gemma, FLUX 계열 등)는 토큰이 있어야 받아진다.
  local -a wauth=() cauth=()
  mapfile -t wauth < <(_auth_args wget)
  mapfile -t cauth < <(_auth_args curl)

  print "Downloading: $url"
  print "Destination: $dest"

  while [ "$attempt" -le "$max_retries" ]; do
    if command -v wget >/dev/null 2>&1; then
      # wget -c 는 Content-Range 를 확인하고 이어받는다. HF 의 302 → 서명 CDN 리다이렉트
      # 너머로도 정상 동작하는 것을 실측 확인했다(206 Partial Content + sha256 일치).
      [ -f "$dest" ] && print "Resume 모드로 다운로드 재개 중... (시도 $attempt/$max_retries)"
      if wget -q "${prog[@]}" "${wauth[@]+"${wauth[@]}"}" -c -O "$dest" "$url"; then
        print "✓ 다운로드 완료"; return 0
      fi
    elif command -v curl >/dev/null 2>&1; then
      [ -f "$dest" ] && print "Resume 모드로 다운로드 재개 중... (시도 $attempt/$max_retries)"
      if [ -f "$dest" ]; then
        if curl -L --fail --progress-bar "${cauth[@]+"${cauth[@]}"}" -C - -o "$dest" "$url"; then print "✓ 다운로드 완료"; return 0; fi
      else
        if curl -L --fail --progress-bar "${cauth[@]+"${cauth[@]}"}"    -o "$dest" "$url"; then print "✓ 다운로드 완료"; return 0; fi
      fi
    else
      print "Error: curl or wget is required to download files." >&2
      return 2
    fi

    # 인증 문제라면 세 번 더 해봐야 세 번 다 실패한다. 즉시 원인을 알려주고 빠져나온다.
    if [ -z "${HF_TOKEN:-}" ] && _diagnose_gated "$url"; then return 1; fi

    if [ "$attempt" -lt "$max_retries" ]; then
      local wait_time=$((attempt * 10))
      print "⚠ 다운로드 실패. ${wait_time}초 후 재시도..."
      sleep "$wait_time"
    fi
    attempt=$((attempt + 1))
  done

  print "Error: 다운로드 최대 시도 횟수 초과" >&2
  # 여기서 파일을 지우지 않는다. 부분 파일이 남아 있어야 다음 실행에서 이어받을 수 있고,
  # 아래 sha256 검증이 "받다 만 것"인지 "깨진 것"인지 구분해 준다.
  return 1
}

# gated 저장소 판별 (요청 1회). 조용히 참/거짓만 돌려준다.
_is_gated() {
  local url="$1" out
  command -v wget >/dev/null 2>&1 || return 1
  out=$(wget --spider -S "$url" 2>&1 || true)
  case "$out" in
    *GatedRepo*|*"401 Unauthorized"*|*"403 Forbidden"*) return 0 ;;
  esac
  return 1
}

_diagnose_gated() {
  _is_gated "$1" || return 1
  print "" >&2
  print "⛔ 이 저장소는 로그인/약관 동의가 필요한 gated 저장소입니다." >&2
  print "   HF 웹에서 해당 모델의 약관에 동의한 뒤 토큰을 주고 재실행하세요:" >&2
  print "     HF_TOKEN=hf_xxx bash download_model.sh" >&2
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# [FIX 3] 무결성 검증
#
# HuggingFace API 의 lfs.oid 는 **파일 내용의 sha256** 이다. 즉 정답지를 서버가 준다.
# 이걸 안 쓰면 20GB 짜리 GGUF 가 조용히 잘려도 그 자리에서는 알 수 없고,
# 나중에 llama-server 가 'invalid magic' 이나 알 수 없는 로드 실패로만 알려준다.
# 비용은 약 6초/GB(실측).  SKIP_VERIFY=1 로 끌 수 있다.
# ─────────────────────────────────────────────────────────────────────────────
_fetch() {
  # [FIX 5] gated 저장소의 트리 API 도 토큰을 요구한다. 안 붙이면 401 → 검증 생략.
  local -a wa=() ca=()
  mapfile -t wa < <(_auth_args wget)
  mapfile -t ca < <(_auth_args curl)
  if   command -v curl >/dev/null 2>&1; then curl -fsSL "${ca[@]+"${ca[@]}"}" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -qO- "${wa[@]+"${wa[@]}"}" "$1"
  else return 1
  fi
}

# https://huggingface.co/<repo>/resolve/<rev>/<path>  →  그 파일의 sha256
# HF URL 이 아니면 빈 문자열을 돌려주고, 그러면 검증은 그냥 생략된다.
hf_sha_for_url() {
  local url="${1%%\?*}" rest repo rev path json
  case "$url" in https://huggingface.co/*) ;; *) return 0 ;; esac
  rest="${url#https://huggingface.co/}"
  case "$rest" in *"/resolve/"*) ;; *) return 0 ;; esac
  repo="${rest%%/resolve/*}"
  rev="${rest#*/resolve/}"; path="${rev#*/}"; rev="${rev%%/*}"
  json=$(_fetch "https://huggingface.co/api/models/${repo}/tree/${rev}?recursive=true" 2>/dev/null || true)
  [ -n "$json" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg p "$path" '.[] | select(.path==$p) | .lfs.oid // ""' 2>/dev/null | head -n1
    return 0
  fi
  # jq 없을 때의 폴백. LFS 파일은 "lfs":{...} 중첩 객체를 갖기 때문에 레코드를 '}' 로
  # 자르면 안 되고, ',{"type":' 를 구분자로 써야 한다.
  printf '%s' "$json" | sed 's/,{"type":/\n{"type":/g' | while IFS= read -r o || [ -n "$o" ]; do
    case "$o" in *"\"path\":\"$path\""*) ;; *) continue ;; esac
    case "$o" in *'"lfs":{"oid":"'*) local h=${o##*'"lfs":{"oid":"'}; printf '%s' "${h%%\"*}" ;; esac
    break
  done
}

verify_sha() {  # file expected → 0=일치 또는 검증불가, 1=불일치
  local f="$1" want="$2" got
  [ -f "$f" ] || return 1
  [ -n "$want" ] || { print "  (sha256 정보 없음 — 검증 생략)"; return 0; }
  [ "${SKIP_VERIFY:-0}" = "1" ] && { print "  (SKIP_VERIFY=1 — 검증 생략)"; return 0; }
  # HF 는 gated 저장소의 해시를 별표로 가린다. 그걸 그대로 비교하면 항상 불일치가 된다.
  [[ "$want" =~ ^[0-9a-fA-F]{64}$ ]] || { print "  (HF 가 해시를 가린 저장소 — 검증 생략)"; return 0; }
  # [FIX] openssl 이 coreutils sha256sum 보다 2.7배 빠르다. 같은 12.7GB 파일 실측:
  #     sha256sum  78.6s (154 MB/s)   ← 이식성 위주의 C 구현
  #     openssl    29.0s (419 MB/s)   ← 어셈블리(AVX2) 최적화
  # 이 CPU(Coffee Lake)에는 SHA-NI 확장이 없어서 구현 차이가 그대로 드러난다.
  if command -v openssl >/dev/null 2>&1; then
    print "  검증 중 (sha256 via openssl, 약 2.4초/GB): $(basename "$f")"
    got=$(openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF}')
  elif command -v sha256sum >/dev/null 2>&1; then
    print "  검증 중 (sha256, 약 6.5초/GB): $(basename "$f")"
    got=$(sha256sum "$f" | cut -d' ' -f1)
  else
    print "  (sha256 도구 없음 — 검증 생략)"; return 0
  fi
  if [ "$got" = "$want" ]; then print "  ✓ sha256 일치: $(basename "$f")"; return 0; fi
  print "  ✗ sha256 불일치: $(basename "$f")" >&2
  print "     기대: $want" >&2
  print "     실제: $got" >&2
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# [FIX 4] 이름 짓기
#
# 예전에는 디렉터리 이름을 사람이 먼저 타이핑하게 했다. 그 결과 models/ 안에는
# 양자화 수준이 빠진 디렉터리(Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive)와
# 제작자가 빠진 디렉터리가 섞여 남았다. 사람이 매번 정확히 옮겨 적을 이유가 없다 —
# URL 이 그 정보를 이미 다 갖고 있다.
#
# 규칙: <제작자>_<파일명 stem>  (stem 안에 제작자가 이미 있으면 중복은 지운다)
#   https://huggingface.co/HauhauCS/Qwen3.8-...-MTP-GGUF/resolve/main/
#     Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-Q6_K_P.gguf
#   →  HauhauCS_Qwen3.8-27B-Uncensored-Aggressive-Q6_K_P
# ─────────────────────────────────────────────────────────────────────────────

# %XX 디코드. 퍼센트 인코딩이 실제로 들어 있을 때만 건드린다 —
# 'printf %b' 는 문자열 안의 백슬래시도 해석하므로 무조건 태우면 안 된다.
_urldecode() {
  case "$1" in
    *%[0-9A-Fa-f][0-9A-Fa-f]*) printf '%b' "${1//%/\\x}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# URL → 파일 이름 (쿼리스트링 ?download=true 제거)
url_basename() {
  local u="${1%%\?*}"
  _urldecode "${u##*/}"
}

# Hugging Face 웹페이지(blob) 링크도 실제 파일(resolve) 링크로 변환한다.
# 사용자가 브라우저 주소창의 링크를 그대로 붙여 넣어도 HTML을 받지 않게 한다.
normalize_hf_url() {
  local url="$1"
  case "$url" in
    https://huggingface.co/*/blob/*)
      printf '%s\n' "${url/\/blob\//\/resolve\/}" ;;
    *)
      printf '%s\n' "$url" ;;
  esac
}

# https://huggingface.co/<owner>/<repo>/... → owner
hf_owner_from_url() {
  local url="${1%%\?*}" rest
  case "$url" in https://huggingface.co/*) ;; *) return 0 ;; esac
  rest="${url#https://huggingface.co/}"
  case "$rest" in
    datasets/*|spaces/*|models/*) rest="${rest#*/}" ;;
  esac
  case "$rest" in */*) printf '%s' "${rest%%/*}" ;; esac
}

hf_repo_from_url() {
  local url="${1%%\?*}" rest
  case "$url" in https://huggingface.co/*) ;; *) return 0 ;; esac
  rest="${url#https://huggingface.co/}"
  case "$rest" in datasets/*|spaces/*|models/*) rest="${rest#*/}" ;; esac
  rest="${rest#*/}"
  printf '%s' "${rest%%/*}"
}

# 파일 이름으로 쓸 수 없는 문자를 _ 로. 앞뒤 구분자도 정리한다.
sanitize_name() {
  local s="${1//[!A-Za-z0-9._-]/_}"
  s="${s##[-._]}"; s="${s%%[-._]}"
  printf '%s' "$s"
}

# stem 에서 토큰 하나를 구분자 경계로 제거 (대소문자 무시).
# 'HauhauCS' 를 지울 때 'HauhauCSX' 같은 다른 단어를 건드리면 안 되므로 경계를 본다.
_strip_token() {
  local s="$1" tok="$2"
  [ -n "$tok" ] || { printf '%s' "$s"; return 0; }
  tok="${tok//./\\.}"
  printf '%s' "$s" | sed -E "s/(^|[-_.])${tok}([-_.]|\$)/\1/I; s/^[-_.]+//; s/[-_.]+\$//"
}

# 모델 URL → 제안할 이름
suggest_name() {
  local url="$1" base stem owner repo
  base=$(url_basename "$url")
  stem="${base%.[Gg][Gg][Uu][Ff]}"
  [ -n "$stem" ] || return 0
  owner=$(hf_owner_from_url "$url")
  repo=$(hf_repo_from_url "$url")
  if [ -n "$owner" ]; then
    stem=$(_strip_token "$stem" "$owner")
    stem="${owner}_${stem}"
  fi
  if printf '%s' "$repo" | grep -qiE '(^|[-_.])mtp([-_.]|$)' \
      && ! printf '%s' "$stem" | grep -qiE '(^|[-_.])mtp([-_.]|$)'; then
    stem="${stem}-MTP"
  fi
  sanitize_name "$stem"
}

# 프로젝션 파일명에서 정밀도 태그만 뽑는다 (f16, bf16, q8_0 ...).
# 보통 이름 끝쪽에 붙으므로 마지막 매치를 쓴다.
proj_tag() {
  local base="$1" low t
  low=$(printf '%s' "${base%.[Gg][Gg][Uu][Ff]}" | tr '[:upper:]' '[:lower:]')
  t=$(printf '%s' "$low" | grep -oE '(bf16|fp16|f16|fp32|f32|q[0-9]+(_[0-9a-z]+)*)' | tail -n1 || true)
  # 하이픈은 반드시 남긴다. run_llama_server.sh 는 '*mmproj-*.gguf' 로 찾는다.
  printf '%s' "mmproj-${t:-default}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 대화형 입력 — URL 을 먼저 받고, 이름은 거기서 뽑아 제안한다.
# ─────────────────────────────────────────────────────────────────────────────
read -p "Model GGUF URL: " MODEL_URL
if [ -z "$MODEL_URL" ]; then
  print "Model GGUF URL is required." >&2; exit 1
fi
MODEL_URL=$(normalize_hf_url "$MODEL_URL")

read -p "Projection GGUF URL (leave empty if none): " PROJ_URL
PROJ_URL=$(normalize_hf_url "$PROJ_URL")
read -p "MTP GGUF URL (leave empty if none): " MTP_URL
MTP_URL=$(normalize_hf_url "$MTP_URL")

# [FIX 5] gated 여부는 20GB 를 태우고 나서가 아니라 시작 전에 알아야 한다.
# 다운로드는 백그라운드 잡으로 도는데, 거기서 토큰을 물어볼 수는 없다(입력이 섞인다).
# 그래서 여기, 아직 프롬프트가 안전한 지점에서 한 번 확인한다. 요청 1회.
if [ -z "${HF_TOKEN:-}" ] && _is_gated "$MODEL_URL"; then
  print ""
  print "⛔ 이 저장소는 로그인/약관 동의가 필요한 gated 저장소입니다."
  print "   먼저 HF 웹에서 해당 모델의 약관에 동의했는지 확인하세요."
  print "   토큰: https://huggingface.co/settings/tokens (read 권한이면 충분)"
  read -r -s -p "HF 토큰을 붙여넣으세요 (그냥 Enter 면 중단): " _tok; print ""
  if [ -z "$_tok" ]; then
    print "토큰 없이는 이 저장소를 받을 수 없습니다." >&2; exit 1
  fi
  HF_TOKEN="$_tok"; unset _tok
fi


case "$(url_basename "$MODEL_URL")" in
  *.[Gg][Gg][Uu][Ff]) ;;
  *) print "⚠ 모델 URL 이 .gguf 로 끝나지 않습니다. 이름이 이상하게 잡힐 수 있습니다." ;;
esac

SUGGESTED=$(suggest_name "$MODEL_URL" || true)

MODEL_DIR_NAME=""
if [ -n "$SUGGESTED" ]; then
  print ""
  print "URL 에서 뽑은 이름:"
  print "  디렉터리  : models/$SUGGESTED/"
  print "  모델 파일 : ${SUGGESTED}.gguf"
  if [ -n "$PROJ_URL" ]; then
    print "  프로젝션  : ${SUGGESTED}_$(proj_tag "$(url_basename "$PROJ_URL")").gguf"
  fi
  if [ -n "$MTP_URL" ]; then
    print "  MTP 모델  : ${SUGGESTED}_mtp.gguf"
  fi
  read -p "이 이름을 쓸까요? (Y/n, 또는 원하는 이름을 직접 입력): " ans
  case "$ans" in
    ""|[Yy]|[Yy][Ee][Ss]) MODEL_DIR_NAME="$SUGGESTED" ;;
    [Nn]|[Nn][Oo]) ;;
    *) MODEL_DIR_NAME=$(sanitize_name "${ans%%/}") ;;
  esac
fi

if [ -z "$MODEL_DIR_NAME" ]; then
  read -p "Model directory name (will create models/<name>/): " MODEL_DIR_NAME
  MODEL_DIR_NAME=$(sanitize_name "${MODEL_DIR_NAME%%/}")
  if [ -z "$MODEL_DIR_NAME" ]; then
    print "Model directory name is required." >&2; exit 1
  fi
fi

TARGET_DIR="models/$MODEL_DIR_NAME"
mkdir -p "$TARGET_DIR"

MODEL_DEST="$TARGET_DIR/${MODEL_DIR_NAME}.gguf"
if [ -f "$MODEL_DEST" ]; then
  read -p "$MODEL_DEST exists. Overwrite? (y/N): " o
  o=${o:-N}
  if [[ ! "$o" =~ ^[Yy]$ ]]; then
    print "Aborting: model file exists."; exit 1
  fi
  rm -f "$MODEL_DEST"
fi

PROJ_DEST=""
if [ -n "$PROJ_URL" ]; then
  PROJ_DEST="$TARGET_DIR/${MODEL_DIR_NAME}_$(proj_tag "$(url_basename "$PROJ_URL")").gguf"
  if [ -f "$PROJ_DEST" ]; then
    read -p "$PROJ_DEST exists. Overwrite? (y/N): " o2
    o2=${o2:-N}
    if [[ ! "$o2" =~ ^[Yy]$ ]]; then
      print "Skipping projection download (file exists)."; PROJ_URL=""; PROJ_DEST=""
    else
      rm -f "$PROJ_DEST"
    fi
  fi
fi

MTP_DEST=""
if [ -n "$MTP_URL" ]; then
  MTP_DEST="$TARGET_DIR/${MODEL_DIR_NAME}_mtp.gguf"
  if [ -f "$MTP_DEST" ]; then
    read -p "$MTP_DEST exists. Overwrite? (y/N): " o3
    o3=${o3:-N}
    if [[ ! "$o3" =~ ^[Yy]$ ]]; then
      print "Skipping MTP download (file exists)."; MTP_URL=""; MTP_DEST=""
    else
      rm -f "$MTP_DEST"
    fi
  fi
fi

# 다운로드를 시작하기 전에 기대 해시를 미리 받아 둔다. 네트워크 호출이 가볍고,
# 여기서 받아 두면 백그라운드 잡들과 경쟁하지 않는다.
MODEL_SHA=$(hf_sha_for_url "$MODEL_URL" || true)
PROJ_SHA=""
[ -n "$PROJ_URL" ] && PROJ_SHA=$(hf_sha_for_url "$PROJ_URL" || true)
MTP_SHA=""
[ -n "$MTP_URL" ] && MTP_SHA=$(hf_sha_for_url "$MTP_URL" || true)
[ -n "$MODEL_SHA" ] && print "기대 sha256 (model): $MODEL_SHA"
[ -n "$PROJ_SHA" ]  && print "기대 sha256 (proj) : $PROJ_SHA"
[ -n "$MTP_SHA" ]   && print "기대 sha256 (mtp)  : $MTP_SHA"

print "Starting downloads..."
PIDS=()

download "$MODEL_URL" "$MODEL_DEST" &
PIDS+=("$!")

if [ -n "$PROJ_URL" ]; then
  download "$PROJ_URL" "$PROJ_DEST" &
  PIDS+=("$!")
fi
if [ -n "$MTP_URL" ]; then
  download "$MTP_URL" "$MTP_DEST" &
  PIDS+=("$!")
fi

FAIL=0
for p in "${PIDS[@]:-}"; do
  if ! wait "$p"; then
    print "A download failed (pid $p)." >&2
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  print "One or more downloads failed. 다시 실행하면 이어받습니다." >&2
  exit 1
fi

# ─── 무결성 검증 ───
print ""
print "── 무결성 검증 ──"
if ! verify_sha "$MODEL_DEST" "$MODEL_SHA"; then FAIL=1; fi
if [ -n "$PROJ_DEST" ] && ! verify_sha "$PROJ_DEST" "$PROJ_SHA"; then FAIL=1; fi
if [ -n "$MTP_DEST" ] && ! verify_sha "$MTP_DEST" "$MTP_SHA"; then FAIL=1; fi

if [ "$FAIL" -ne 0 ]; then
  print "" >&2
  print "파일이 손상되었습니다. 다시 실행하면 이어받기를 시도합니다." >&2
  print "그래도 안 되면 지우고 처음부터 받으세요: rm '$TARGET_DIR'/*.gguf" >&2
  exit 1
fi

print ""
print "Downloads complete. Saved to:"
ls -1sh "$TARGET_DIR"

exit 0
