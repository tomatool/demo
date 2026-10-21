"""Build the demo's test report page.

    report.py <data-dir> <out-dir>

<data-dir>/<workflow>/meta.json is `gh run list --json` for that workflow's
latest run on main, and the run's artifacts are downloaded next to it. The
page shows the shop's architecture with every service tinted by the code
coverage of its black-box run, the end-to-end result over the connections it
exercises, and which commit and tomato version each run used.
"""

from __future__ import annotations

import html
import json
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

data, out = Path(sys.argv[1]), Path(sys.argv[2])
REPO = "tomatool/demo"

SERVICES = [
    ("gateway", "Node.js"),
    ("orders", "Go"),
    ("catalog", "Rust"),
    ("payments", "Kotlin"),
    ("notifications", "Python"),
]


def find(root: Path, name: str) -> Path | None:
    hits = sorted(root.rglob(name)) if root.exists() else []
    return hits[0] if hits else None


def load(workflow: str) -> dict:
    root = data / workflow
    info = {"workflow": workflow}
    try:
        meta = json.loads((root / "meta.json").read_text())[0]
    except (OSError, ValueError, IndexError):
        return info
    info.update(sha=meta["headSha"], run=meta["databaseId"], conclusion=meta["conclusion"],
                at=meta["createdAt"], message=meta.get("displayTitle", ""))

    if (f := find(root, "code-coverage.md")):
        m = re.search(r"([\d.]+)% of (lines|statements) \((\d+)/(\d+)\)", f.read_text())
        if m:
            info["code"] = float(m.group(1))
            info["unit"] = m.group(2)
    if (f := find(root, "coverage.json")):
        c = json.loads(f.read_text())
        if c.get("total"):
            info["steps"] = 100.0 * c["covered"] / c["total"]
    if (f := find(root, "junit.xml")):
        try:
            r = ET.parse(f).getroot()
            cases = list(r.iter("testcase"))
            failed = [c for c in cases if c.find("failure") is not None or c.find("error") is not None]
            info["scenarios"] = (len(cases) - len(failed), len(cases))
            info["cases"] = [(c.get("name"), c not in failed) for c in cases]
        except ET.ParseError:
            pass
    if (f := find(root, "tomato-version.txt")):
        info["tomato"] = f.read_text().strip()
    return info


runs = {w: load(w) for w, _ in SERVICES}
e2e = load("e2e")


def hue(pct: float | None) -> str:
    """Red below 50%, green at 100%, through the tomato palette's hues."""
    if pct is None:
        return "var(--fg-3)"
    h = 30 + max(0.0, min(1.0, (pct - 50) / 50)) * 118
    return f"oklch(0.74 0.15 {h:.0f})"


def esc(s: object) -> str:
    return html.escape(str(s))


# ─── the diagram ────────────────────────────────────────────────────────────

BOXES = {
    "gateway": (170, 185), "catalog": (400, 40), "orders": (400, 185),
    "payments": (630, 185), "notifications": (630, 330),
}
W, H = 170, 80


def service_node(name: str, lang: str) -> str:
    r = runs[name]
    x, y = BOXES[name]
    color = hue(r.get("code"))
    pct = f'{r["code"]:.0f}%' if "code" in r else "—"
    sc = r.get("scenarios")
    sc_txt = f"{sc[0]}/{sc[1]} scenarios" if sc else "no run"
    ok = r.get("conclusion") == "success"
    return f'''
  <a href="https://github.com/{REPO}/actions/runs/{r.get("run", "")}">
  <g class="svc">
    <rect x="{x}" y="{y}" width="{W}" height="{H}" rx="10" style="stroke:{color};fill:color-mix(in oklch, {color} 16%, var(--bg-1))"/>
    <text class="n" x="{x+14}" y="{y+24}">{esc(name)}</text>
    <text class="l" x="{x+14}" y="{y+41}">{esc(lang)}</text>
    <text class="p" x="{x+W-14}" y="{y+46}" text-anchor="end" style="fill:{color}">{pct}</text>
    <text class="s" x="{x+14}" y="{y+66}">{"✓" if ok else "✗"} {sc_txt}</text>
  </g></a>'''


def pill(x: int, y: int, text: str, cls: str = "infra") -> str:
    w = 12 + 7 * len(text)
    return f'<g class="{cls}"><rect x="{x}" y="{y}" width="{w}" height="22" rx="11"/><text x="{x + w/2}" y="{y+15}" text-anchor="middle">{esc(text)}</text></g>'


def edge(d: str, label: str, lx: int, ly: int) -> str:
    return f'<path class="edge" d="{d}" marker-end="url(#a)"/><text class="el" x="{lx}" y="{ly}">{esc(label)}</text>'


