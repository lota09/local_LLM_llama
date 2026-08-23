#!/usr/bin/env python3
"""models/<이름>/ 아래로 GGUF 모델과 (선택) mmproj 를 받는다.

download_model.sh 의 파이썬 판이다. 두 파일은 같은 규칙을 따라야 한다:
동작이 갈리면 sh 가 기준이다.

예전 파이썬 판이 sh 와 달랐던 점(전부 여기서 맞췄다):
  - 재시도가 죽어 있었다. except 절 끝의 `break` 가 첫 실패에서 루프를 빠져나가
    "3회 재시도" 가 한 번도 돌지 않았다. sh 의 [FIX 2] 와 같은 종류의 버그다.
  - 실패하면 받다 만 파일을 지웠다. 그러면 다음 실행에서 이어받을 수가 없다.
  - Range 요청을 보내고 서버 응답 코드를 안 봤다. 서버가 206 대신 200(전체)을
    돌려주면 기존 파일 뒤에 처음부터 다시 붙여서 파일을 조용히 망가뜨린다.
    → 이어받기는 wget -c / curl -C - 에게 맡긴다. 이미 검증된 구현이다.
  - HF_TOKEN(gated 저장소), sha256 검증, 모델/프로젝션 동시 다운로드가 없었다.
"""
import concurrent.futures
import getpass
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

SKIP_VERIFY = os.environ.get("SKIP_VERIFY", "0") == "1"

# ─────────────────────────────────────────────────────────────────────────────
# MTP(다중 토큰 예측) 사이드카 판별
#
# 예전 정규식은 (^|[-_.])mtp([-_.]|$) 였다. 구분자로 둘러싸인 'mtp' 만 인정하므로
# HauhauCS 저장소의 'Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-FastMTP-32K.gguf'
# 를 놓쳤다. 그 파일은 MTP 선택 목록에 아예 뜨지 않았고(=받을 방법이 없었고),
# 대신 본 모델 목록에 양자화 'unknown' 으로 섞여 들어갔다.
#
# 이제 구분자로 시작하는 토큰이 'mtp'(뒤에 숫자 허용)로 끝나면 사이드카로 본다.
# 'MTP', 'FastMTP', 'mtp2' 가 모두 걸리고, 'Q6_K_P' 같은 양자화 태그는 안 걸린다.
# ─────────────────────────────────────────────────────────────────────────────
MTP_RE = re.compile(r"(?:^|[-_.])[A-Za-z]*mtp[0-9]*(?:[-_.]|$)", re.IGNORECASE)


def is_mtp_name(name):
    """파일 이름(또는 저장소 이름)이 MTP 를 가리키면 True."""
    return bool(MTP_RE.search(os.path.basename(name)))


# ─────────────────────────────────────────────────────────────────────────────
# HF 토큰
#
# gated 저장소(Llama, Gemma, FLUX 계열 등)는 토큰이 있어야 받아진다. 예전에는
# 토큰을 환경변수로만 받았고, 게다가 다운로드 요청에만 붙였다. 그래서 sha256 정답지를
# 가져오는 HF API 호출이 401 을 받고 빈 문자열을 돌려줬고, 화면에는
# "sha256 정보 없음 — 검증 생략" 만 떴다. 정작 검증이 가장 필요한 gated 20GB 짜리에서
# 검증이 조용히 사라지는 셈이다. 이제 API 호출에도 같은 토큰을 붙인다.
#
# 출처 우선순위: HF_TOKEN → HUGGING_FACE_HUB_TOKEN → huggingface-cli 로그인 파일
# ─────────────────────────────────────────────────────────────────────────────
def _resolve_hf_token():
    for var in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"):
        if os.environ.get(var):
            return os.environ[var].strip()
    path = os.path.join(os.environ.get("HF_HOME") or
                        os.path.expanduser("~/.cache/huggingface"), "token")
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


HF_TOKEN = _resolve_hf_token()


def _auth_header():
    return {"Authorization": f"Bearer {HF_TOKEN}"} if HF_TOKEN else {}


def prompt(msg):
    try:
        return input(msg).strip()
    except EOFError:
        return ""


