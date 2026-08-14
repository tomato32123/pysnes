"""Run every test module and report a single pass/fail, for CI.

The report is written for the case where the person reading it cannot send
the output back -- a phone, a machine across the room, someone relaying it
out loud.  So when things fail, this works out *why* rather than printing
everything and leaving the diagnosis to whoever is looking.

The distinction that matters is between N faults and one fault repeated N
times.  If every module ends on the same exception the emulator may be
entirely sound and something underneath it is missing; if they end on
different ones there is real work.  Those two want opposite next steps, and
telling them apart is a string comparison, so it is done here.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Every module in tests/ runs.  Listing them by hand once let four of them
# sit unrun for a fortnight, so the list is now the directory itself; a test
# that exists is a test that runs, and adding one takes no second step.
def modules():
    names = [n[:-3] for n in os.listdir(os.path.join(ROOT, "tests"))
             if n.startswith("test_") and n.endswith(".py")]
    # The two that want a cartridge go last, so a run without one still
    # reaches the end with everything it could check already checked.
    slow = ("test_state", "test_rewind")
    return sorted(n for n in names if n not in slow) + \
           [n for n in slow if n in names]


NO_ROM = 77          # tools/romarg.py's "there is no ROM here" exit code

# What a failure's last line means, when it means something specific.  These
# are the ones that are not the emulator being wrong, which is exactly the
# distinction a person cannot make from a traceback they did not write.
CAUSES = [
    (r"No module named 'snes\.",
     "the compiled cores are missing -- run: python build.py"),
    (r"No module named '(\w+)'",
     "a package is not installed here: %s"),
    (r"not accessible for the namespace",
     "Android refuses to load a compiled library from shared storage.\n"
     "         The build worked; the .so simply cannot be opened from where it\n"
     "         is.  Copy the project into Termux's own home and run it there:\n"
     "           cp -r . ~/pysnes && cd ~/pysnes && python tools/runtests.py\n"
     "         The ROM can stay where it is -- only compiled libraries are\n"
     "         refused, not data."),
    (r"undefined symbol|cannot open shared object|wrong ELF class",
     "the built cores do not match this Python -- delete snes/*.so and rebuild"),
    (r"No such file or directory: .*\.(smc|sfc|bin|rom)",
     "a test file is missing, not a fault in the emulator"),
    (r"MemoryError",
     "this machine ran out of memory, which is not a result"),
]


def last_line(output):
    """The line that says what went wrong.

    A traceback's final line names the fault; a test that fails its own
    check prints its own message and exits.  Either way the interesting
    line is the last non-empty one.
    """
    for line in reversed(output.strip().splitlines()):
        if line.strip():
            return line.strip()
    return "(no output at all)"


def explain(line):
    for pattern, message in CAUSES:
        found = re.search(pattern, line)
        if found:
            if "%s" in message:
                return message % found.group(1)
            return message
    return None


def main():
    failed, skipped, passed = [], [], []
    for name in modules():
        path = os.path.join(ROOT, "tests", name + ".py")
        res = subprocess.run([sys.executable, path], cwd=ROOT,
                             capture_output=True, text=True)
        if res.returncode == NO_ROM:
            skipped.append(name)
            print("%-16s SKIP (no ROM)" % name)
            continue
        if res.returncode == 0:
            passed.append(name)
            print("%-16s PASS" % name)
        else:
            print("%-16s FAIL" % name)
            failed.append((name, res.stdout[-2000:] + res.stderr[-2000:]))
    print()

    if not failed:
        if skipped:
            print("all %d test modules passed (%d skipped for want of a ROM: %s)"
                  % (len(passed), len(skipped), ", ".join(skipped)))
        else:
            print("all %d test modules passed" % len(passed))
        return 0

    # ---- the diagnosis ---------------------------------------------------
    endings = [last_line(output) for _, output in failed]
    shared = len(set(endings)) == 1 and len(failed) > 1

    if shared:
        print("Every one of the %d modules failed the same way.  That is one"
              % len(failed))
        print("fault, not %d -- most likely something they all rely on, with"
              % len(failed))
        print("the emulator itself untested rather than wrong.")
        print()
        print("  %s" % endings[0][:200])
        reason = explain(endings[0])
        if reason:
            print()
            print("  cause: %s" % reason)
    else:
        print("%d module(s) failed, on %d different faults:"
              % (len(failed), len(set(endings))))
        print()
        for (name, _), ending in zip(failed, endings):
            print("  %-16s %s" % (name, ending[:120]))
            reason = explain(ending)
            if reason:
                print("  %-16s cause: %s" % ("", reason))

    # The full output still goes out, after the summary rather than before
    # it, so scrolling back is only needed when the summary is not enough.
    print()
    for name, output in failed:
        print("=== %s ===" % name)
        print(output)
    print("%d of %d modules failed" % (len(failed), len(failed) + len(passed)))
    return 1


if __name__ == "__main__":
    sys.exit(main())
