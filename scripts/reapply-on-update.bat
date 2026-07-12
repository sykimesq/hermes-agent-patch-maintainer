@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

REM ===========================================================================
REM reapply-on-update.bat — Windows wrapper for reapply-on-update.sh
REM ===========================================================================
REM Usage: scripts\reapply-on-update.bat [--dry-run] [--force]
REM
REM This is a thin Windows wrapper that invokes the bash script via git-bash.
REM All logic lives in reapply-on-update.sh so behavior is identical on
REM Windows / macOS / Linux.
REM ===========================================================================

set "SCRIPT_DIR=%~dp0"
set "BASH_SCRIPT=%SCRIPT_DIR%reapply-on-update.sh"

if not exist "%BASH_SCRIPT%" (
    echo [ERROR] reapply-on-update.sh not found at %BASH_SCRIPT%
    pause
    exit /b 1
)

REM --- Locate bash (git-bash on Windows; bash on POSIX) ---
where bash >nul 2>&1
if errorlevel 1 (
    echo [ERROR] bash not found in PATH.
    echo Install Git for Windows (https://git-scm.com) which ships git-bash.
    pause
    exit /b 1
)

echo [INFO] Invoking: bash %BASH_SCRIPT% %*
bash "%BASH_SCRIPT%" %*
set "EXITCODE=%errorlevel%"

if not "%EXITCODE%"=="0" (
    echo.
    echo [INFO] reapply-on-update.sh exited with code %EXITCODE%
)

exit /b %EXITCODE%