e2e_ok = e2e.get("conclusion") == "success"
e2e_sc = e2e.get("scenarios")
edges = "".join([
    edge("M130 225 H170", "HTTP", 134, 216),
    edge("M340 205 L400 95", "gRPC", 344, 150),
    edge("M340 225 H400", "HTTP", 352, 216),
    edge("M485 185 V120", "gRPC", 491, 158),
    edge("M570 210 H630", "Kafka", 580, 201),
    edge("M630 245 H570", "RabbitMQ", 572, 262),
    edge("M715 265 V330", "RabbitMQ", 721, 302),
    edge("M800 225 H850", "HTTPS", 806, 216),
    edge("M800 352 L850 337", "", 0, 0),
    edge("M800 382 L850 395", "", 0, 0),
])
svg = f'''<svg viewBox="0 0 980 470" role="img" aria-label="The shop's services, tinted by the code coverage of their black-box runs, and the connections the end-to-end suite exercises">
  <defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0 10 5 0 10z" class="ah"/></marker></defs>
  <g class="e2e {"ok" if e2e_ok else "bad"}">{edges}</g>
  <g class="who"><rect x="20" y="195" width="110" height="60" rx="30"/><text x="75" y="221" text-anchor="middle">shopper</text>
    <text class="sub" x="75" y="239" text-anchor="middle">e2e {f"{e2e_sc[0]}/{e2e_sc[1]}" if e2e_sc else "—"} {"✓" if e2e_ok else "✗"}</text></g>
  {"".join(service_node(n, l) for n, l in SERVICES)}
  {pill(580, 69, "Postgres")}{pill(430, 273, "Postgres")}{pill(650, 418, "Postgres · S3")}
  {pill(850, 214, "Stripe", "ext")}{pill(850, 326, "SendGrid", "ext")}{pill(850, 384, "Slack", "ext")}
</svg>'''


# ─── the table ──────────────────────────────────────────────────────────────

def bar(pct: float | None) -> str:
    if pct is None:
        return '<span class="muted">—</span>'
    return f'<span class="bar"><i style="width:{pct:.0f}%;background:{hue(pct)}"></i></span> {pct:.1f}%'


rows = []
for name, lang in SERVICES + [("e2e", "all five")]:
    r = e2e if name == "e2e" else runs[name]
    sc = r.get("scenarios")
    sha = r.get("sha", "")
    rows.append(f'''<tr>
  <td><strong>{esc(name)}</strong> <span class="muted">{esc(lang)}</span></td>
  <td>{bar(r.get("code")) if name != "e2e" else '<span class="muted">per service</span>'}</td>
  <td class="{"ok" if r.get("conclusion") == "success" else "bad"}">{f"{sc[0]}/{sc[1]}" if sc else "—"}</td>
  <td>{f'{r["steps"]:.0f}%' if "steps" in r else "—"}</td>
  <td><a href="https://github.com/{REPO}/commit/{sha}"><code>{sha[:7]}</code></a> · <a href="https://github.com/{REPO}/actions/runs/{r.get("run", "")}">run</a></td>
</tr>''')

all_runs = list(runs.values()) + [e2e]
versions = sorted({r["tomato"] for r in all_runs if r.get("tomato")})
latest = max((r for r in all_runs if r.get("at")), key=lambda r: r["at"], default={})
head = latest.get("sha", "")
green = all(r.get("conclusion") == "success" for r in all_runs)
e2e_cases = "".join(f'<li class="{"ok" if ok else "bad"}">{"✓" if ok else "✗"} {esc(n)}</li>' for n, ok in e2e.get("cases", []))

page = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>tomato demo · test report</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Cpath d='M12.2 10.2V6.8a3.2 3.2 0 0 1 3.2-3.2h1.2a3.2 3.2 0 0 1 3.2 3.2v3.4z' fill='%2366cb79'/%3E%3Ccircle cx='16' cy='19.6' r='11.2' fill='%23f75f4c'/%3E%3C/svg%3E">
<style>
:root {{ color-scheme: dark; --bg-0: oklch(0.155 0.006 40); --bg-1: oklch(0.185 0.007 40); --bg-2: oklch(0.215 0.008 40);
  --line: oklch(0.285 0.009 40); --line-strong: oklch(0.37 0.01 40); --fg-0: oklch(0.95 0.006 70); --fg-1: oklch(0.82 0.008 70);
  --fg-2: oklch(0.64 0.01 70); --fg-3: oklch(0.48 0.01 70); --pass: oklch(0.76 0.15 148); --fail: oklch(0.68 0.19 30); }}
@media (prefers-color-scheme: light) {{ :root {{ color-scheme: light; --bg-0: oklch(0.97 0.003 70); --bg-1: oklch(0.995 0.001 70);
  --bg-2: oklch(0.953 0.004 70); --line: oklch(0.89 0.005 70); --line-strong: oklch(0.8 0.007 70); --fg-0: oklch(0.255 0.008 70);
  --fg-1: oklch(0.38 0.009 70); --fg-2: oklch(0.545 0.01 70); --fg-3: oklch(0.66 0.01 70); --pass: oklch(0.545 0.135 148); --fail: oklch(0.545 0.18 30); }} }}