# ─────────────────────────────────────────────────────────────────────────────
# 다운로드 — 이어받기는 wget -c / curl -C - 가 한다.
# wget -c 는 Content-Range 를 확인하고 이어받으며, HF 의 302 → 서명 CDN 리다이렉트
# 너머로도 정상 동작하는 것을 실측 확인했다(206 Partial Content + sha256 일치).
#
# 진행 표시는 우리가 직접 그린다. 예전에는 wget/curl 이 각자 자기 진행률을 같은
# 터미널에 그렸는데, 이 스크립트는 모델·mmproj·MTP 를 **동시에** 받으므로 세 프로세스가
# 서로 커서를 뺏어 한 줄에 겹쳐 찍혔다. 그래서 받는 쪽은 조용히(-q) 돌리고
# 화면은 여기서 혼자 그린다 — 파일 하나당 한 줄, 매번 같은 자리를 다시 쓴다.
#
# 진행률은 다운로더 출력을 파싱하지 않고 목적지 파일 크기를 직접 잰다. 전체 크기는
# HF 트리 API 가 준 값(size, 실제 파일 크기와 바이트까지 일치하는 것을 실측 확인)이라
# 정확하고, 이어받기(부분 파일)도 그냥 맞아떨어진다. 파싱할 게 없으니 wget/curl 의
# 버전·로케일 차이도 안 탄다.
# ─────────────────────────────────────────────────────────────────────────────
def _fmt_bytes(n):
    n = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def _fmt_eta(sec):
    if not sec or sec <= 0 or sec > 99 * 3600:
        return "--:--"
    minutes, seconds = divmod(int(sec), 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours}:{minutes:02d}:{seconds:02d}" if hours else f"{minutes:02d}:{seconds:02d}"


class Job:
    """받을 파일 하나. 상태는 다운로드 스레드가 쓰고 그리는 쪽이 읽는다.

    파이썬 문자열/정수 대입은 원자적이라 잠금이 필요 없다(읽는 쪽은 한 프레임
    늦은 값을 봐도 아무 문제가 없다).
    """

    def __init__(self, label, url, dest, total=0, sha="", resumed=0):
        self.label = label
        self.url = url
        self.dest = dest
        self.total = total or 0
        self.sha = sha
        self.resumed = resumed        # 시작 시점에 이미 있던 바이트 수
        self.state = "대기"
        self.note = ""
        self.ok = False
        self.err = ""
        self.speed = 0.0
        self._last = None             # (시각, 바이트)

    def current(self):
        try:
            return os.path.getsize(self.dest)
        except OSError:
            return 0

    def tick(self, now):
        """0.3초 이상 지났으면 속도를 갱신한다(지수 평활)."""
        cur = self.current()
        if self._last is None:
            self._last = (now, cur)
            return cur
        dt = now - self._last[0]
        if dt >= 0.3:
            inst = max(0, cur - self._last[1]) / dt
            self.speed = inst if self.speed == 0 else self.speed * 0.7 + inst * 0.3
            self._last = (now, cur)
        return cur


def _downloader_cmd(url, dest):
    """(cmd, 도구이름) 또는 (None, None). 진행 표시는 우리가 그리므로 조용히 돌린다."""
    if shutil.which("wget"):
        cmd = ["wget", "-q"]
        if HF_TOKEN:
            cmd.append(f"--header=Authorization: Bearer {HF_TOKEN}")
        return cmd + ["-c", "-O", dest, url], "wget"
    if shutil.which("curl"):
        cmd = ["curl", "-L", "--fail", "-sS"]
        if HF_TOKEN:
            cmd += ["-H", f"Authorization: Bearer {HF_TOKEN}"]
        if os.path.exists(dest):
            cmd += ["-C", "-"]
        return cmd + ["-o", dest, url], "curl"
    return None, None


