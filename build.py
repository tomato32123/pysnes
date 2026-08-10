"""Build driver for the Cython cores.

Locates MSVC via vswhere (or known install paths), captures the vcvars
environment from a *sanitized* shell -- inheriting a raw MSYS/Git-Bash
environment makes vcvars64.bat fail silently -- then runs setup.py build_ext
with that environment applied.

Usage:  python build.py [--force] [--annotate]
"""
import glob
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
PROGFILES_X86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
VSWHERE = os.path.join(PROGFILES_X86, "Microsoft Visual Studio", "Installer", "vswhere.exe")


def find_vcvars():
    if os.path.exists(VSWHERE):
        try:
            out = subprocess.run(
                [VSWHERE, "-latest", "-products", "*", "-requires",
                 "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                 "-property", "installationPath"],
                capture_output=True, text=True, check=False).stdout.strip()
            if out:
                cand = os.path.join(out, r"VC\Auxiliary\Build\vcvars64.bat")
                if os.path.exists(cand):
                    return cand
        except OSError:
            pass
    pattern = os.path.join(PROGFILES_X86, "Microsoft Visual Studio", "*", "*",
                           r"VC\Auxiliary\Build\vcvars64.bat")
    hits = sorted(glob.glob(pattern), reverse=True)
    if hits:
        return hits[0]
    raise SystemExit("vcvars64.bat not found - install VS Build Tools with the C++ workload")


def msvc_env(vcvars):
    """Run vcvars in a minimal environment and capture the resulting variables."""
    keep = ("SystemRoot", "SystemDrive", "TEMP", "TMP", "USERPROFILE", "ProgramFiles",
            "ProgramFiles(x86)", "ProgramData", "windir", "NUMBER_OF_PROCESSORS",
            "PROCESSOR_ARCHITECTURE", "COMSPEC", "LOCALAPPDATA", "APPDATA")
    base = {k: os.environ[k] for k in keep if k in os.environ}
    root = base.get("SystemRoot", r"C:\Windows")
    base["PATH"] = os.pathsep.join([os.path.join(root, "System32"), root])
    marker = "___VCVARS_DONE___"
    # shell=True (not a ["cmd","/c",...] list): Python's list2cmdline escapes the
    # inner quotes as \" which cmd.exe does not understand.
    res = subprocess.run(f'call "{vcvars}" >nul 2>&1 && echo {marker} && set',
                         shell=True, capture_output=True, text=True, env=base)
    if marker not in res.stdout:
        raise SystemExit("vcvars failed:\n" + res.stdout[-2000:] + res.stderr[-2000:])
    env = dict(base)
    for line in res.stdout.split(marker, 1)[1].splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v
    return env


def main():
    argv = sys.argv[1:]
    env = msvc_env(find_vcvars())
    if "--annotate" in argv:
        env["PYSNES_ANNOTATE"] = "1"
    cmd = [sys.executable, "setup.py", "build_ext", "--inplace"]
    if "--force" in argv:
        cmd.append("--force")
    verbose = "-v" in argv or "--verbose" in argv
    if verbose:
        return subprocess.run(cmd, cwd=ROOT, env=env).returncode

    res = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True,
                         errors="replace")
    # cl.exe echoes its full command line and the name of each .c file; keep only
    # the lines that say something went wrong.
    noise = ("running build_ext", "building ", "creating ", "copying ", "cl.exe",
             "link.exe", "Generating code", "Finished generating")
    for line in (res.stdout + res.stderr).splitlines():
        t = line.strip()
        if not t or t.startswith(noise) or t.endswith(".c") or "cl.exe" in t or "link.exe" in t:
            continue
        print(line)
    if res.returncode == 0:
        print("build ok")
    return res.returncode


if __name__ == "__main__":
    sys.exit(main())
