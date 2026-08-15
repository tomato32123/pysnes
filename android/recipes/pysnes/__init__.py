"""Build the emulator's Cython cores for the phone.

python-for-android knows how to install pure-Python packages and how to
build the recipes it ships with.  This project is neither: snes/*.pyx are
Cython, and they have to be cross-compiled for arm64 against the NDK.
That is what a recipe is for, and it is the only piece of Android
packaging this project actually needs -- everything else in the APK is
Python, pygame and SDL2, which p4a already has.

There is no URL.  The source is the checkout this recipe sits inside, two
directories up, so the build copies it in rather than downloading it.
That keeps the phone and the desktop building the same .pyx files, which
is the whole point: the emulator is not ported to Android, it is compiled
for it.
"""
import sh
from os.path import dirname, abspath, join

from pythonforandroid.recipe import CythonRecipe
from pythonforandroid.logger import info


class PysnesRecipe(CythonRecipe):
    version = 'dev'
    url = None
    name = 'pysnes'

    # setuptools because setup.py uses it; Cython itself runs on the host
    # python, which p4a builds and which this recipe expects to have it.
    depends = ['python3', 'setuptools']

    # The .pyx files cimport each other through snes/*.pxd, so they have to
    # be cythonised together by the project's own setup.py rather than one
    # at a time by p4a's generic path.
    call_hostpython_via_targetpython = False

    def prepare_build_dir(self, arch):
        """Copy the checkout in, minus everything the phone does not need."""
        build_dir = self.get_build_dir(arch)
        source = dirname(dirname(dirname(dirname(abspath(__file__)))))
        info('pysnes: copying {} -> {}'.format(source, build_dir))
        sh.mkdir('-p', build_dir)
        for item in ('snes', 'tools', 'setup.py', 'build.py', 'pyproject.toml'):
            src = join(source, item)
            sh.cp('-a', src, build_dir)
        # A stale build/ from the desktop would put x86-64 objects in the
        # way of the arm64 ones.
        sh.rm('-rf', join(build_dir, 'build'))


recipe = PysnesRecipe()
