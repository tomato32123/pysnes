"""Find tests that cannot fail.

A test that runs the emulator, prints what it saw and never judges it is
indistinguishable from one that works: it is green on a broken build and
green on a correct one, and it makes the suite's count larger without making
it stronger.  This session found that shape three times outside the tests --
a library sweep read by eye, an audio check whose reference had never been
built, an APK check that counted modules instead of comparing them -- so the
tests themselves are worth the same question.

A test judges if it calls something that records a failure or raises.  The
helpers are found rather than listed, by looking for functions in tests/
whose body appends to FAILURES or raises: the first version of this had the
list hard-coded, did not know about `check_near`, and reported four false
positives in the one file that used it.  An auditor that does not know its
subject invents faults and misses real ones.

    python tools/weaktests.py
"""
import ast
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NL = chr(10)


def judging_helpers(paths):
    """Every function in the suite that can record a failure."""
    found = set()
    for path in paths:
        src = open(path).read()
        for m in re.finditer(r"def (\w+)\([^)]*\):((?:" + NL + r"(?:    .*)?)+)", src):
            body = m.group(2)
            if "FAILURES.append" in body or "raise " in body:
                found.add(m.group(1))
    return found


def main():
    paths = sorted(glob.glob(os.path.join(ROOT, "tests", "*.py")))
    if not paths:
        print("no test files found -- nothing was checked")
        return 77
    helpers = judging_helpers(paths)
    weak, total = [], 0
    for path in paths:
        tree = ast.parse(open(path).read())
        for node in ast.walk(tree):
            if not (isinstance(node, ast.FunctionDef)
                    and node.name.startswith("test_")):
                continue
            total += 1
            called = {n.func.id for n in ast.walk(node)
                      if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
            dumped = ast.dump(node)
            if not (called & helpers) and "Assert" not in dumped \
                    and "FAILURES" not in dumped:
                weak.append("%s: %s" % (os.path.basename(path), node.name))
    for w in weak:
        print("  cannot fail: %s" % w)
    print("%d test functions, %d of which cannot fail" % (total, len(weak)))
    return 1 if weak else 0


if __name__ == "__main__":
    sys.exit(main())
