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

What works is removing the distribution, the recipe's build **and its
install**, which forces the whole chain and still does not rebuild SDL or
Python:

    B=.buildozer/android/platform/build-arm64-v8a
    rm -rf "$B/dists/pysnes" "$B/build/other_builds/pysnes" \
           "$B/build/python-installs/pysnes"
    buildozer android debug

The install directory is the one that catches people out.  Leaving it in
place, the recipe compiles fresh every time -- the log is four thousand
lines, the `.c` files are regenerated, the `.so` files appear with the
current timestamp -- and then the install step decides the package is
already there and packages the old copy.  Every APK built here between 08:26
and 11:52 one morning carried the same core, byte for byte, through four
rebuilds that all looked convincing.

**Check the artefact by identity, not by existence.**  Counting modules and
running `file` proves the APK has *a* core, not *this* core, and that is the
mistake that let those four through.  Compare what was packed against what
was built:

    python -c "
    import zipfile, tarfile, io, hashlib, glob, os
    z = zipfile.ZipFile('android/bin/pysnes-0.1-arm64-v8a-debug.apk')
    t = tarfile.open(fileobj=io.BytesIO(z.read('lib/arm64-v8a/libpybundle.so')))
    packed = {n.split('/')[-1]: hashlib.md5(t.extractfile(n).read()).hexdigest()
              for n in t.getnames() if '/snes/' in n and n.endswith('.so')}
    built = {os.path.basename(f).split('.')[0] + '.so':
             hashlib.md5(open(f,'rb').read()).hexdigest()
             for f in glob.glob('android/.buildozer/android/platform/'
                                'build-arm64-v8a/build/other_builds/pysnes/*/'
                                'pysnes/build/lib.*/snes/*.so')}
    print(sum(1 for k in packed if built.get(k) == packed[k]), 'of', len(packed))"

Fifteen of fifteen is right.  Anything less means the packaging and the build
disagree.

The app itself is `main.pyc` inside `assets/private.tar`, a separate tar in
the same APK, and it goes stale independently:

    python -c "
    import zipfile, tarfile, io
    z = zipfile.ZipFile('android/bin/pysnes-0.1-arm64-v8a-debug.apk')
    m = tarfile.open(fileobj=io.BytesIO(z.read('assets/private.tar')))
    d = m.extractfile('main.pyc').read()
    print('fps readout:', b'fps' in d)"

-- or whatever string the newest change added.  A compiled module keeps the
strings its source had, so this one does work, unlike searching a `.so` for
a `cdef` field that has no name in it.

Searching the binary for a symbol does not work as a freshness check and
looked as though it did.  A `cdef` struct member has no name in the compiled
object, so its absence proves nothing -- and `strings` is not on the PATH
without the conda environment, so the search printed 0 because the command
was missing, which reads exactly like a real answer.

One thing that looks wrong and is not: the intermediate objects are named
`ppu.cpython-314-x86_64-linux-gnu.so`.  That is the *host* Python's tag.
`file` on them, and on the copy inside the bundle, says `ARM aarch64`.

## Keeping the APK current

It goes stale quickly: the first build was made twenty commits before it was
next looked at, and by then it was missing a day of fixes and about a tenth
of the frame rate. Rebuild it after any run of core changes worth having on
the phone.