def download(job, max_retries=3):
    """한 파일을 받는다. 화면에 직접 찍지 않고 job 의 상태만 바꾼다."""
    for attempt in range(1, max_retries + 1):
        cmd, _tool = _downloader_cmd(job.url, job.dest)
        if cmd is None:
            job.state, job.note = "실패", "curl 또는 wget 이 필요합니다"
            return False
        job.state = "받는 중"
        if attempt > 1:
            job.note = f"재시도 {attempt}/{max_retries}"
        proc = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if proc.returncode == 0:
            job.state, job.note, job.ok = "완료", "", True
            return True
        job.err = (proc.stderr or b"").decode("utf-8", "replace").strip()

        # 인증 문제라면 세 번 더 해봐야 세 번 다 실패한다. 즉시 원인을 알려주고 빠져나온다.
        # (여기서 화면에 찍으면 진행 표시가 깨지므로 note 에만 남긴다.)
        if not HF_TOKEN and _is_gated(job.url):
            job.state, job.note = "실패", "gated 저장소 — HF_TOKEN 이 필요합니다"
            return False

        if attempt < max_retries:
            job.state = "대기"
            for remain in range(attempt * 10, 0, -1):
                job.note = f"실패 — {remain}초 후 재시도 ({attempt + 1}/{max_retries})"
                time.sleep(1)

    job.state, job.note = "실패", "최대 재시도 횟수 초과"
    # 여기서 파일을 지우지 않는다. 부분 파일이 남아 있어야 다음 실행에서 이어받을 수 있고,
    # sha256 검증이 "받다 만 것"인지 "깨진 것"인지 구분해 준다.
    return False


def _render(jobs, width):
    lines = []
    for j in jobs:
        head = f"{j.label:<7}"
        if j.state in ("완료", "실패"):
            mark = "✓" if j.ok else "✗"
            lines.append(f"{head} {mark} {j.state}{('  ' + j.note) if j.note else ''}")
            continue
        cur = j.current()
        if j.total:
            frac = min(1.0, cur / j.total)
            filled = int(24 * frac)
            bar = "█" * filled + "░" * (24 - filled)
            eta = (j.total - cur) / j.speed if j.speed > 0 else 0
            line = (f"{head} {bar} {frac * 100:5.1f}%  "
                    f"{_fmt_bytes(cur)}/{_fmt_bytes(j.total)}  "
                    f"{_fmt_bytes(j.speed)}/s  ETA {_fmt_eta(eta)}")
        else:
            line = f"{head} {_fmt_bytes(cur)}  {_fmt_bytes(j.speed)}/s"
        lines.append(line + (f"  {j.note}" if j.note else ""))
    return [ln[:width] for ln in lines]


def run_jobs(jobs):
    """모든 잡을 동시에 받으면서 잡마다 한 줄씩 진행률을 그린다."""
    if not jobs:
        return True
    tty = sys.stdout.isatty()
    drawn = 0
    last_plain = 0.0

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(jobs)) as pool:
        futures = [pool.submit(download, j) for j in jobs]
        while True:
            running = not all(f.done() for f in futures)
            now = time.monotonic()
            for j in jobs:
                j.tick(now)
            if tty:
                # 창 크기는 매 프레임 다시 본다. 줄이 터미널 폭을 넘으면 자동 줄바꿈이
                # 일어나 '올릴 줄 수'가 어긋나므로, 폭보다 한 칸 짧게 잘라서 그린다.
                width = max(40, shutil.get_terminal_size((100, 24)).columns - 1)
                # 이미 그린 줄 수만큼 커서를 올리고(ESC[nA) 각 줄을 지운 뒤 다시 쓴다.
                out = [f"\033[{drawn}A"] if drawn else []
                lines = _render(jobs, width)
                out += ["\r\033[2K" + ln + "\n" for ln in lines]
                sys.stdout.write("".join(out))
                sys.stdout.flush()
                drawn = len(lines)
            elif now - last_plain >= 20 or not running:
                # 로그로 리다이렉트된 경우. 커서 제어는 쓰레기만 남기므로 주기적으로 한 줄씩.
                for ln in _render(jobs, 200):
                    print(ln, flush=True)
                last_plain = now
            if not running:
                break
            time.sleep(0.4)

    ok = all(j.ok for j in jobs)
    for j in jobs:
        if not j.ok and j.err:
            print("", file=sys.stderr)
            print(f"[{j.label}] {j.url}", file=sys.stderr)
            for ln in j.err.splitlines()[-5:]:
                print(f"  {ln}", file=sys.stderr)
    return ok


