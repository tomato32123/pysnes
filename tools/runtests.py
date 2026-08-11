"""Run every test module and report a single pass/fail, for CI."""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULES = ["test_cpu", "test_timing", "test_openbus", "test_ppu", "test_dsp",
           "test_cart", "test_state", "test_rewind"]


NO_ROM = 77          # tools/romarg.py's "there is no ROM here" exit code


def main():
    failed = []
    skipped = []
    for name in MODULES:
        path = os.path.join(ROOT, "tests", name + ".py")
        res = subprocess.run([sys.executable, path], cwd=ROOT,
                             capture_output=True, text=True)
        if res.returncode == NO_ROM:
            skipped.append(name)
            print("%-14s SKIP (no ROM)" % name)
            continue
        ok = res.returncode == 0
        print("%-14s %s" % (name, "PASS" if ok else "FAIL"))
        if not ok:
            failed.append((name, res.stdout[-2000:] + res.stderr[-2000:]))
    print()
    if failed:
        for name, output in failed:
            print("=== %s ===" % name)
            print(output)
        print("%d module(s) failed" % len(failed))
        return 1
    if skipped:
        print("all test modules passed (%d skipped for want of a ROM: %s)"
              % (len(skipped), ", ".join(skipped)))
    else:
        print("all test modules passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
