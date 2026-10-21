#!/usr/bin/env python3
"""Fail unless every collected pytest test passed or skipped for an expected reason.

Public CI has no ROM, ChronoRET checkout, manifests or extracted assets, so the
research tests that need them skip. expected_pytest_skips.tsv names each one
with its exact reason; a failure or error, a skip that is not listed or has a
different reason, a listed test that ran, or a stale entry fails.
"""
import argparse
from collections import Counter
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


def node_id(case):
    # JUnit classname is the dotted module path (re_workspace.tests.test_x).
    return case.get("classname").replace(".", "/") + ".py::" + case.get("name")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("junit", type=Path, help="pytest --junitxml output")
    parser.add_argument("--expected-skips", type=Path, required=True)
    parser.add_argument("--summary", type=Path, help="append a Markdown summary here")
    args = parser.parse_args()

    results = {}
    reasons = {}
    for case in ET.parse(args.junit).iter("testcase"):
        test = node_id(case)
        if case.find("failure") is not None or case.find("error") is not None:
            results[test] = "failed"
        elif (skipped := case.find("skipped")) is not None:
            results.setdefault(test, "skipped")
            reasons[test] = skipped.get("message", "")
        else:
            results.setdefault(test, "passed")
    expected = {}
    for number, line in enumerate(args.expected_skips.read_text().splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        test, sep, reason = line.partition("\t")
        if not sep or not reason.strip():
            sys.exit(f"{args.expected_skips}:{number}: expected <node id><TAB><reason>")
        expected[test] = reason.strip()

    errors = [] if results else ["no tests collected"]
    errors += [f"{t}: failed or errored" for t, s in sorted(results.items()) if s == "failed"]
    errors += [f"{t}: skipped unexpectedly ({reasons[t]})" for t, s in sorted(results.items())
               if s == "skipped" and t not in expected]
    errors += [f"{t}: skipped with {reasons[t]!r}, expected {expected[t]!r}" for t, s in sorted(results.items())
               if s == "skipped" and t in expected and reasons[t] != expected[t]]
    errors += [f"{t}: expected to skip without local data, but ran" for t, s in sorted(results.items())
               if s == "passed" and t in expected]
    errors += [f"{t}: expected-skip entry names no collected test" for t in sorted(expected.keys() - results.keys())]

    counts = Counter(results.values())
    line = (f"{len(results)} collected, {counts['passed']} passed, {counts['skipped']} skipped, "
            f"{counts['failed']} failed")
    for error in errors:
        print(f"ERROR {error}")
    print(("FAIL " if errors else "OK ") + line)
    if args.summary:
        with args.summary.open("a") as out:
            out.write(f"### Python research suites\n\n{line}.\n\n")
            if errors:
                out.write("".join(f"- {e}\n" for e in errors) + "\n")
            by_reason = Counter(reasons[t] for t, s in results.items() if s == "skipped")
            if by_reason:
                out.write("<details><summary>Skipped (local ROM, ChronoRET, manifests or assets)"
                          "</summary>\n\n" + "".join(f"- {n} × {r}\n" for r, n in by_reason.most_common())
                          + "\n</details>\n\n")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
