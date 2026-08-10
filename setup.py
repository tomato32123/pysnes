import glob
import os
from setuptools import setup, Extension
from Cython.Build import cythonize

DIRECTIVES = {
    "language_level": 3,
    "boundscheck": False,
    "wraparound": False,
    "initializedcheck": False,
    "cdivision": True,
    "nonecheck": False,
    "embedsignature": True,
}

CFLAGS = ["/O2"] if os.name == "nt" else ["-O3"]

extensions = [
    Extension("snes." + os.path.splitext(os.path.basename(p))[0], [p],
              extra_compile_args=CFLAGS)
    for p in sorted(glob.glob("snes/*.pyx"))
]

setup(
    name="pysnes",
    packages=["snes"],
    ext_modules=cythonize(extensions, compiler_directives=DIRECTIVES,
                          annotate=bool(os.environ.get("PYSNES_ANNOTATE")),
                          quiet=True),
)
