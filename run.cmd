@echo off
rem Launch pysnes with an interpreter that can actually load the built cores.
rem A bare "python" is often a different minor version than the one the
rem extensions were built for, or lacks pygame, so probe a few candidates.
setlocal enabledelayedexpansion

if "%~1"=="" (
  echo usage: run.cmd ^<rom.smc^> [--scale N] [--no-audio]
  exit /b 1
)

set "PYSNES_ROOT=%~dp0"
set "PYSNES_DIR=%PYSNES_ROOT:~0,-1%"
set "FOUND="

if defined PYSNES_PYTHON call :try "%PYSNES_PYTHON%"
if not defined FOUND call :try "%LOCALAPPDATA%\Microsoft\WindowsApps\PythonSoftwareFoundation.Python.3.12_qbz5n2kfra8p0\python.exe"
if not defined FOUND call :trycmd python
if not defined FOUND call :trycmd python3
if not defined FOUND call :try "C:\Python312\python.exe"

if not defined FOUND (
  echo No interpreter found that can import both snes.system and pygame.
  echo   pip install cython pygame
  echo   python build.py
  echo Then re-run, or set PYSNES_PYTHON to the interpreter you built with.
  exit /b 1
)

"%FOUND%" "%PYSNES_ROOT%play.py" %*
exit /b %ERRORLEVEL%

:try
if not exist %1 goto :eof
%1 -c "import sys; sys.path.insert(0, r'%PYSNES_DIR%'); import snes.system, pygame" >nul 2>&1
if not errorlevel 1 set "FOUND=%~1"
goto :eof

:trycmd
for /f "delims=" %%P in ('where %1 2^>nul') do (
  if not defined FOUND call :try "%%P"
)
goto :eof
