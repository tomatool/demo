"""Gate a tomato coverage report and render it for a job summary.

    coverage.py <coverage.json> <coverage.md> <min-total-percent> <service> > summary.md

Fails when a step in the features matches no step definition (a typo tomato
would only report at run time), or when the share of the declared resources'
steps the suite uses drops below the service's floor.
"""

import json
import sys

report_path, markdown_path, floor, service = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
report = json.load(open(report_path))
total = 100.0 * report["covered"] / report["total"] if report["total"] else 0.0
unmatched = report.get("unmatched_steps") or []

problems = []
if unmatched:
    problems.append(f"{len(unmatched)} step(s) match no step definition:")
    problems += [f"  - `{s.get('text', s) if isinstance(s, dict) else s}`" for s in unmatched]
if total < floor:
    problems.append(f"total step coverage {total:.1f}% is below this service's floor of {floor:.1f}%")

status = "✅" if not problems else "❌"
print(f"### {status} Step coverage: {report['covered']}/{report['total']} ({total:.1f}%), floor {floor:.1f}%\n")
print("How much of each declared resource's step vocabulary the `" + service + "` suite exercises.\n")
print(open(markdown_path).read())
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
