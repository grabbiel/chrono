#!/usr/bin/env python3
"""Fail unless every listed XCTest ran, none failed, and every skip is expected.

Public CI has no ROM, ChronoRET checkout or IPL image, so tests that need them
skip. expected_skips.txt names each one; a skip not listed there, a listed
`skip` test that ran, a stale entry, or a listed test without a result fails.
"""
import argparse
from collections import Counter
from pathlib import Path
import re
import sys

RESULT = re.compile(r"Test Case '-\[(\S+)\.(\S+) (\S+)\]' (passed|failed|skipped)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="output of `swift test` (XCTest, not --parallel)")
    parser.add_argument("--list", type=Path, required=True, help="output of `swift test list`")
    parser.add_argument("--expected-skips", type=Path, required=True)
    parser.add_argument("--summary", type=Path, help="append a Markdown summary here")
    args = parser.parse_args()

    results = {}
    for module, cls, name, status in RESULT.findall(args.log.read_text()):
        test = f"{module}.{cls}/{name}"
        # A test reported twice keeps its worst outcome.
        if results.get(test) != "failed":
            results[test] = status
    lines = [line.strip() for line in args.list.read_text().splitlines() if line.strip()]
    listed = {line for line in lines if re.fullmatch(r"[A-Za-z_][\w.]*/[A-Za-z_]\w*", line)}
    # Only XCTest results are parsed; refuse anything else instead of ignoring it.
    unsupported = [line for line in lines if line not in listed]
    expected = {}
    for number, line in enumerate(args.expected_skips.read_text().splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        test, policy, *_ = line.split()
        if policy not in ("skip", "may-skip"):
            sys.exit(f"{args.expected_skips}:{number}: policy must be skip or may-skip")
        expected[test] = policy

    errors = [f"{line}: unsupported test id (only XCTest results are checked)" for line in unsupported]
    if not listed:
        errors.append("no tests listed")
    errors += [f"{t}: listed but produced no result" for t in sorted(listed - results.keys())]
    errors += [f"{t}: failed" for t, s in sorted(results.items()) if s == "failed"]
    errors += [f"{t}: skipped unexpectedly" for t, s in sorted(results.items())
               if s == "skipped" and t not in expected]
    errors += [f"{t}: expected to skip without local data, but ran" for t, p in sorted(expected.items())
               if p == "skip" and results.get(t) == "passed"]
    errors += [f"{t}: expected-skip entry names no listed test" for t in sorted(expected.keys() - listed)]

    counts = Counter(results.values())
    line = (f"{len(listed)} listed, {counts['passed']} passed, {counts['skipped']} skipped, "
            f"{counts['failed']} failed")
    for error in errors:
        print(f"ERROR {error}")
    print(("FAIL " if errors else "OK ") + line)
    if args.summary:
        with args.summary.open("a") as out:
            out.write(f"### Swift tests\n\n{line}.\n\n")
            if errors:
                out.write("".join(f"- {e}\n" for e in errors) + "\n")
            skipped = sorted(t for t, s in results.items() if s == "skipped")
            if skipped:
                out.write("<details><summary>Skipped (local ROM/reference data or hosted-runner limits)"
                          "</summary>\n\n" + "".join(f"- `{t}`\n" for t in skipped) + "\n</details>\n\n")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
