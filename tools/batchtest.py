"""Boot every ROM in a directory and report what happens.

For each image: parse the header, run it headless for a while, and classify the
result.  Writes a screenshot per ROM and a summary table, so regressions across
a whole library can be seen at a glance.

    python tools/batchtest.py <rom-dir> [--frames 900] [--shots out-dir]
"""
import argparse
import collections
import hashlib
import os
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System
from tools.screenshot import write_png

W, H = 512, 478
NL = chr(10)
TAB = chr(9)

# How many times the normal window a title that has drawn nothing is given
# before its verdict is believed.  See run_one.
PATIENCE = 9

from snes.boards import CHIPSET as COPROCESSORS


def find_roms(root):
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for name in sorted(files):
            if name.lower().endswith((".smc", ".sfc", ".fig", ".swc")):
                out.append(os.path.join(dirpath, name))
    return sorted(out)


# The pad, for the runs that press it.  Start and A between them get past
# a title screen, a "press start", a corrupt-save prompt and most opening
# cutscenes -- which is as far as a run that presses nothing ever gets.
PAD_START = 0x1000
PAD_A = 0x80


def frame_signature(fb):
    """A cheap fingerprint of a frame, for telling motion from a still.

    A title screen is a still.  A game that has actually started is not.
    Booting is the only thing a run that never presses a button can check,
    and it is much less than these ROMs can be asked.
    """
    return hash(bytes(fb[::4 * 397]))


def frame_digest(fb):
    """A stable fingerprint of a frame, for comparing one run to the next.

    frame_signature above uses hash(), which CPython randomises per process:
    fine for counting how often the picture changed inside one run, useless
    for saying whether today's picture is yesterday's.  This one is a digest
    of every pixel and does not move between runs, machines or Python
    versions.
    """
    return hashlib.sha1(bytes(fb)).hexdigest()[:16]


def analyse_frame(fb):
    """Rough description of what is on screen."""
    colours = set()
    nonblack = 0
    step = 4 * 3            # sample every third pixel; plenty for a summary
    for i in range(0, W * H * 4, step):
        b, g, r = fb[i], fb[i + 1], fb[i + 2]
        if b or g or r:
            nonblack += 1
        colours.add((r, g, b))
    return nonblack, len(colours)


