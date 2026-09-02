#!/usr/bin/env python3
"""백엔드(ROCm/HIP vs Vulkan)별 추론 성능을 동일 조건에서 측정한다.

왜 llama-bench 가 아니라 llama-server 인가:
    build_llama_server.sh 는 llama-server 만 설치하므로 이 기기에 llama-bench
    바이너리가 없다. 다시 빌드하면(백엔드당 20~40분) 얻을 수 있지만, 굳이 그럴
    필요가 없다 — llama-server 는 요청마다 timings 를 돌려주고 /completion 의
    prompt 에 토큰 배열을 그대로 넣을 수 있어서, 프롬프트 길이를 토큰 단위로
    정확히 통제한 채 같은 지표(pp/tg)를 뽑을 수 있다.

    다만 llama-bench 와 완전히 같은 수치는 아니다. 차이의 원인은 두 가지다:
      (1) HTTP·토큰화·샘플링 오버헤드가 얇게 섞인다 (512토큰 이상에서는 무시할
          수준이지만 0 은 아니다)
      (2) llama-bench 는 측정에 필요한 최소 컨텍스트만 할당하는 반면 서버는
          -c 로 준 만큼 미리 잡는다. 이건 Vulkan 에서 특히 치명적이라
          (보고서 §5.2: ctx 32K 에서 tg 가 69.7 → 8.9 t/s 로 붕괴) 두 백엔드에
          "같은" -c 를 주는 것이 이 스크립트에서 가장 중요한 공정성 조건이다.
    그래서 서버 인자는 백엔드 이름과 디바이스만 빼고 전부 동일하게 고정한다.

사용법:
    python3 bench_backends.py                          # 기본: rocm, vulkan 둘 다
    python3 bench_backends.py --backends vulkan        # 하나만
    python3 bench_backends.py --ctx 4096 --reps 5
"""

import argparse
import json
import os
import re
import signal
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# 백엔드별 설치 디렉터리. 디바이스는 여기서 하드코딩하지 않고 --list-devices 로
# 실행 시점에 고른다 (아래 pick_device 주석 참고).
BACKENDS = {
    "rocm": "llama_server_rocm",
    "vulkan": "llama_server_vulkan",
}

DEFAULT_MODEL = os.path.join(
    SCRIPT_DIR, "models/gemma-4-26B-A4B-it-Q8_0/gemma-4-26B-A4B-it-Q8_0.gguf"
)

# 토큰 풀을 만들 원문. 내용은 처리량에 영향이 없으므로(같은 커널을 같은 횟수만큼
# 돈다) 아무 텍스트나 되지만, 토큰화가 잘 되도록 평범한 산문을 쓴다.
FILLER = (
    "The quick brown fox jumps over the lazy dog near the riverbank at dawn, "
    "while the fishermen prepare their nets and the village slowly wakes to "
    "the smell of bread and coffee drifting through the narrow streets. "
)


def log(msg):
    print(msg, flush=True)


# ── HTTP (curl 이 없는 기기라 urllib 을 쓴다) ───────────────────────────────
def post(port, path, payload, timeout=300):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def get(port, path, timeout=5):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=timeout) as r:
        return json.loads(r.read())


# ── 사전 점검 ──────────────────────────────────────────────────────────────
def amd_card_path():
    """AMD 카드의 /sys 경로. Intel iGPU 와 공존하므로 벤더 ID 로 찾는다."""
    import glob

    for vendor in glob.glob("/sys/class/drm/card*/device/vendor"):
        try:
            if open(vendor).read().strip() == "0x1002":
                return os.path.dirname(vendor)
        except OSError:
            pass
    return None


def read_clocks():
    """현재 sclk/mclk 을 (값, 최대값) 으로 돌려준다. 못 읽으면 None."""
    card = amd_card_path()
    if not card:
        return None
    out = {}
    for key, fname in (("sclk", "pp_dpm_sclk"), ("mclk", "pp_dpm_mclk")):
        try:
            lines = open(os.path.join(card, fname)).read().strip().splitlines()
        except OSError:
            return None
        # 형식: "1: 1000Mhz *"  — '*' 가 현재 레벨
        levels = [int(re.search(r"(\d+)Mhz", ln).group(1)) for ln in lines if "Mhz" in ln]
        cur = next(
            (int(re.search(r"(\d+)Mhz", ln).group(1)) for ln in lines if ln.endswith("*")),
            None,
        )
        out[key] = (cur, max(levels) if levels else None)
    return out


