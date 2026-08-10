# Launch pysnes with an interpreter that can actually load the built cores.
#
# The extension modules are built for one specific CPython minor version, and a
# bare "python" is often a different install (or lacks pygame), so search for a
# 3.12 that can import both snes.system and pygame before giving up.

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

function Test-Interpreter([string]$exe) {
    if (-not $exe) { return $false }
    if (-not (Test-Path $exe)) { return $false }
    & $exe -c "import sys; sys.path.insert(0, r'$root'); import snes.system, pygame" 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

$candidates = @()
if ($env:PYSNES_PYTHON) { $candidates += $env:PYSNES_PYTHON }
$candidates += Join-Path $env:LOCALAPPDATA `
    "Microsoft\WindowsApps\PythonSoftwareFoundation.Python.3.12_qbz5n2kfra8p0\python.exe"
foreach ($cmd in @("python", "python3", "py")) {
    $found = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($found) { $candidates += $found.Source }
}
$candidates += "C:\Python312\python.exe"

$py = $null
foreach ($c in $candidates) {
    if (Test-Interpreter $c) { $py = $c; break }
}

if (-not $py) {
    Write-Error @"
No interpreter found that can import both snes.system and pygame.

  pip install cython pygame
  python build.py

Then re-run, or point PYSNES_PYTHON at the interpreter you built with.
"@
    exit 1
}

& $py (Join-Path $root "play.py") @args