def run_one(path, frames, shots_dir, play=False):
    result = {"path": path, "name": os.path.basename(path)}
    try:
        machine = System(path, use_saves=False)
    except Exception as exc:
        result["status"] = "header"
        result["detail"] = "%s: %s" % (type(exc).__name__, exc)
        return result

    cart = machine.cart
    result.update(title=cart.title, map=cart.map_mode_name, chip=cart.coprocessor,
                  size=cart.rom_size, checksum_ok=bool(cart.checksum_ok),
                  coproc=COPROCESSORS.get(cart.coprocessor))

    pcs = collections.Counter()
    t0 = time.perf_counter()
    # Judging a title on its last frame judges it on luck.  Games fade between
    # screens, and a fade sampled at the wrong moment reads as a black screen
    # from an emulator that is in fact drawing the logo perfectly.  So the run
    # is sampled periodically and the best frame is what counts, with the last
    # one kept for the screenshot.
    best = (0, 0)
    best_frame = 0
    every = max(1, frames // 12)
    signatures = []
    try:
        for i in range(frames):
            if play:
                # Press start, then A, over and over: enough to get past a
                # title screen and a prompt, and short enough that a menu it
                # opens gets closed again.
                phase = i % 120
                if phase == 0:
                    machine.set_pad(0, PAD_START)
                elif phase == 8:
                    machine.set_pad(0, 0)
                elif phase == 60:
                    machine.set_pad(0, PAD_A)
                elif phase == 68:
                    machine.set_pad(0, 0)
            machine.run_frame()
            if (i + 1) % every == 0 or i == frames - 1:
                seen = analyse_frame(machine.framebuffer)
                signatures.append(frame_signature(machine.framebuffer))
                if seen > best:
                    best = seen
                    best_frame = i + 1
            if i >= frames - 240:                 # sample the tail for hangs
                r = machine.cpu.regs
                pcs[(r["pb"], r["pc"])] += 1
    except Exception:
        result["status"] = "crash"
        result["detail"] = traceback.format_exc(limit=3).strip().splitlines()[-1]
        result["seconds"] = time.perf_counter() - t0
        return result
    # A title that has not drawn anything yet may simply not have got there.
    # Rudra no Hihou spends more than 900 frames on its sound upload and its
    # opening fades, and reported "flat" here for months on end -- long enough
    # that it was written up as an emulator defect and investigated as one.
    # It renders its opening perfectly at frame 7200.  So a bad verdict is not
    # a verdict until the title has been given several times as long.
    if best[1] <= 2:
        for i in range(frames, frames * PATIENCE):
            machine.run_frame()
            if (i + 1) % every == 0:
                seen = analyse_frame(machine.framebuffer)
                if seen > best:
                    best = seen
                    best_frame = i + 1
            if best[1] > 2:
                break
        result["slow"] = best[1] > 2
    result["seconds"] = time.perf_counter() - t0

    nonblack, colours = best
    result["nonblack"] = nonblack
    result["colours"] = colours
    result["best_frame"] = best_frame
    result["mode"] = machine.ppu.bg_mode if hasattr(machine.ppu, "bg_mode") else -1
    top = pcs.most_common(1)
    result["hot_pc_share"] = (top[0][1] / float(sum(pcs.values()))) if pcs else 0.0
    # How much of the run was not a still picture.
    moved = sum(1 for a, b in zip(signatures, signatures[1:]) if a != b)
    result["moved"] = moved
    result["samples"] = max(0, len(signatures) - 1)

    if nonblack == 0:
        result["status"] = "black"
    elif colours <= 2:
        result["status"] = "flat"
    else:
        result["status"] = "ok"

    result["digest"] = frame_digest(machine.framebuffer)

    if shots_dir:
        os.makedirs(shots_dir, exist_ok=True)
        safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in result["name"])
        result["shot"] = os.path.join(shots_dir, os.path.splitext(safe)[0] + ".png")
        write_png(result["shot"], machine.framebuffer)
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("romdir")
    ap.add_argument("--frames", type=int, default=900)
    ap.add_argument("--shots", default=None)
    ap.add_argument("--filter", default=None, help="only ROMs whose path contains this")
    # A run over a whole library takes hours, so one that is interrupted
    # should not have to start again.  The order is the sorted path order,
    # which does not change between runs, so a position taken from an
    # earlier run's output means the same ROM here.
    ap.add_argument("--start", type=int, default=1,
                    help="skip to this position in the list (1-based)")
    # Not the default, though it was for an hour.  The argument for making
    # it one was that two SPC7110 cartridges sat here as static screens
    # while waiting for a button, with their manufacturer's own check
    # program behind it.  Measured over the whole library, pressing buttons
    # improved no cartridge's classification and worsened three -- and it
    # did not improve those two either, because a check program is white
    # text on black and classifies as "flat" exactly like the prompt it
    # replaced.  What found them was looking at the picture.
    #
    # This report is a regression detector, and its worth is in comparing
    # one run to the next.  Pressing buttons makes a run depend on when the
    # presses land, which costs the comparison more than it pays.
    # Where the last run's answers are kept.  Deliberately not in the
    # repository: it is a list of one machine's game library, and a path or a
    # collection that exists here does not belong in a tree anyone else will
    # clone.  Without one this writes it; with one it compares and says what
    # moved.
    ap.add_argument("--baseline", default=None,
                    help="compare each ROM's final frame against this file")
    # Writing is a separate word on purpose.  With one flag that compares
    # when the file is there and writes when it is not, the first run of an
    # automated check creates the thing it was supposed to check against and
    # reports success -- which is the failure mode this whole file exists to
    # prevent.
    ap.add_argument("--write-baseline", default=None,
                    help="record this run as the baseline in this file")
    ap.add_argument("--play", action="store_true",
                    help="press start and A while it runs, and report how "
                         "much of the run was not a still picture")
    args = ap.parse_args()

    base = {}
    base_frames = None
    if args.baseline and not os.path.exists(args.baseline):
        raise SystemExit("no baseline at %s; take one with --write-baseline"
                         % args.baseline)
    if args.baseline:
        with open(args.baseline) as fh:
            for line in fh:
                if line.startswith("#"):
                    if "frames=" in line:
                        base_frames = int(line.split("frames=")[1].split()[0])
                    continue
                parts = line.rstrip(chr(10)).split(chr(9))
                if len(parts) == 3:
                    base[parts[0]] = (parts[1], parts[2])
        if base_frames is not None and base_frames != args.frames:
            raise SystemExit("baseline was taken over %d frames, this run is %d"
                             % (base_frames, args.frames))
        if args.play:
            raise SystemExit("--play makes a run depend on when the presses "
                             "land; it cannot be compared against a baseline")

    roms = find_roms(args.romdir)
    if args.filter:
        roms = [r for r in roms if args.filter.lower() in r.lower()]
    print("%d ROMs, %d frames each" % (len(roms), args.frames), flush=True)
    print(flush=True)

    results = []
    for i, path in enumerate(roms, 1):
        if i < args.start:
            continue
        res = run_one(path, args.frames, args.shots, play=args.play)
        # Keyed by where it is, not what it is called.  Two of the files in
        # this library share a name -- a Super Mario World and a hack of it
        # in another folder -- and a baseline keyed by name has them
        # overwriting each other's answer, so every run reports a change that
        # depends only on which was read last.
        res["key"] = os.path.relpath(path, args.romdir)
        results.append(res)
        chip = res.get("coproc") or ""
        print("%3d/%-3d %-9s %-46s %-8s $%02X %-8s %s%s"
              % (i, len(roms), res["status"], res["name"][:46],
                 res.get("map", "-"), res.get("chip", 0), chip,
                 res.get("detail", "nonblack=%s colours=%s @f%s moving=%s/%s" %
                         (res.get("nonblack"), res.get("colours"),
                          res.get("best_frame"), res.get("moved"),
                          res.get("samples"))),
                 "  (slow to start)" if res.get("slow") else ""),
              flush=True)

    print(flush=True)
    by_status = collections.Counter(r["status"] for r in results)
    print("summary:", dict(by_status), flush=True)

    if args.baseline:
        changed, missing, added = [], [], []
        for r in results:
            was = base.get(r["key"])
            if was is None:
                added.append(r["key"])
            elif was != (r["status"], r.get("digest", "")):
                changed.append((r["key"], was, (r["status"], r.get("digest", ""))))
        seen = {r["key"] for r in results}
        # Only a whole run can say something has gone.  With --filter or
        # --start the rest were not attempted, and calling that a
        # disappearance turns every subset check into a failure.
        whole = not args.filter and args.start == 1
        missing = [n for n in base if n not in seen] if whole else []
        if changed:
            print(flush=True)
            print("== different from the baseline ==", flush=True)
            for name, was, now in changed:
                print("  %-46s %s %s  ->  %s %s"
                      % (name[:46], was[0], was[1], now[0], now[1]), flush=True)
        for n in added:
            print("  new since the baseline: %s" % n, flush=True)
        for n in missing:
            print("  in the baseline but not run: %s" % n, flush=True)
        if not whole:
            print("  (a subset: %d of the baseline's %d were run)"
                  % (len(results), len(base)), flush=True)
        print(flush=True)
        print("%d of %d match the baseline" % (len(results) - len(changed),
                                               len(results)), flush=True)
        # A regression detector has to be able to fail.  Anything that
        # moved, appeared or vanished is a difference worth stopping on;
        # if the change was meant, take the baseline again.
        return 1 if (changed or added or missing) else 0

    if args.write_baseline:
        with open(args.write_baseline, "w") as fh:
            fh.write("# pysnes library baseline, frames=%d%s" % (args.frames, NL))
            fh.write("# %d ROMs; the final frame of each, as it was on this "
                     "build%s" % (len(results), NL))
            for r in sorted(results, key=lambda r: r["key"]):
                fh.write("%s%s%s%s%s%s" % (r["key"], TAB, r["status"], TAB,
                                           r.get("digest", ""), NL))
        print("baseline written to %s" % args.write_baseline, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
