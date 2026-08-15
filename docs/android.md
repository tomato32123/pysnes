# Android

**Built.** `android/bin/pysnes-0.1-arm64-v8a-debug.apk` is a real APK for
`arm64-v8a`, produced on this machine by Buildozer and python-for-android.
Everything below is what it took and what is still unknown.

Most of this file used to describe a Windows machine whose WSL2 would not
start because VT-x was off in its firmware. That machine is not this one and
that blocker does not exist here; the history has been dropped rather than
left to mislead. Nobody needs to go looking for a BIOS setting.

## How it is built

```
cd android
buildozer android debug
```

from the conda `pysnes` environment, with the compiler variables **unset**
first:

```
unset LDFLAGS CFLAGS CPPFLAGS CXXFLAGS PKG_CONFIG_PATH CC CXX AR LD
```

That is not optional. Conda's activation puts its own `CC`, `LDFLAGS` and
`PKG_CONFIG_PATH` into the environment, and the NDK's cross-compiler then
picks up x86-64 libraries and headers from the host: the failures it caused
were an x86-64 `libzstd` and `libuuid` offered to an `aarch64` link, and a
`Makefile` cached with a poisoned `CC` that survived several clean attempts.

`android/recipes/pysnes` is a python-for-android `CythonRecipe` that copies
`snes/`, `tools/`, `setup.py`, `build.py` and `pyproject.toml` out of the
project and builds them in place. `pyproject.toml` exists for that recipe:
without it the isolated build has no Cython.

## What it packages

`android/main.py` looks for ROMs in, in order:

    /storage/emulated/0/Android/data/org.pysnes.pysnes/files/roms
    the app's own files directory
    ./roms

The first is the one to use. Android 11's scoped storage will not let the
app read an arbitrary folder, and -- separately -- the linker refuses to
`dlopen` a shared object from `/storage` at all, which is why running the
emulator from Termux out of shared storage fails every test at once.
`tools/armcheck.sh` refuses to start from there and says why.

## What is still unknown

1. **Speed on the phone.** No ARM measurement exists. On this desktop the
   core runs Super Mario World at about 236 fps, four times the 60 Hz
   budget; a phone's single core on this kind of work is commonly several
   times slower, which could put it anywhere from comfortable to half speed.
   Until someone runs it, this is a guess and should be written as one.
2. **The app is thin.** Display, sound and touch controls exist only as much
   as `android/main.py` has them. Save states, a ROM picker and configuration
   are not there.
3. **Six coprocessors still want firmware**, so the DSP titles -- Super Mario
   Kart among them -- will not play correctly wherever this runs. That is not
   an Android problem.

## Buildozer will package an APK with no emulator in it and report success

`buildozer android debug` does not rebuild a recipe once a distribution
exists.  Three builds in a row exited 0 here and none of them was what it
claimed:

1. Rebuilding after a day of core changes produced an APK of **exactly the
   same size, byte for byte**, with the old core in it.  The log was 188
   lines and never mentioned Cython.
2. Deleting the intermediate build directory changed nothing: p4a decides
   whether a recipe needs building by looking for the *installed* package,
   and the install lives in two places, the python-installs directory and
   the distribution's site-packages.
3. Deleting `snes/` from both left `pysnes-0.0.0.dist-info` behind, which
   still says "installed".  That build succeeded, reported success, and
   shipped an APK **with no emulator in it at all** -- 768 KB smaller, and
   silently useless.

What works is removing the distribution, which forces it to be rebuilt from
the recipes that are already compiled, so SDL and Python are not rebuilt:

    B=.buildozer/android/platform/build-arm64-v8a
    rm -rf "$B/dists/pysnes" "$B/build/other_builds/pysnes"
    buildozer android debug

A real build of this recipe writes about 4,300 lines of log.  A few hundred
means it packaged whatever was lying around.

**Check the artefact, not the exit code.**  The Python side is not a plain
zip entry: it is a tar inside `lib/arm64-v8a/libpybundle.so`.

    python -c "
    import zipfile, tarfile, io
    z = zipfile.ZipFile('android/bin/pysnes-0.1-arm64-v8a-debug.apk')
    t = tarfile.open(fileobj=io.BytesIO(z.read('lib/arm64-v8a/libpybundle.so')))
    print(sorted(n.split('/')[-1] for n in t.getnames()
                 if '/snes/' in n and n.endswith('.so')))"

Fifteen modules is right.  Zero is the failure above, and nothing else in
the build says so.

One thing that looks wrong and is not: the intermediate objects are named
`ppu.cpython-314-x86_64-linux-gnu.so`.  That is the *host* Python's tag.
`file` on them, and on the copy inside the bundle, says `ARM aarch64`.

## Keeping the APK current

It goes stale quickly: the first build was made twenty commits before it was
next looked at, and by then it was missing a day of fixes and about a tenth
of the frame rate. Rebuild it after any run of core changes worth having on
the phone.
