#!/usr/bin/env python3
"""아티팩트 HTML → 마크다운.  사용: h2md.py <in.html> <out.md> "<제목>" "<원본 URL>"

이 두 문서만을 위한 변환기다. 범용이 아니라, 여기서 실제로 쓰는 태그만 다룬다:
  h1/h2/h3 · p · strong/b · em · code · table(caption/thead/tbody) · ul/ol/li
  dl.terms · figure(svg 버림, figcaption 만) · div.key/.note(인용구로) · a
그래프(인라인 SVG)는 마크다운에서 살릴 방법이 없으므로 캡션만 남기고 버린다.
"""
import html, re, sys, io
from html.parser import HTMLParser

SKIP_TAGS = {"style", "script", "svg", "nav", "title"}


class MD(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []          # 완성된 블록
        self.buf = []          # 현재 인라인 버퍼
        self.skip = 0
        self.stack = []
        self.tbl = None        # 표 수집 상태
        self.row = None
        self.cell = None
        self.list_stack = []
        self.in_fig = False
        self.dl = None

    # ── 도우미 ──
    def flush(self, prefix="", suffix=""):
        t = re.sub(r"\s+", " ", "".join(self.buf)).strip()
        self.buf = []
        if t:
            self.out.append(prefix + t + suffix)
        return t

    def emit(self, s):
        self.out.append(s)

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = a.get("class", "")
        if tag in SKIP_TAGS:
            self.skip += 1
            return
        if self.skip:
            return

        if tag in ("h1", "h2", "h3"):
            self.flush()
            self.stack.append(tag)
        elif tag == "p":
            self.flush()
        elif tag in ("strong", "b"):
            self.buf.append("**")
        elif tag in ("em", "i"):
            self.buf.append("*")
        elif tag == "code":
            self.buf.append("`")
        elif tag == "br":
            self.buf.append(" " if self.tbl is not None else "<<BR>>")
        elif tag == "a":
            self.buf.append("[")
            self.stack.append(("a", a.get("href", "")))
        elif tag == "table":
            self.flush(); self.tbl = {"caption": "", "rows": [], "head": 0}
        elif tag == "caption":
            self.cell = []
        elif tag == "tr":
            self.row = []
        elif tag in ("td", "th"):
            self.cell = []
            self.buf = []
            if tag == "th" and self.tbl is not None and not self.tbl["rows"]:
                pass
        elif tag == "thead":
            self.stack.append("thead")
        elif tag in ("ul", "ol"):
            self.flush(); self.list_stack.append(tag)
        elif tag == "li":
            self.flush(); self.buf = []
        elif tag == "figure":
            self.flush(); self.in_fig = True
        elif tag == "figcaption":
            self.buf = []
        elif tag == "dl":
            self.flush(); self.dl = []
        elif tag in ("dt", "dd"):
            self.buf = []
        elif tag == "span":
            if "unit" in cls:
                self.buf.append(" ")
            elif cls.strip() == "k":
                self.buf.append(" — ")
            elif "tag" in cls:
                self.buf.append("")
        elif tag == "div":
            if "fig-cell" in cls:
                self.flush(); self.stack.append("figcell"); return
            self.flush()
            if "key" in cls or "note" in cls:
                self.stack.append("quote")
                self.emit("<<QUOTE_START>>")

    def handle_endtag(self, tag):
        if tag in SKIP_TAGS:
            self.skip = max(0, self.skip - 1)
            return
        if self.skip:
            return

        if tag in ("h1", "h2", "h3"):
            lvl = {"h1": "# ", "h2": "## ", "h3": "### "}[tag]
            t = "".join(self.buf).strip()
            self.buf = []
            t = re.sub(r"^\s*(\d+)\s+", r"\1. ", t)      # 절 번호 뒤 공백 정리
            if t:
                self.emit("\n" + lvl + t + "\n")
            if self.stack and self.stack[-1] == tag:
                self.stack.pop()
        elif tag == "p":
            self.flush()
        elif tag in ("strong", "b"):
            self.buf.append("**")
        elif tag in ("em", "i"):
            self.buf.append("*")
        elif tag == "code":
            self.buf.append("`")
        elif tag == "a":
            href = ""
            if self.stack and isinstance(self.stack[-1], tuple):
                href = self.stack.pop()[1]
            if href.startswith("#"):
                # 문서 내 앵커는 마크다운에서 살지 않는다 — 평문으로 남긴다
                txt = "".join(self.buf)
                i = txt.rfind("[")
                self.buf = [txt[:i] + txt[i+1:]] if i >= 0 else [txt]
            else:
                self.buf.append(f"]({href})")
        elif tag == "caption":
            self.tbl["caption"] = "".join(self.buf).strip(); self.buf = []
        elif tag in ("td", "th"):
            v = re.sub(r"\s+", " ", "".join(self.buf)).strip()
            self.buf = []
            if self.row is not None:
                self.row.append(v)
        elif tag == "tr":
            if self.tbl is not None and self.row:
                self.tbl["rows"].append(self.row)
            self.row = None
        elif tag == "thead":
            if self.tbl is not None:
                self.tbl["head"] = len(self.tbl["rows"])
            if self.stack and self.stack[-1] == "thead":
                self.stack.pop()
        elif tag == "table":
            self.emit_table(); self.tbl = None
        elif tag in ("ul", "ol"):
            if self.list_stack:
                self.list_stack.pop()
            self.emit("")
        elif tag == "li":
            t = re.sub(r"\s+", " ", "".join(self.buf)).strip()
            self.buf = []
            if t:
                t = re.sub(r"^[·•]\s*", "", t)
                mark = "- " if (self.list_stack and self.list_stack[-1] == "ul") else "1. "
                self.emit(mark + t)
        elif tag == "figcaption":
            t = re.sub(r"\s+", " ", "".join(self.buf)).strip()
            self.buf = []
            if t:
                self.emit(f"> **[그림 — 원문 HTML 참조]** {t}\n")
        elif tag == "figure":
            self.in_fig = False
        elif tag == "dt":
            self.dl.append(["".join(self.buf).strip(), ""]); self.buf = []
        elif tag == "dd":
            if self.dl:
                self.dl[-1][1] = re.sub(r"\s+", " ", "".join(self.buf)).strip()
            self.buf = []
        elif tag == "dl":
            if self.dl:
                self.emit("| 용어 | 뜻 |")
                self.emit("|:--|:--|")
                for k, v in self.dl:
                    self.emit(f"| **{k}** | {v} |")
                self.emit("")
            self.dl = None
        elif tag == "div":
            if self.stack and self.stack[-1] == "figcell":
                self.stack.pop()
                t = re.sub(r"\s+", " ", "".join(self.buf)).strip()
                self.buf = []
                if t:
                    self.emit("- " + t)
                return
            self.flush()
            if self.stack and self.stack[-1] == "quote":
                self.stack.pop(); self.emit("<<QUOTE_END>>")

    def handle_data(self, d):
        if self.skip or self.tbl is not None and self.row is None and self.cell is None and not d.strip():
            return
        if self.skip:
            return
        self.buf.append(d)

    def emit_table(self):
        t = self.tbl
        if not t or not t["rows"]:
            return
        if t["caption"]:
            self.emit(f"\n**{t['caption']}**\n")
        rows = t["rows"]
        nh = t["head"] or 1
        head = rows[0]
        w = max(len(r) for r in rows)
        def pad(r): return r + [""] * (w - len(r))
        self.emit("| " + " | ".join(pad(head)) + " |")
        self.emit("|" + "|".join(["---"] * w) + "|")
        for r in rows[nh:]:
            self.emit("| " + " | ".join(x.replace("|", "\\|") for x in pad(r)) + " |")
        self.emit("")


def convert(src, title, url):
    body = src[src.index("<title>"):]
    p = MD()
    p.feed(body)
    p.flush()
    txt = "\n".join(p.out)
    # 인용구 블록 처리
    out, q = [], False
    for line in txt.split("\n"):
        if line.strip() == "<<QUOTE_START>>":
            q = True; continue
        if line.strip() == "<<QUOTE_END>>":
            q = False; out.append(""); continue
        out.append(("> " + line) if (q and line.strip()) else line)
    txt = "\n".join(out)
    txt = txt.replace("<<BR>>", "  \n")
    txt = re.sub(r"\n{3,}", "\n\n", txt)
    txt = re.sub(r"^#\s*" + re.escape(title) + r"\s*$", "", txt, flags=re.M)
    hdr = (f"# {title}\n\n> 원본(그래프·서식 포함): {url}\n>\n"
           f"> 이 마크다운은 아카이브용 변환본이다. **인라인 SVG 그래프는 빠져 있고** 캡션만 남았다.\n")
    return hdr + txt.strip() + "\n"


if __name__ == "__main__":
    src = io.open(sys.argv[1], encoding="utf-8").read()
    io.open(sys.argv[2], "w", encoding="utf-8").write(convert(src, sys.argv[3], sys.argv[4]))
    print(f"{sys.argv[2]} 생성")