def _is_gated(url):
    """gated 저장소 판별 (요청 1회). 조용히 참/거짓만 돌려준다."""
    try:
        req = urllib.request.Request(url, method="HEAD",
                                     headers={"User-Agent": "wget/1.21",
                                              **_auth_header()})
        urllib.request.urlopen(req, timeout=15)
        return False
    except urllib.error.HTTPError as e:
        return e.code in (401, 403)
    except Exception:
        return False


def _diagnose_gated(url):
    if not _is_gated(url):
        return False
    print("", file=sys.stderr)
    print("⛔ 이 저장소는 로그인/약관 동의가 필요한 gated 저장소입니다.", file=sys.stderr)
    print("   HF 웹에서 해당 모델의 약관에 동의한 뒤 토큰을 주고 재실행하세요:", file=sys.stderr)
    print("     HF_TOKEN=hf_xxx python3 download_model.py", file=sys.stderr)
    return True


def ensure_token(model_url):
    """gated 여부는 20GB 를 태우고 나서가 아니라 시작 전에 알아야 한다.

    다운로드는 스레드로 도는데 거기서 토큰을 물어볼 수는 없다(입력이 섞인다).
    그래서 아직 프롬프트가 안전한 이 지점에서 한 번 확인한다. 요청 1회.
    """
    global HF_TOKEN
    if HF_TOKEN or not _is_gated(model_url):
        return
    print("")
    print("⛔ 이 저장소는 로그인/약관 동의가 필요한 gated 저장소입니다.")
    print("   먼저 HF 웹에서 해당 모델의 약관에 동의했는지 확인하세요.")
    print("   토큰: https://huggingface.co/settings/tokens (read 권한이면 충분)")
    tok = getpass.getpass("HF 토큰을 붙여넣으세요 (그냥 Enter 면 중단): ").strip()
    if not tok:
        print("토큰 없이는 이 저장소를 받을 수 없습니다.", file=sys.stderr)
        sys.exit(1)
    HF_TOKEN = tok


# ─────────────────────────────────────────────────────────────────────────────
# 무결성 검증
#
# HuggingFace API 의 lfs.oid 는 파일 내용의 sha256 이다. 즉 정답지를 서버가 준다.
# 이걸 안 쓰면 20GB 짜리 GGUF 가 조용히 잘려도 그 자리에서는 알 수 없고,
# 나중에 llama-server 가 'invalid magic' 이나 알 수 없는 로드 실패로만 알려준다.
# ─────────────────────────────────────────────────────────────────────────────
def _sha256(path):
    # openssl 이 파이썬 hashlib/coreutils sha256sum 보다 빠르다. 같은 12.7GB 파일 실측:
    #     sha256sum  78.6s (154 MB/s)   ← 이식성 위주의 C 구현
    #     openssl    29.0s (419 MB/s)   ← 어셈블리(AVX2) 최적화
    # 이 CPU(Coffee Lake)에는 SHA-NI 확장이 없어서 구현 차이가 그대로 드러난다.
    if shutil.which("openssl"):
        print(f"  검증 중 (sha256 via openssl, 약 2.4초/GB): {os.path.basename(path)}", flush=True)
        out = subprocess.run(["openssl", "dgst", "-sha256", path],
                             capture_output=True, text=True)
        if out.returncode == 0:
            return out.stdout.strip().split()[-1]
    print(f"  검증 중 (sha256, 약 6.5초/GB): {os.path.basename(path)}", flush=True)
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_sha(path, want):
    """일치하거나 검증 불가면 True, 불일치면 False."""
    if not os.path.isfile(path):
        return False
    if not want:
        print("  (sha256 정보 없음 — 검증 생략)")
        return True
    if SKIP_VERIFY:
        print("  (SKIP_VERIFY=1 — 검증 생략)")
        return True
    # HF 는 gated 저장소의 해시를 별표로 가린다. 그대로 비교하면 항상 불일치가 된다.
    if not re.fullmatch(r"[0-9a-fA-F]{64}", want):
        print("  (HF 가 해시를 가린 저장소 — 검증 생략)")
        return True
    got = _sha256(path)
    if got == want:
        print(f"  ✓ sha256 일치: {os.path.basename(path)}")
        return True
    print(f"  ✗ sha256 불일치: {os.path.basename(path)}", file=sys.stderr)
    print(f"     기대: {want}", file=sys.stderr)
    print(f"     실제: {got}", file=sys.stderr)
    return False