def vram_used_mib():
    card = amd_card_path()
    if not card:
        return None
    try:
        return int(open(os.path.join(card, "mem_info_vram_used")).read()) // (1024 * 1024)
    except OSError:
        return None


def check_clocks():
    """클럭이 고정되어 있는지 확인한다.

    이걸 놓치면 벤치 전체가 무의미해진다. auto DPM 은 이 카드의 LLM 부하를
    인식하지 못해 mclk 을 350MHz(최대의 35%)에 묶어두고, 그 상태의 실측치는
    pp 가 8.3배 낮게 나온다 (mi50_high.sh 주석 참고).
    """
    clocks = read_clocks()
    if not clocks:
        log("⚠️  클럭을 읽지 못했습니다. mi50_high.sh high 로 고정했는지 직접 확인하세요.")
        return
    parts = []
    low = False
    for key in ("sclk", "mclk"):
        cur, mx = clocks[key]
        parts.append(f"{key}={cur}/{mx}MHz")
        if cur is not None and mx and cur < mx * 0.9:
            low = True
    log(f"  클럭: {'  '.join(parts)}")
    if low:
        log("")
        log("⚠️  클럭이 최대치에 고정되어 있지 않습니다. 이 상태의 측정값은 신뢰할 수 없습니다:")
        log("      sudo bash mi50_high.sh high")
        log("    (auto DPM 은 이 카드에서 mclk 을 350MHz 에 묶어 pp 를 8.3배 떨어뜨립니다)")
        log("")
        if sys.stdin.isatty():
            if input("그래도 계속할까요? [y/N]: ").strip().lower() not in ("y", "yes"):
                sys.exit(1)


def pick_device(binary, libdir):
    """이 백엔드에서 쓸 디바이스를 --list-devices 결과에서 고른다.

    번호를 하드코딩하면 안 된다. 이 기기는 Intel UHD 630 과 MI50 이 함께 있어
    Vulkan 열거가 이렇게 나온다:
        Vulkan0: Intel(R) UHD Graphics 630 …
        Vulkan1: AMD Radeon Graphics (RADV VEGA20) …
    기본값(Vulkan0=iGPU)으로 돌면 벤치가 통째로 무의미해지고, 열거 순서는
    드라이버/커널 업데이트로 언제든 바뀔 수 있다. 그래서 매번 이름으로 고른다.
    """
    env = dict(os.environ, LD_LIBRARY_PATH=libdir)
    out = subprocess.run(
        [binary, "--list-devices"], env=env, capture_output=True, text=True, timeout=120
    )
    text = out.stdout + out.stderr
    cands = []
    for m in re.finditer(r"^\s*(\w+\d+):\s*(.+?)\s*\((\d+) MiB", text, re.M):
        name, desc, mib = m.group(1), m.group(2), int(m.group(3))
        # iGPU / CPU 폴백(llvmpipe, lavapipe) 은 제외한다.
        if re.search(r"intel|llvmpipe|lavapipe|swiftshader", desc, re.I):
            continue
        cands.append((name, desc, mib))
    if not cands:
        raise RuntimeError(f"쓸 만한 GPU 를 찾지 못했습니다:\n{text}")
    # 후보가 여럿이면 VRAM 이 가장 큰 것.
    cands.sort(key=lambda c: -c[2])
    return cands[0]


