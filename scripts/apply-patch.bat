@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

REM ===========================================================================
REM apply-patch.bat -- Hermes Custom Patch Application (Windows batch)
REM ===========================================================================
REM Usage: scripts\apply-patch.bat
REM
REM After Hermes Agent update, automatically applies the custom patch
REM (per-task model routing via agent profiles) and verifies it.
REM
REM Flow:
REM   1. Check Hermes repo exists
REM   2. Check git status (dirty guard)
REM   3. Try git am to apply patch
REM   4. On failure, retry with 3-way merge
REM   5. On success, run verify-patch.bat
REM   6. On failure, diagnose conflict type and suggest next steps
REM ===========================================================================

set "SCRIPT_DIR=%~dp0"
set "PROJECT_DIR=%SCRIPT_DIR%.."
set "HERMES_REPO=C:\Users\SYKIM\AppData\Local\hermes\hermes-agent"
set "PATCH_FILE=%PROJECT_DIR%\patch\hermes-agent-profile-routing.patch"
set "SPEC_FILE=%PROJECT_DIR%\FUNCTIONAL_SPEC.md"
set "VERIFY_SCRIPT=%SCRIPT_DIR%verify-patch.bat"

echo ============================================
echo   Hermes Custom Patch Application
echo   Per-Task Model Routing (Agent Profiles)
echo ============================================
echo.

REM --- 1. Check patch file ---
if not exist "%PATCH_FILE%" (
    echo [ERROR] Patch file not found:
    echo   %PATCH_FILE%
    pause
    exit /b 1
)
echo [OK] Patch file: hermes-agent-profile-routing.patch

REM --- 2. Check Hermes repo ---
if not exist "%HERMES_REPO%" (
    echo [ERROR] Hermes repo not found:
    echo   %HERMES_REPO%
    echo.
    echo Hermes may have been updated via directory replacement.
    echo In that case, git am cannot apply the patch.
    echo.
    echo Options:
    echo   A) If Hermes repo is at a different path:
    echo      set HERMES_REPO=correct\path
    echo      %0
    echo.
    echo   B) If directory was fully replaced:
    echo      Read FUNCTIONAL_SPEC.md and ask Sydney to reimplement.
    echo      (%SPEC_FILE%)
    echo.
    pause
    exit /b 1
)
echo [OK] Hermes repo: %HERMES_REPO%

REM --- 3. Check git repo ---
cd /d "%HERMES_REPO%"
git rev-parse --git-dir >nul 2>&1
if errorlevel 1 (
    echo [ERROR] %HERMES_REPO% is not a git repository.
    echo   Manual reimplementation required. See FUNCTIONAL_SPEC.md.
    pause
    exit /b 1
)
echo [OK] Git repository confirmed

REM --- 4. Show current branch ---
for /f %%i in ('git rev-parse --abbrev-ref HEAD') do set "BRANCH=%%i"
for /f %%i in ('git rev-parse --short HEAD') do set "HEAD_HASH=%%i"
echo [OK] Current branch: %BRANCH% (%HEAD_HASH%)

REM --- 5. Dirty check ---
git diff --quiet HEAD >nul 2>&1
if not errorlevel 1 goto :CLEAN
echo [WARN] Working directory is dirty.
echo   Modified files may cause git am to fail.
echo.
git status --short
echo.
echo Options:
echo   1) git stash to save changes temporarily, then retry
echo   2) git commit to finalize changes, then retry
echo   3) Force proceed with current state (not recommended)
echo.
echo Recommended: git stash && %0
pause
exit /b 1

:CLEAN
echo [OK] Working directory clean

REM --- 6. Check if patch already applied ---
git log --oneline -1 2>nul | findstr "hermes-agent-profile-routing" >nul
if not errorlevel 1 (
    echo [WARN] Patch appears to already be applied.
    echo   (Last commit message contains 'hermes-agent-profile-routing')
    echo.
    echo   Running verification only...
    cd /d "%PROJECT_DIR%"
    if exist "%VERIFY_SCRIPT%" (
        call "%VERIFY_SCRIPT%"
    ) else (
        echo [WARN] verify-patch.bat not found. Run manually:
        echo   bash scripts/verify-patch.sh
    )
    pause
    exit /b !errorlevel!
)

REM --- 7. Apply patch ---
echo.
echo [STEP] Applying patch...

git am "%PATCH_FILE%" 2>&1
if not errorlevel 1 goto :AM_OK

echo [WARN] git am failed. Retrying with 3-way merge...
git am --abort 2>nul

git am --3way "%PATCH_FILE%" 2>&1
if not errorlevel 1 goto :AM_OK

echo [ERROR] Patch application failed.
echo.
echo ========== Conflict Diagnosis ==========
echo.

echo Conflicted files:
git diff --name-only --diff-filter=U 2>nul
echo.

findstr "agent_profiles" tools\delegate_tool.py >nul 2>&1
if not errorlevel 1 (
    echo [FOUND] Upstream already has 'agent_profiles' related code.
    echo   Hermes may now natively support this feature.
    echo   Consider discarding the patch and keeping only config.yaml.
    echo.
    echo Recommended action:
    echo   git am --abort
    echo   # Verify delegation.agent_profiles in config.yaml still works
) else (
    echo [FOUND] No agent_profiles code in upstream.
    echo   Likely a simple context conflict.
    echo.
    echo Recommended action:
    echo   Resolve conflict markers manually, then:
    echo     git add ^<file^>
    echo     git am --continue
    echo.
    echo   Or ask Sydney to resolve the conflict.
)
echo.
echo Reference: %SPEC_FILE%
pause
exit /b 1

:AM_OK
echo [OK] Patch applied successfully!
for /f "delims=" %%i in ('git log --oneline -1') do echo   Commit: %%i

REM --- 8. Verify ---
echo.
echo [STEP] Running verification...
cd /d "%PROJECT_DIR%"

if exist "%VERIFY_SCRIPT%" (
    call "%VERIFY_SCRIPT%"
    set "VERIFY_EXIT=!errorlevel!"
) else (
    echo [WARN] verify-patch.bat not found. Run manually:
    echo   bash scripts/verify-patch.sh
    set "VERIFY_EXIT=0"
)

echo.
if "!VERIFY_EXIT!"=="0" (
    echo ============================================
    echo   [OK] All done!
    echo   Patch applied + verification passed
    echo ============================================
) else (
    echo ============================================
    echo   [ERROR] Verification failed
    echo   Patch was applied but verification did not pass.
    echo ============================================
    echo.
    echo Possible causes:
    echo   - Upstream changes broke tests
    echo   - Patch was not fully applied
    echo.
    echo Recommended action:
    echo   Ask Sydney: "fix hermes-agent-patch-maintainer verification failure"
)

pause
exit /b %VERIFY_EXIT%