# ─────────────────────────────────────────────────────────────────────────────
# 이름 짓기
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
def url_basename(url):
    """URL → 파일 이름 (쿼리스트링 ?download=true 제거, %XX 디코드)."""
    path = urllib.parse.urlparse(url).path
    return urllib.parse.unquote(os.path.basename(path))


def normalize_hf_url(url):
    """Hugging Face blob 웹페이지 URL을 실제 resolve 다운로드 URL로 변환한다."""
    parsed = urllib.parse.urlsplit(url)
    parts = parsed.path.split("/")
    if parsed.netloc == "huggingface.co" and "blob" in parts:
        parts[parts.index("blob")] = "resolve"
        parsed = parsed._replace(path="/".join(parts))
        return urllib.parse.urlunsplit(parsed)
    return url


def hf_owner_from_url(url):
    """https://huggingface.co/<owner>/<repo>/... → owner."""
    p = urllib.parse.urlparse(url)
    if p.netloc != "huggingface.co":
        return ""
    parts = [x for x in p.path.split("/") if x]
    if parts and parts[0] in ("datasets", "spaces", "models"):
        parts = parts[1:]
    return parts[0] if len(parts) >= 2 else ""


def hf_repo_from_url(url):
    """https://huggingface.co/<owner>/<repo>/... → repo name."""
    p = urllib.parse.urlparse(url)
    if p.netloc != "huggingface.co":
        return ""
    parts = [x for x in p.path.split("/") if x]
    if parts and parts[0] in ("datasets", "spaces", "models"):
        parts = parts[1:]
    return parts[1] if len(parts) >= 2 else ""


