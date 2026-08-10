# PyInstaller spec for a single-file pysnes.exe.
#
# The cores are Cython extension modules, so PyInstaller's import scanner
# cannot see what they pull in — every snes.* module is listed explicitly.
#
#   pyinstaller pysnes.spec --noconfirm

block_cipher = None

hidden = [
    "snes",
    "snes.cart",
    "snes.ppu",
    "snes.apu",
    "snes.bus",
    "snes.cpu",
    "snes.system",
    "snes.audioout",
]

a = Analysis(
    ["play.py"],
    pathex=["."],
    binaries=[],
    datas=[],
    hiddenimports=hidden,
    hookspath=[],
    runtime_hooks=[],
    # Only drop what is genuinely unused at runtime.  setuptools/xml/email
    # look droppable but pkg_resources (pulled in by pygame) needs them.
    excludes=["numpy", "Cython", "pip"],
    cipher=block_cipher,
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="pysnes",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    runtime_tmpdir=None,
    console=False,          # no console window; errors go to a dialog
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
