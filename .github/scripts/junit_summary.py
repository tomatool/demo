"""Summarise a tomato JUnit report as markdown.

    junit_summary.py <junit.xml> > results.md
"""

import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
except (OSError, ET.ParseError) as err:
    print(f"### ❌ No test report\n\ntomato did not write `{sys.argv[1]}`: {err}")
    sys.exit(0)

suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
rows, passed, failed, skipped, seconds = [], 0, 0, 0, 0.0
for suite in suites:
    for case in suite.findall("testcase"):
        seconds += float(case.get("time", 0) or 0)
        failure = case.find("failure")
        if failure is None:
            failure = case.find("error")
        if failure is not None:
            failed += 1
            message = (failure.get("message") or failure.text or "").strip().splitlines()
            rows.append(f"| ❌ | {suite.get('name')} | {case.get('name')} | {message[0] if message else ''} |")
        elif case.find("skipped") is not None:
            skipped += 1
            rows.append(f"| ⏭️ | {suite.get('name')} | {case.get('name')} | |")
        else:
            passed += 1
            rows.append(f"| ✅ | {suite.get('name')} | {case.get('name')} | |")

total = passed + failed + skipped
status = "✅" if failed == 0 and total > 0 else "❌"
print(f"### {status} Black-box tests: {passed}/{total} scenarios passed"
      + (f", {failed} failed" if failed else "") + (f", {skipped} skipped" if skipped else "")
      + f" in {seconds:.1f}s\n")
print("<details><summary>Scenarios</summary>\n")
print("| | Feature | Scenario | Failure |\n|---|---|---|---|")
print("\n".join(rows))
print("\n</details>")