# ── 서버 수명 관리 ─────────────────────────────────────────────────────────
def start_server(backend, args):
    libdir = os.path.join(SCRIPT_DIR, BACKENDS[backend])
    binary = os.path.join(libdir, "llama-server")
    if not os.path.isfile(binary):
        raise RuntimeError(f"{binary} 가 없습니다. 해당 백엔드를 먼저 빌드하세요.")

    dev, desc, mib = pick_device(binary, libdir)
    log(f"  디바이스: {dev}  ({desc}, {mib} MiB)")

    logpath = os.path.join(SCRIPT_DIR, "logs", f"bench_server_{backend}.log")
    os.makedirs(os.path.dirname(logpath), exist_ok=True)
    logfile = open(logpath, "w")

    # ─ 백엔드 간 유일한 차이는 -dev 뿐이다. 나머지는 전부 동일하게 고정한다.
    #   특히 -c 와 -np: 둘 다 Vulkan 에서 성능 절벽을 만드는 변수라
    #   (보고서 §5.2/§5.4) 한쪽만 다르면 비교가 아니라 착시가 된다.
    cmd = [
        binary,
        "-m", args.model,
        "-dev", dev,
        "-ngl", "99",
        "-c", str(args.ctx),
        "-np", "1",
        "-fa", "on",
        "-ctk", args.kv, "-ctv", args.kv,
        "-b", "2048", "-ub", "512",
        "--host", "127.0.0.1", "--port", str(args.port),
        "--no-webui",
    ]
    log(f"  실행: {' '.join(cmd[1:])}")
    proc = subprocess.Popen(
        cmd,
        env=dict(os.environ, LD_LIBRARY_PATH=libdir),
        stdout=logfile,
        stderr=subprocess.STDOUT,
        start_new_session=True,   # 죽일 때 자식까지 한 번에
    )

    t0 = time.time()
    while time.time() - t0 < args.load_timeout:
        if proc.poll() is not None:
            logfile.flush()
            tail = "".join(open(logpath).readlines()[-25:])
            raise RuntimeError(f"서버가 죽었습니다 (exit {proc.returncode}):\n{tail}")
        try:
            if get(args.port, "/health").get("status") == "ok":
                log(f"  모델 로드 완료 ({time.time() - t0:.0f}s)")
                used = vram_used_mib()
                if used:
                    log(f"  VRAM 사용: {used} MiB / 32752 MiB")
                return proc, dev
        except (urllib.error.URLError, OSError, json.JSONDecodeError):
            pass
        time.sleep(2)
    stop_server(proc)
    raise RuntimeError(f"{args.load_timeout}s 안에 서버가 준비되지 않았습니다 → {logpath}")


def stop_server(proc):
    if proc.poll() is not None:
        return
    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        proc.wait(timeout=10)