* {{ box-sizing: border-box; }}
body {{ margin: 0; background: var(--bg-0); color: var(--fg-1); font: 15px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif; }}
main {{ max-width: 1000px; margin: 0 auto; padding: 28px 16px 40px; }}
a {{ color: var(--fail); text-decoration: none; }} a:hover {{ text-decoration: underline; }}
code, .mono {{ font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.92em; }}
h1 {{ margin: 0; font-size: 24px; color: var(--fg-0); letter-spacing: -0.01em; }}
.meta {{ display: flex; flex-wrap: wrap; gap: 8px 16px; margin: 10px 0 20px; color: var(--fg-2); font-size: 14px; }}
.chip {{ font: 600 12.5px ui-monospace, Menlo, monospace; padding: 2px 10px; border-radius: 999px; }}
.chip.ok {{ color: var(--pass); background: color-mix(in oklch, var(--pass) 14%, transparent); }}
.chip.bad {{ color: var(--fail); background: color-mix(in oklch, var(--fail) 14%, transparent); }}
.card {{ border: 1px solid var(--line); border-radius: 12px; background: var(--bg-1); padding: 14px; }}
svg {{ display: block; width: 100%; height: auto; font-family: ui-monospace, Menlo, monospace; }}
.svc rect {{ stroke-width: 2; }} .svc .n {{ fill: var(--fg-0); font-size: 14px; font-weight: 700; }}
.svc .l {{ fill: var(--fg-3); font-size: 11.5px; }} .svc .p {{ font-size: 20px; font-weight: 700; }} .svc .s {{ fill: var(--fg-2); font-size: 11.5px; }}
.who rect {{ fill: var(--bg-2); stroke: var(--line-strong); }} .who text {{ fill: var(--fg-0); font-size: 13px; font-weight: 700; }}
.who .sub {{ fill: var(--fg-2); font-size: 11px; font-weight: 400; }}
.infra rect {{ fill: var(--bg-2); stroke: var(--line-strong); }} .infra text, .ext text {{ fill: var(--fg-2); font-size: 11px; }}
.ext rect {{ fill: none; stroke: var(--line-strong); stroke-dasharray: 4 3; }}
.edge {{ fill: none; stroke-width: 1.8; }} .el {{ fill: var(--fg-3); font-size: 10.5px; }}
.e2e.ok .edge {{ stroke: color-mix(in oklch, var(--pass) 70%, var(--line-strong)); }} .e2e.bad .edge {{ stroke: var(--fail); }}
.ah {{ fill: var(--line-strong); }}
.legend {{ display: flex; flex-wrap: wrap; gap: 14px; margin-top: 8px; font-size: 12.5px; color: var(--fg-2); }}
.grad {{ display: inline-block; width: 120px; height: 8px; border-radius: 4px; vertical-align: middle;
  background: linear-gradient(90deg, oklch(0.74 0.15 30), oklch(0.74 0.15 89), oklch(0.74 0.15 148)); }}
table {{ width: 100%; border-collapse: collapse; margin-top: 18px; font-size: 14px; }}
th, td {{ text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line); white-space: nowrap; }}
th {{ color: var(--fg-2); font-weight: 600; font-size: 12.5px; }}
.bar {{ display: inline-block; width: 90px; height: 7px; border-radius: 4px; background: var(--bg-2); vertical-align: middle; overflow: hidden; }}
.bar i {{ display: block; height: 100%; }}
.ok {{ color: var(--pass); }} .bad {{ color: var(--fail); }} .muted {{ color: var(--fg-3); }}
.table {{ overflow-x: auto; }}
ul.cases {{ list-style: none; padding: 0; margin: 14px 0 0; font-size: 14px; columns: 2; }}
footer {{ margin-top: 24px; font-size: 12.5px; color: var(--fg-3); }}
@media (max-width: 640px) {{ ul.cases {{ columns: 1; }} }}
</style></head><body><main>
<h1>🍅 tomato demo · test report</h1>
<div class="meta">
  <span class="chip {"ok" if green else "bad"}">{"all green" if green else "failing"}</span>
  <span>commit <a href="https://github.com/{REPO}/commit/{head}"><code>{head[:7]}</code></a> {esc(latest.get("message", ""))}</span>
  <span>tomato <code>{esc(", ".join(versions) or "unknown")}</code></span>
  <span>{esc(latest.get("at", "")[:16].replace("T", " "))} UTC</span>
</div>
<div class="card">
  {svg}
  <div class="legend"><span>code coverage of each service's black-box run</span><span>50% <span class="grad"></span> 100%</span>
    <span>edges: what the e2e suite ran through</span><span>dashed: third parties, stubbed</span></div>
</div>
<div class="table"><table>
<tr><th>Component</th><th>Code coverage</th><th>Scenarios</th><th>Step coverage</th><th>Tested at</th></tr>
{"".join(rows)}
</table></div>
<ul class="cases">{e2e_cases}</ul>
<footer>Each service runs on its own pipeline and only when it changes, so a row can be from an earlier commit than the header.
  Generated {datetime.now(timezone.utc):%Y-%m-%d %H:%M} UTC from <a href="https://github.com/{REPO}">{REPO}</a>.</footer>
</main></body></html>'''

out.mkdir(parents=True, exist_ok=True)
(out / "index.html").write_text(page)
print(f"report: {head[:7]} tomato {versions} green={green}")
