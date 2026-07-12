@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

REM ===========================================================================
REM verify-patch.bat -- Hermes Custom Patch Verification (Windows batch)
REM ===========================================================================
REM Usage: scripts\verify-patch.bat
REM
REM Verifies the custom patch is correctly applied by checking:
REM   1. Core functions exist in delegate_tool.py
REM   2. DELEGATE_TASK_SCHEMA has agent/profile fields
REM   3. Unit tests pass
REM   4. config.yaml has agent_profiles section
REM ===========================================================================

set "HERMES_REPO=C:\Users\SYKIM\AppData\Local\hermes\hermes-agent"
set "SYDNEY_CONFIG=C:\Users\SYKIM\AppData\Local\hermes\profiles\sydney\config.yaml"

set "PASS=0"
set "FAIL=0"
set "TOTAL=0"

echo ============================================
echo   Hermes Custom Patch Verification
echo ============================================
echo.

if not exist "%HERMES_REPO%\tools\delegate_tool.py" (
    echo [FAIL] delegate_tool.py not found
    echo   Path: %HERMES_REPO%\tools\delegate_tool.py
    pause
    exit /b 1
)

cd /d "%HERMES_REPO%"

REM ---- [1/4] Core functions ----
echo [1/4] Core function check
echo.

call :check_grep "_get_profile_config" "_get_profile_config" "tools\delegate_tool.py"
call :check_grep "_merge_delegation_profile" "_merge_delegation_profile" "tools\delegate_tool.py"
call :check_grep "_PROFILE_MERGE_KEYS" "_PROFILE_MERGE_KEYS" "tools\delegate_tool.py"
call :check_grep "delegate_task agent param" "agent: Optional" "tools\delegate_tool.py"
call :check_grep "delegate_task profile param" "profile: Optional" "tools\delegate_tool.py"

REM ---- [2/4] Schema fields ----
echo.
echo [2/4] DELEGATE_TASK_SCHEMA check
echo.

call :check_grep "Schema 'agent' field" "\"agent\":" "tools\delegate_tool.py"
call :check_grep "Schema 'profile' field" "\"profile\":" "tools\delegate_tool.py"

REM ---- [3/4] Unit tests ----
echo.
echo [3/4] Unit test check
echo.

call :check_grep "TestAgentProfileRouting class" "TestAgentProfileRouting" "tests\tools\test_delegate.py"
call :check_grep "TestDelegateSchemaProfileFields class" "TestDelegateSchemaProfileFields" "tests\tools\test_delegate.py"

echo.
echo    Running TestAgentProfileRouting...
python -m pytest tests/tools/test_delegate.py::TestAgentProfileRouting -v --tb=short 2>&1 | findstr /C:"FAILED" >nul
if errorlevel 1 (
    call :check_ok "TestAgentProfileRouting tests PASS"
) else (
    call :check_fail "TestAgentProfileRouting tests FAIL"
)

echo    Running TestDelegateSchemaProfileFields...
python -m pytest tests/tools/test_delegate.py::TestDelegateSchemaProfileFields -v --tb=short 2>&1 | findstr /C:"FAILED" >nul
if errorlevel 1 (
    call :check_ok "TestDelegateSchemaProfileFields tests PASS"
) else (
    call :check_fail "TestDelegateSchemaProfileFields tests FAIL"
)

echo    Running existing tests for regression...
python -m pytest tests/tools/test_delegate.py -v --tb=short -k "not TestAgentProfileRouting and not TestDelegateSchemaProfileFields" 2>&1 | findstr /C:"FAILED" >nul
if errorlevel 1 (
    call :check_ok "Existing tests no regression"
) else (
    call :check_fail "Existing tests regression detected"
)

REM ---- [4/4] config.yaml ----
echo.
echo [4/4] config.yaml check
echo.

if exist "%SYDNEY_CONFIG%" (
    findstr "agent_profiles" "%SYDNEY_CONFIG%" >nul 2>&1
    if not errorlevel 1 (
        call :check_ok "config.yaml has agent_profiles section"
        for %%p in (mira rumi zoe) do (
            findstr "%%p:" "%SYDNEY_CONFIG%" >nul 2>&1
            if not errorlevel 1 (
                call :check_ok "  Profile '%%p' exists"
            ) else (
                call :check_fail "  Profile '%%p' not found"
            )
        )
    ) else (
        call :check_fail "config.yaml missing agent_profiles section"
    )
) else (
    call :check_fail "config.yaml not found: %SYDNEY_CONFIG%"
)

REM ---- Summary ----
echo.
echo ============================================
echo   Verification Results
echo ============================================
echo.
echo   Total: %TOTAL% checks
echo   Pass:  %PASS%
if %FAIL% gtr 0 (
    echo   Fail:  %FAIL%
    echo.
    echo [WARN] Some checks failed. Review above.
    pause
    exit /b 1
) else (
    echo   ALL CHECKS PASSED!
    exit /b 0
)

goto :eof

REM ===========================================================================
REM Helper functions
REM ===========================================================================
:check_grep
set /a TOTAL+=1
set "DESC=%~1"
set "PATTERN=%~2"
set "FILE=%~3"
findstr /C:"%PATTERN%" "%FILE%" >nul 2>&1
if not errorlevel 1 (
    echo   [OK] %DESC%
    set /a PASS+=1
) else (
    echo   [FAIL] %DESC%
    set /a FAIL+=1
)
goto :eof

:check_ok
set /a TOTAL+=1
echo   [OK] %~1
set /a PASS+=1
goto :eof

:check_fail
set /a TOTAL+=1
echo   [FAIL] %~1
set /a FAIL+=1
goto :eof