# ── 측정 ───────────────────────────────────────────────────────────────────
def build_token_pool(port, need):
    """길이 need 이상의 토큰 목록을 만든다.

    /tokenize 로 실제 토큰 ID 를 받아온다. 임의의 정수를 넣으면 vocab 범위를
    벗어나거나 특수 토큰을 건드릴 수 있어서 그렇게 하지 않는다.
    """
    text = FILLER * (need // 10 + 64)
    toks = post(port, "/tokenize", {"content": text})["tokens"]
    while len(toks) < need:
        toks = toks + toks
    return toks


def measure_pp(port, tokens, n, offset):
    """프롬프트 n 토큰 처리 속도(t/s).

    n_predict=1 로 생성을 최소화하고, cache_prompt=false 와 offset 이동으로
    앞선 반복의 KV 를 재사용하지 못하게 막는다 (재사용되면 prompt_n 이 줄어
    말도 안 되게 빠른 값이 나온다 — 아래에서 실제로 검증한다).
    """
    r = post(
        port,
        "/completion",
        {
            "prompt": tokens[offset : offset + n],
            "n_predict": 1,
            "cache_prompt": False,
            "temperature": 0,
        },
    )
    t = r["timings"]
    return t["prompt_per_second"], int(t["prompt_n"])


def measure_tg(port, tokens, n, offset):
    """n 토큰 생성 속도(t/s). ignore_eos 로 EOS 조기 종료를 막는다."""
    r = post(
        port,
        "/completion",
        {
            "prompt": tokens[offset : offset + 8],
            "n_predict": n,
            "ignore_eos": True,
            "cache_prompt": False,
            "temperature": 0,
        },
    )
    t = r["timings"]
    return t["predicted_per_second"], int(t["predicted_n"])


def run_backend(backend, args):
    log("")
    log(f"══ {backend} ══")
    proc, dev = start_server(backend, args)
    results = {}
    try:
        need = max(args.pp) + args.reps * 512 + 64
        tokens = build_token_pool(args.port, need)

        # 워밍업 — 첫 요청은 셰이더 캐시/할당 때문에 항상 느리다. 버린다.
        log("  워밍업…")
        measure_pp(args.port, tokens, 256, 0)
        measure_tg(args.port, tokens, 16, 0)

        for n in args.pp:
            vals = []
            for i in range(args.reps):
                tps, got = measure_pp(args.port, tokens, n, 1 + i * 512)
                if got != n:
                    log(f"    ⚠️  pp{n}: 서버가 실제로 처리한 토큰은 {got}개 (캐시 재사용?)")
                vals.append(tps)
            results[f"pp{n}"] = vals
            log(f"  pp{n:<5} {fmt(vals)}")

        for n in args.tg:
            vals = []
            for i in range(args.reps):
                tps, got = measure_tg(args.port, tokens, n, 1 + i * 512)
                if got != n:
                    log(f"    ⚠️  tg{n}: 실제 생성 토큰 {got}개")
                vals.append(tps)
            results[f"tg{n}"] = vals
            log(f"  tg{n:<5} {fmt(vals)}")

        results["_device"] = f"{dev}"
        results["_vram_mib"] = vram_used_mib()
        results["_clocks"] = read_clocks()
    finally:
        stop_server(proc)
    return results


def fmt(vals):
    m = statistics.mean(vals)
    s = statistics.stdev(vals) if len(vals) > 1 else 0.0
    return f"{m:8.2f} ± {s:.2f} t/s"


# ── 출력 ───────────────────────────────────────────────────────────────────
def report(all_results, args):
    metrics = [f"pp{n}" for n in args.pp] + [f"tg{n}" for n in args.tg]
    backends = list(all_results)

    lines = []
    lines.append("")
    lines.append(f"모델    : {os.path.basename(args.model)}")
    lines.append(f"조건    : -ngl 99 -c {args.ctx} -np 1 -fa on -ctk {args.kv} -ctv {args.kv}, {args.reps}회 평균")
    lines.append("")
    head = "| 지표 | " + " | ".join(backends) + " |"
    lines.append(head)
    lines.append("|:---|" + "---:|" * len(backends))
    for met in metrics:
        row = [met]
        for b in backends:
            vals = all_results[b].get(met)
            row.append(fmt(vals).strip() if vals else "—")
        lines.append("| " + " | ".join(row) + " |")

    # 두 백엔드를 다 돌렸으면 비율까지 붙인다 — 이 벤치의 목적이 그 비교다.
    if len(backends) == 2:
        a, b = backends
        lines.append("")
        lines.append(f"| 지표 | {a} 대비 {b} |")
        lines.append("|:---|---:|")
        for met in metrics:
            va, vb = all_results[a].get(met), all_results[b].get(met)
            if va and vb:
                r = statistics.mean(vb) / statistics.mean(va)
                lines.append(f"| {met} | {r:.2f}배 |")

    text = "\n".join(lines)
    log(text)

    os.makedirs(os.path.join(SCRIPT_DIR, "logs"), exist_ok=True)
    stamp = time.strftime("%Y%m%d_%H%M%S")
    path = os.path.join(SCRIPT_DIR, "logs", f"bench_{stamp}.json")
    with open(path, "w") as f:
        json.dump(
            {
                "model": args.model,
                "ctx": args.ctx,
                "kv": args.kv,
                "reps": args.reps,
                "results": all_results,
            },
            f,
            indent=2,
        )
    log("")
    log(f"raw: logs/bench_{stamp}.json")


def main():
    p = argparse.ArgumentParser(description="ROCm vs Vulkan 추론 성능 비교")
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.add_argument("--backends", default="rocm,vulkan")
    p.add_argument("--pp", default="512,2048,4096", help="프롬프트 처리 토큰 수")
    p.add_argument("--tg", default="128,512", help="생성 토큰 수")
    p.add_argument("--ctx", type=int, default=8192,
                   help="할당 컨텍스트. 두 백엔드에 동일하게 적용된다(공정성 조건)")
    p.add_argument("--kv", default="f16", choices=["f16", "q8_0", "q4_0"])
    p.add_argument("--reps", type=int, default=3)
    p.add_argument("--port", type=int, default=8099)
    p.add_argument("--load-timeout", type=int, default=900)
    args = p.parse_args()

    args.pp = [int(x) for x in args.pp.split(",") if x]
    args.tg = [int(x) for x in args.tg.split(",") if x]
    args.backends = [b.strip() for b in args.backends.split(",") if b.strip()]

    if not os.path.isfile(args.model):
        sys.exit(f"모델이 없습니다: {args.model}")
    for b in args.backends:
        if b not in BACKENDS:
            sys.exit(f"알 수 없는 백엔드: {b} (가능: {', '.join(BACKENDS)})")

    # -c 는 pp 최대치 + tg 최대치를 담아야 한다. 모자라면 서버가 프롬프트를
    # 잘라내고, 그러면 "pp4096" 이라는 이름표만 남고 실제로는 다른 걸 재는 셈이 된다.
    need = max(args.pp) + max(args.tg) + 64
    if args.ctx < need:
        sys.exit(f"--ctx {args.ctx} 는 너무 작습니다 (pp/tg 최대치 기준 {need} 이상 필요)")

    check_clocks()

    all_results = {}
    for b in args.backends:
        try:
            all_results[b] = run_backend(b, args)
        except Exception as e:      # 한쪽이 실패해도 나머지 결과는 남긴다
            log(f"  ✗ {b} 실패: {e}")
    if all_results:
        report(all_results, args)


if __name__ == "__main__":
    main()
