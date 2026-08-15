[app]

title = pysnes
package.name = pysnes
package.domain = org.pysnes

# The app is this directory; the emulator itself is the parent, which the
# recipe below builds and installs into the same Python.
source.dir = .
source.include_exts = py,png,ttf

version = 0.1

# pygame carries the SDL2 bootstrap, which is the same path the desktop front
# end takes -- a window, a streaming texture, and the mixer.  The cores are
# not here: they are Cython, and Cython extensions cannot be listed as a
# requirement.  See the note at the bottom.
requirements = python3,pygame

orientation = landscape
fullscreen = 1

# A phone that rotates mid-frame would otherwise take the window away.
android.presplash_color = #14151A

# Where a cartridge is looked for.  Android 11 and later hand out scoped
# storage, so the app reads from its own directory unless the user grants
# the broader permission.
android.permissions = READ_EXTERNAL_STORAGE

# arm64 is every phone made in the last decade; armeabi-v7a is there for
# older hardware and costs only build time.
android.archs = arm64-v8a

android.api = 34
android.minapi = 24
android.ndk_api = 24

# Keep the build's own noise out of the repository.
android.private_storage = True

[buildozer]
log_level = 2
warn_on_root = 1


# ---------------------------------------------------------------------------
# What is not solved here
#
# python-for-android installs pure-Python packages and its own recipes.  The
# emulator is neither: snes/*.pyx are Cython extensions that have to be
# cross-compiled for arm64 against the Android NDK, and that needs a recipe
# of its own -- a small Python class telling p4a to run this project's
# setup.py with the NDK's compiler.
#
# Writing that recipe is the remaining piece of packaging, and it cannot be
# tested without the SDK and NDK on the machine, which is several gigabytes
# of download.  Until then this spec describes an app that would build if
# the cores were already there.
#
# The alternative worth knowing about: Termux needs none of this.  It has a
# compiler on the phone, so `python build.py` works there directly, which is
# why the speed measurement was proposed that way -- it skips every problem
# in this file.
# ---------------------------------------------------------------------------
