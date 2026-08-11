"""Boot every ROM in a directory and report what happens.

For each image: parse the header, run it headless for a while, and classify the
result.  Writes a screenshot per ROM and a summary table, so regressions across
a whole library can be seen at a glance.

    python tools/batchtest.py <rom-dir> [--frames 900] [--shots out-dir]
"""
import argparse
import collections
import os
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System
from tools.screenshot import write_png

W, H = 512, 478

from snes.boards import CHIPSET as COPROCESSORS


def find_roms(root):
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for name in sorted(files):
            if name.lower().endswith((".smc", ".sfc", ".fig", ".swc")):
                out.append(os.path.join(dirpath, name))
    return sorted(out)


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


def run_one(path, frames, shots_dir):
    result = {"path": path, "name": os.path.basename(path)}
    try:
        machine = System(path)
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
    try:
        for i in range(frames):
            machine.run_frame()
            if (i + 1) % every == 0 or i == frames - 1:
                seen = analyse_frame(machine.framebuffer)
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
    result["seconds"] = time.perf_counter() - t0

    nonblack, colours = best
    result["nonblack"] = nonblack
    result["colours"] = colours
    result["best_frame"] = best_frame
    result["mode"] = machine.ppu.bg_mode if hasattr(machine.ppu, "bg_mode") else -1
    top = pcs.most_common(1)
    result["hot_pc_share"] = (top[0][1] / float(sum(pcs.values()))) if pcs else 0.0

    if nonblack == 0:
        result["status"] = "black"
    elif colours <= 2:
        result["status"] = "flat"
    else:
        result["status"] = "ok"

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
    args = ap.parse_args()

    roms = find_roms(args.romdir)
    if args.filter:
        roms = [r for r in roms if args.filter.lower() in r.lower()]
    print("%d ROMs, %d frames each" % (len(roms), args.frames), flush=True)
    print(flush=True)

    results = []
    for i, path in enumerate(roms, 1):
        res = run_one(path, args.frames, args.shots)
        results.append(res)
        chip = res.get("coproc") or ""
        print("%3d/%-3d %-9s %-46s %-8s $%02X %-8s %s"
              % (i, len(roms), res["status"], res["name"][:46],
                 res.get("map", "-"), res.get("chip", 0), chip,
                 res.get("detail", "nonblack=%s colours=%s @f%s" %
                         (res.get("nonblack"), res.get("colours"),
                          res.get("best_frame")))),
              flush=True)

    print(flush=True)
    by_status = collections.Counter(r["status"] for r in results)
    print("summary:", dict(by_status), flush=True)
    return results


if __name__ == "__main__":
    main()