def sanitize_name(name):
    """파일 이름으로 쓸 수 없는 문자를 _ 로. 앞뒤 구분자도 정리한다."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", name).strip("-._")


def _strip_token(stem, token):
    """stem 에서 토큰 하나를 구분자 경계로 제거 (대소문자 무시).

    'HauhauCS' 를 지울 때 'HauhauCSX' 같은 다른 단어를 건드리면 안 되므로 경계를 본다.
    """
    if not token:
        return stem
    pat = re.compile(r"(^|[-_.])" + re.escape(token) + r"([-_.]|$)", re.IGNORECASE)
    return pat.sub(r"\1", stem, count=1).strip("-._")


def suggest_name(model_url):
    """모델 URL → 제안할 디렉터리/파일 이름."""
    stem = re.sub(r"\.gguf$", "", url_basename(model_url), flags=re.IGNORECASE)
    if not stem:
        return ""
    owner = hf_owner_from_url(model_url)
    if owner:
        stem = f"{owner}_{_strip_token(stem, owner)}"
    repo = hf_repo_from_url(model_url)
    if is_mtp_name(repo) and not is_mtp_name(stem):
        stem = f"{stem}-MTP"
    return sanitize_name(stem)


def proj_tag(basename):
    """프로젝션 파일명에서 정밀도 태그만 뽑는다 (f16, bf16, q8_0 ...).

    보통 이름 끝쪽에 붙으므로 마지막 매치를 쓴다.
    """
    low = re.sub(r"\.gguf$", "", basename, flags=re.IGNORECASE).lower()
    found = re.findall(r"bf16|fp16|f16|fp32|f32|q[0-9]+(?:_[0-9a-z]+)*", low)
    # 하이픈은 반드시 남긴다. run_llama_server.sh 는 '*mmproj-*.gguf' 로 찾는다.
    return f"mmproj-{found[-1] if found else 'default'}"


# ─────────────────────────────────────────────────────────────────────────────
# 대화형 입력 — URL 을 먼저 받고, 이름은 거기서 뽑아 제안한다.
# ─────────────────────────────────────────────────────────────────────────────
def ask_names(model_url, proj_url, name_suffix=""):
    if not url_basename(model_url).lower().endswith(".gguf"):
        print("⚠ 모델 URL 이 .gguf 로 끝나지 않습니다. 이름이 이상하게 잡힐 수 있습니다.")
    suggested = suggest_name(model_url)
    if suggested and name_suffix and not is_mtp_name(suggested):
        suggested = f"{suggested}{name_suffix}"
    if suggested:
        print("")
        print("URL 에서 뽑은 이름:")
        print(f"  디렉터리  : models/{suggested}/")
        print(f"  모델 파일 : {suggested}.gguf")
        if proj_url:
            print(f"  프로젝션  : {suggested}_{proj_tag(url_basename(proj_url))}.gguf")
        ans = prompt("이 이름을 쓸까요? (Y/n, 또는 원하는 이름을 직접 입력): ")
        low = ans.lower()
        if ans == "" or low in ("y", "yes"):
            return suggested
        if low not in ("n", "no"):
            return sanitize_name(ans.rstrip("/"))

    name = sanitize_name(prompt("Model directory name (will create models/<name>/): ").rstrip("/"))
    if not name:
        print("Model directory name is required.", file=sys.stderr)
        sys.exit(1)
    return name


# ─────────────────────────────────────────────────────────────────────────────
# 이미 있는 파일 처리 — 건너뛰기 / 이어받기
#
# 예전에는 목적지에 파일이 있으면 무조건 "Overwrite? (y/N)" 를 물었고,
#   y → os.remove() 로 지우고 처음부터   N → 본 모델이면 통째로 중단
# 이었다. 그래서 30GB 를 25GB 까지 받다 끊긴 뒤 다시 실행하면, 받아 둔 25GB 를
# 버리고 처음부터 받거나 아예 아무것도 못 하거나 둘 중 하나였다.
# 실패 메시지의 "다시 실행하면 이어받습니다" 는 사실이 아니었던 셈이다.
# (이어받기 자체는 wget -c 가 잘 한다. 실측: 부분 파일 → 206 Partial Content,
#  이어받은 파일의 sha256 이 새로 받은 것과 일치.)
#
# 이제 HF 가 알려준 기대 크기와 실제 파일 크기를 비교해서 스스로 정한다:
#   같다      → 건너뛴다 (VERIFY_ALL=1 이면 sha256 도 확인, REDOWNLOAD=1 이면 새로 받는다)
#   작다      → 이어받는다 (묻지 않는다)
#   크다/모름 → 그때만 사람에게 묻는다
# ─────────────────────────────────────────────────────────────────────────────
REDOWNLOAD = os.environ.get("REDOWNLOAD", "0") == "1"
VERIFY_ALL = os.environ.get("VERIFY_ALL", "0") == "1"


def plan_file(label, url, dest, total, sha):
    """받을 Job 을 돌려준다. 받을 필요가 없으면 None."""
    name = os.path.basename(dest)
    if not os.path.exists(dest):
        return Job(label, url, dest, total, sha)

    cur = os.path.getsize(dest)
    if total and cur == total and not REDOWNLOAD:
        print(f"  {label:<7} 이미 받아져 있습니다 ({_fmt_bytes(cur)}) — 건너뜁니다: {name}")
        return None
    if total and cur < total:
        pct = cur / total * 100
        print(f"  {label:<7} 받다 만 파일 {_fmt_bytes(cur)}/{_fmt_bytes(total)} "
              f"({pct:.1f}%) — 이어받습니다: {name}")
        return Job(label, url, dest, total, sha, resumed=cur)
    if total and cur == total and REDOWNLOAD:
        print(f"  {label:<7} REDOWNLOAD=1 — 지우고 새로 받습니다: {name}")
        os.remove(dest)
        return Job(label, url, dest, total, sha)

    # 기대 크기보다 크거나, 크기를 아예 모르는 경우(비 HF URL 등)만 사람에게 묻는다.
    why = (f"기대({_fmt_bytes(total)})보다 큽니다" if total else "기대 크기를 알 수 없습니다")
    print(f"  {label:<7} {name}: {_fmt_bytes(cur)} — {why}.")
    if not (prompt("          지우고 새로 받을까요? (y/N): ") or "N").lower().startswith("y"):
        print(f"  {label:<7} 그대로 두고 건너뜁니다.")
        return None
    os.remove(dest)
    return Job(label, url, dest, total, sha)


def hf_repo_from_input(url):
    """Return (owner, repo, revision) from an HF repo/tree URL."""
    parsed = urllib.parse.urlparse(url.rstrip("/"))
    if parsed.netloc != "huggingface.co":
        return "", "", "main"
    parts = [x for x in parsed.path.split("/") if x]
    if parts and parts[0] in ("models", "datasets", "spaces"):
        parts = parts[1:]
    if len(parts) < 2:
        return "", "", "main"
    revision = "main"
    if len(parts) >= 4 and parts[2] in ("tree", "blob", "resolve"):
        revision = parts[3]
    return parts[0], parts[1], revision


def list_repo_gguf_files(repo_url):
    """List GGUF files in an HF repository via its public tree API."""
    owner, repo, revision = hf_repo_from_input(repo_url)
    if not owner or not repo:
        print("Hugging Face repository URL is invalid.", file=sys.stderr)
        sys.exit(1)
    api = f"https://huggingface.co/api/models/{owner}/{repo}/tree/{revision}?recursive=true"
    req = urllib.request.Request(api, headers=_auth_header())
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            entries = json.load(response)
    except Exception as exc:
        print(f"Could not read repository file list: {exc}", file=sys.stderr)
        sys.exit(1)
    files = [e["path"] for e in entries
             if e.get("type") == "file" and e.get("path", "").lower().endswith(".gguf")]
    # 크기와 sha256(lfs.oid)을 여기서 같이 챙긴다. 이 한 번의 응답에 다 들어 있으므로
    # 파일마다 API 를 또 부를 이유가 없고, 크기를 알면 '이미 다 받았는지 / 어디까지
    # 받다 말았는지' 를 사람에게 묻지 않고 판단할 수 있다.
    meta = {e["path"]: (e.get("size") or 0, (e.get("lfs") or {}).get("oid", "") or "")
            for e in entries if e.get("type") == "file"}
    return owner, repo, revision, sorted(files), meta


def hf_file_url(owner, repo, revision, path):
    return (f"https://huggingface.co/{owner}/{repo}/resolve/"
            f"{urllib.parse.quote(revision)}/{urllib.parse.quote(path, safe='/')}?download=true")


def quantization_label(path):
    stem = os.path.basename(path).rsplit(".", 1)[0]
    found = re.findall(r"(?:^|[-_.])(Q[0-9]+(?:_[0-9A-Za-z]+)*|IQ[0-9]+(?:_[0-9A-Za-z]+)*|BF16|F16|F32)(?:[-_.]|$)", stem, re.IGNORECASE)
    return found[-1].upper() if found else "unknown"


def choose_file(label, files):
    print(f"\n{label} 선택:")
    for index, path in enumerate(files, 1):
        print(f"  [{index}] {os.path.basename(path)}")
    while True:
        answer = prompt(f"번호 선택 [기본값 1]: ") or "1"
        if answer.isdigit() and 1 <= int(answer) <= len(files):
            return files[int(answer) - 1]
        print("올바른 번호를 선택하세요.")


def main():
    repo_url = prompt("Hugging Face model repository URL: ")
    if not repo_url:
        print("Repository URL is required.", file=sys.stderr)
        sys.exit(1)
    owner, repo, revision, gguf_files, meta = list_repo_gguf_files(repo_url)
    if not gguf_files:
        print("No GGUF files found in the repository.", file=sys.stderr)
        sys.exit(1)

    model_files = [f for f in gguf_files if "mmproj" not in os.path.basename(f).lower()
                   and not is_mtp_name(f)]
    projection_files = [f for f in gguf_files if "mmproj" in os.path.basename(f).lower()]
    mtp_files = [f for f in gguf_files if is_mtp_name(f)]
    if not model_files and mtp_files:
        # 'Something-MTP.gguf' 처럼 본 모델 파일 이름 자체가 MTP 로 끝나는 저장소도
        # 있을 수 있다. 그런 곳에서 본 모델 목록이 통째로 비어 버리지 않게 되돌린다.
        model_files, mtp_files = mtp_files, []
    if not model_files:
        print("No base model GGUF files found.", file=sys.stderr)
        sys.exit(1)

    print(f"\n저장소: {owner}/{repo} (revision: {revision})")
    print("사용 가능한 양자화 수준:")
    for path in model_files:
        print(f"  - {quantization_label(path)}: {os.path.basename(path)}")
    model_file = choose_file("본 모델", model_files)
    model_url = hf_file_url(owner, repo, revision, model_file)

    proj_file = ""
    if projection_files:
        use_proj = (prompt("프로젝션 모델을 사용할까요? (Y/n): ") or "Y").lower().startswith("y")
        if use_proj:
            proj_file = choose_file("프로젝션 모델", projection_files)
    mtp_file = ""
    if mtp_files:
        use_mtp = (prompt("MTP 모델을 사용할까요? (y/N): ") or "N").lower().startswith("y")
        if use_mtp:
            mtp_file = choose_file("MTP 모델", mtp_files)

    proj_url = hf_file_url(owner, repo, revision, proj_file) if proj_file else ""
    mtp_url = hf_file_url(owner, repo, revision, mtp_file) if mtp_file else ""
    ensure_token(model_url)

    model_dir_name = ask_names(model_url, proj_url, "-MTP" if mtp_file else "")
    target_dir = os.path.join("models", model_dir_name)
    os.makedirs(target_dir, exist_ok=True)

    plans = [("model", model_file, model_url,
              os.path.join(target_dir, f"{model_dir_name}.gguf"))]
    if proj_url:
        plans.append(("mmproj", proj_file, proj_url, os.path.join(
            target_dir, f"{model_dir_name}_{proj_tag(url_basename(proj_url))}.gguf")))
    if mtp_url:
        plans.append(("mtp", mtp_file, mtp_url,
                      os.path.join(target_dir, f"{model_dir_name}_mtp.gguf")))

    print("")
    print("── 받을 파일 ──")
    jobs, skipped = [], []
    for label, path, url, dest in plans:
        total, sha = meta.get(path, (0, ""))
        job = plan_file(label, url, dest, total, sha)
        if job:
            jobs.append(job)
        elif os.path.exists(dest):
            skipped.append((label, dest, sha))

    if jobs:
        print("")
        ok = run_jobs(jobs)
        if not ok:
            print("", file=sys.stderr)
            print("일부 다운로드가 실패했습니다. 다시 실행하면 받다 만 지점부터 이어받습니다.",
                  file=sys.stderr)
            sys.exit(1)
    else:
        print("")
        print("모두 받아져 있습니다 — 받을 것이 없습니다.")

    # ─── 무결성 검증 ───
    # 이번에 받은(또는 이어받은) 파일만 검사한다. 이미 있던 파일까지 매번 다시
    # 해싱하면 30GB 당 70초 정도를 아무 일 없이 태우게 된다. 전부 확인하고 싶으면
    # VERIFY_ALL=1 로 실행한다.
    to_verify = [(j.label, j.dest, j.sha) for j in jobs]
    if VERIFY_ALL:
        to_verify += skipped
    elif skipped:
        print("")
        print(f"(건너뛴 파일 {len(skipped)}개는 크기만 확인했습니다. "
              f"sha256 까지 보려면 VERIFY_ALL=1 로 실행하세요.)")

    if to_verify:
        print("")
        print("── 무결성 검증 ──")
        bad = False
        for _label, dest, sha in to_verify:
            if not verify_sha(dest, sha):
                bad = True
        if bad:
            print("", file=sys.stderr)
            print("파일이 손상되었습니다. 다시 실행하면 이어받기를 시도합니다.", file=sys.stderr)
            print(f"그래도 안 되면 지우고 처음부터 받으세요: rm '{target_dir}'/*.gguf",
                  file=sys.stderr)
            sys.exit(1)

    print("")
    print("Downloads complete. Saved to:")
    subprocess.call(["ls", "-1sh", target_dir])


if __name__ == "__main__":
    main()
