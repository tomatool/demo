"""Report how much of a service's code its black-box run exercised.

    code_coverage.py <format> <report> <service-dir> <floor-percent> [exclude-regex] > code-coverage.md

<format> is what the language's tool wrote:

    lcov    lcov tracefile (Node c8, coverage.py, llvm-cov)
    go      Go cover profile (go tool covdata textfmt)
    jacoco  JaCoCo XML report

Every format is reduced to lines (statements, for Go) per source file. Fails
when the total is below the service's floor.
"""

from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

fmt, report, service, floor = sys.argv[1], sys.argv[2], sys.argv[3].rstrip("/"), float(sys.argv[4])
exclude = re.compile(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] else None

# file -> [covered, total]
files: dict[str, list[int]] = defaultdict(lambda: [0, 0])


def add(path: str, covered: int, total: int) -> None:
    files[path][0] += covered
    files[path][1] += total


def lines(path: str) -> list[str]:
    try:
        return open(path).read().splitlines()
    except OSError:
        return []


if fmt == "lcov":
    path = None
    for line in lines(report):
        line = line.strip()
        if line.startswith("SF:"):
            path = line[3:]
        elif line.startswith("LH:") and path:
            add(path, int(line[3:]), 0)
        elif line.startswith("LF:") and path:
            add(path, 0, int(line[3:]))
elif fmt == "go":
    # file:start.col,end.col statements count; a block can appear once per
    # process that ran, so count each block once, covered if any run hit it.
    blocks: dict[tuple[str, str], tuple[int, bool]] = {}
    for line in lines(report):
        if line.startswith("mode:") or not line.strip():
            continue
        location, statements, count = line.rsplit(" ", 2)
        path, span = location.rsplit(":", 1)
        seen = blocks.get((path, span), (int(statements), False))
        blocks[(path, span)] = (int(statements), seen[1] or int(count) > 0)
    for (path, _), (statements, hit) in blocks.items():
        add(path, statements if hit else 0, statements)
elif fmt == "jacoco":
    try:
        root = ET.parse(report).getroot()
    except (OSError, ET.ParseError):
        root = ET.Element("report")
    for package in root.iter("package"):
        for source in package.iter("sourcefile"):
            for counter in source.findall("counter"):
                if counter.get("type") == "LINE":
                    covered, missed = int(counter.get("covered")), int(counter.get("missed"))
                    add(f"{package.get('name')}/{source.get('name')}", covered, covered + missed)
else:
    sys.exit(f"unknown format {fmt}")


def display(path: str) -> str:
    # Show paths from the service's directory, whatever the tool recorded.
    marker = service.split("/")[-1] + "/"
    return path.rsplit(marker, 1)[1] if marker in path else path


rows = sorted((display(p), c, t) for p, (c, t) in files.items()
              if t > 0 and not (exclude and exclude.search(p)))
covered = sum(c for _, c, _ in rows)
total = sum(t for _, _, t in rows)
percent = 100.0 * covered / total if total else 0.0
unit = "statements" if fmt == "go" else "lines"
ok = total > 0 and percent >= floor

print(f"### {'✅' if ok else '❌'} Code coverage of the black-box run: "
      f"{percent:.1f}% of {unit} ({covered}/{total}), floor {floor:.1f}%\n")
print(f"The {unit} of `{service}`'s own code that ran while tomato tested the built artifact.\n")
print("<details><summary>By file</summary>\n")
print(f"| File | {unit.capitalize()} covered | Coverage |\n|---|---|---|")
for path, c, t in rows:
    print(f"| `{path}` | {c} / {t} | {100.0 * c / t:.1f}% |")
print("\n</details>")
if not total:
    print("\nNo coverage data: did the service exit cleanly when tomato stopped it?")
sys.exit(0 if ok else 1)
