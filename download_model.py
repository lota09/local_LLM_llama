#!/usr/bin/env python3
"""Download model gguf and optional mmproj into models/<name>/

Usage: run and follow prompts. Saves model as <name>.gguf and projection as
<name>_mmproj*.gguf per rules described in the repo.
"""
import os
import sys
import urllib.request
import urllib.parse
import re


def prompt(msg):
    try:
        return input(msg).strip()
    except EOFError:
        return ""


def download(url, dest):
    print(f"Downloading:\n  {url}\n-> {dest}")
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "wget/1.21"})
        with urllib.request.urlopen(req) as r:
            total = r.getheader("Content-Length")
            total = int(total) if total and total.isdigit() else None
            with open(dest, "wb") as f:
                downloaded = 0
                chunk_size = 64 * 1024
                while True:
                    chunk = r.read(chunk_size)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)
                    if total:
                        pct = downloaded * 100 / total
                        print(f"  {downloaded}/{total} bytes ({pct:.1f}%)", end="\r")
        if total:
            print()
        print("Download finished.")
    except Exception as e:
        print(f"Download failed: {e}")
        if os.path.exists(dest):
            os.remove(dest)
        sys.exit(1)


def safe_filename_from_proj_url(basename, name):
    # try to capture mmproj plus optional suffix (e.g. mmproj-F16)
    m = re.search(r"(mmproj(?:-[^.]*)?)", basename, flags=re.IGNORECASE)
    if m:
        tag = m.group(1)
        # preserve case from match
        return f"{name}_{tag}.gguf"
    # fallback
    return f"{name}_mmproj.gguf"


def main():
    print("Create model directory name under models/ (example: gemma-4-26B-A4B-it-Claude-Opus-Distill_v2.q3_k_s)")
    model_dir_name = prompt("Model directory name: ")
    if not model_dir_name:
        print("Model directory name is required.")
        sys.exit(1)
    model_dir_name = os.path.basename(model_dir_name.rstrip("/"))

    model_url = prompt("Model GGUF URL: ")
    if not model_url:
        print("Model GGUF URL is required.")
        sys.exit(1)

    proj_url = prompt("Projection GGUF URL (leave empty if none): ")

    target_dir = os.path.join("models", model_dir_name)
    os.makedirs(target_dir, exist_ok=True)

    model_dest = os.path.join(target_dir, f"{model_dir_name}.gguf")
    if os.path.exists(model_dest):
        over = prompt(f"{model_dest} exists. Overwrite? (y/N): ") or "N"
        if not over.lower().startswith("y"):
            print("Aborting (model file exists).")
            sys.exit(1)

    download(model_url, model_dest)

    if proj_url:
        parsed = urllib.parse.urlparse(proj_url)
        base = os.path.basename(parsed.path)
        proj_filename = safe_filename_from_proj_url(base, model_dir_name)
        proj_dest = os.path.join(target_dir, proj_filename)
        if os.path.exists(proj_dest):
            over = prompt(f"{proj_dest} exists. Overwrite? (y/N): ") or "N"
            if not over.lower().startswith("y"):
                print("Skipping projection download (file exists).")
                return
        download(proj_url, proj_dest)
    else:
        print("No projection URL provided; skipping projection download.")

    print(f"Saved files under {target_dir}:")
    for fn in os.listdir(target_dir):
        print(" - ", fn)


if __name__ == "__main__":
    main()
