#!/bin/bash
# =============================================================================
# verify-patch.sh — Hermes Custom Patch 검증 스크립트
# =============================================================================
# 사용법: bash scripts/verify-patch.sh
#
# 패치가 올바르게 적용되었는지 다음 항목을 검증합니다:
#   1. 패치 커밋 존재 여부
#   2. delegate_tool.py에 핵심 함수 존재 여부
#   3. DELEGATE_TASK_SCHEMA에 agent/profile 필드 존재 여부
#   4. 단위 테스트 통과 여부
#   5. config.yaml에 agent_profiles 섹션 존재 여부
# =============================================================================

set -euo pipefail

# --- 설정 ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HERMES_REPO="/c/Users/SYKIM/AppData/Local/hermes/hermes-agent"
SYDNEY_CONFIG="/c/Users/SYKIM/AppData/Local/hermes/profiles/sydney/config.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Windows pytest temp 디렉토리 권한 문제 회피
# PermissionError: [WinError 5] 액세스가 거부되었습니다: 'C:\\Users\\SYKIM\\AppData\\Local\\Temp\\pytest-of-SYKIM'
# --basetemp을 지정하면 깨끗한 임시 디렉토리에서 테스트 실행
PYTEST_BASETEMP="C:/Users/SYKIM/AppData/Local/Temp/hermes-pytest"
PYTEST_OPTS="--basetemp $PYTEST_BASETEMP"
PASS=0
FAIL=0
TOTAL=0

check() {
    TOTAL=$((TOTAL + 1))
    local desc="$1"
    local result="$2"
    if [ "$result" = "true" ] || [ "$result" = "0" ]; then
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}✅${NC} $desc"
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}❌${NC} $desc"
        echo -e "    ${RED}→ $3${NC}"
    fi
}

echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  Hermes Custom Patch 검증${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

# --- 1. Hermes repo 존재 확인 ---
if [ ! -d "$HERMES_REPO" ]; then
    echo -e "${RED}❌ Hermes repo를 찾을 수 없습니다: $HERMES_REPO${NC}"
    echo "   검증을 계속할 수 없습니다."
    exit 1
fi
cd "$HERMES_REPO"

# --- 2. 패치 커밋 확인 ---
echo -e "${CYAN}[1/5] 패치 적용 상태 확인${NC}"
PATCH_COMMIT=$(git log --all --oneline --grep="hermes-agent-profile-routing" -1 2>/dev/null || true)
if [ -n "$PATCH_COMMIT" ]; then
    check "패치 커밋 존재" "true" "$PATCH_COMMIT"
else
    # 대체: agent_profiles 관련 변경사항이 있는지 확인
    PATCH_COMMIT_ALT=$(git log --all --oneline --grep="agent.profile" -1 2>/dev/null || true)
    if [ -n "$PATCH_COMMIT_ALT" ]; then
        check "패치 커밋 존재 (agent.profile 검색)" "true" "$PATCH_COMMIT_ALT"
    else
        # 커밋되지 않았지만 working directory에 변경사항이 있는지 확인
        if git diff --name-only 2>/dev/null | grep -q "delegate_tool.py"; then
            check "패치 적용 상태 (커밋 전, working directory에 변경 있음)" "true" "git commit 필요"
        else
            check "패치 커밋 존재" "false" "git log에서 'hermes-agent-profile-routing' 또는 'agent.profile' 커밋을 찾을 수 없습니다. 패치가 아직 적용되지 않았습니다."
        fi
    fi
fi

# --- 3. 핵심 함수 존재 확인 ---
echo ""
echo -e "${CYAN}[2/5] 핵심 함수 존재 확인${NC}"

# delegate_tool.py 존재 확인
if [ -f "tools/delegate_tool.py" ]; then
    check "delegate_tool.py 존재" "true"

    # _get_profile_config 함수
    if grep -q "def _get_profile_config" tools/delegate_tool.py; then
        check "_get_profile_config() 함수 존재" "true"
    else
        check "_get_profile_config() 함수 존재" "false" "함수를 찾을 수 없습니다. 패치가 완전히 적용되지 않았거나 upstream에서 제거되었습니다."
    fi

    # _merge_delegation_profile 함수
    if grep -q "def _merge_delegation_profile" tools/delegate_tool.py; then
        check "_merge_delegation_profile() 함수 존재" "true"
    else
        check "_merge_delegation_profile() 함수 존재" "false" "함수를 찾을 수 없습니다."
    fi

    # _PROFILE_MERGE_KEYS 상수
    if grep -q "_PROFILE_MERGE_KEYS" tools/delegate_tool.py; then
        check "_PROFILE_MERGE_KEYS 상수 존재" "true"
    else
        check "_PROFILE_MERGE_KEYS 상수 존재" "false" "상수를 찾을 수 없습니다."
    fi

    # _resolve_delegation_credentials에 profile 파라미터
    # 함수 시그니처가 여러 줄에 걸쳐 있을 수 있으므로 멀티라인 검색
    if grep -Pzq "def _resolve_delegation_credentials\([^)]*profile:" tools/delegate_tool.py 2>/dev/null; then
        check "_resolve_delegation_credentials(profile=) 파라미터" "true"
    elif grep -A1 "def _resolve_delegation_credentials" tools/delegate_tool.py | grep -q "profile:"; then
        check "_resolve_delegation_credentials(profile=) 파라미터" "true"
    else
        check "_resolve_delegation_credentials(profile=) 파라미터" "false" "profile 파라미터가 없습니다."
    fi

    # delegate_task 함수에 agent 파라미터
    if grep -q "agent: Optional\[str\]" tools/delegate_tool.py; then
        check "delegate_task(agent=) 파라미터" "true"
    else
        check "delegate_task(agent=) 파라미터" "false" "agent 파라미터가 없습니다."
    fi

    # delegate_task 함수에 profile 파라미터
    if grep -q "profile: Optional\[str\]" tools/delegate_tool.py; then
        check "delegate_task(profile=) 파라미터" "true"
    else
        check "delegate_task(profile=) 파라미터" "false" "profile 파라미터가 없습니다."
    fi
else
    check "delegate_tool.py 존재" "false" "tools/delegate_tool.py 파일이 없습니다. Hermes 구조가 변경되었을 수 있습니다."
fi

# --- 4. DELEGATE_TASK_SCHEMA 확인 ---
echo ""
echo -e "${CYAN}[3/5] DELEGATE_TASK_SCHEMA 확인${NC}"

if [ -f "tools/delegate_tool.py" ]; then
    # agent 필드 존재 (최상위)
    if grep -q '"agent":' tools/delegate_tool.py; then
        check "스키마에 최상위 'agent' 필드 존재" "true"
    else
        check "스키마에 최상위 'agent' 필드 존재" "false" "DELEGATE_TASK_SCHEMA properties에 agent 필드가 없습니다."
    fi

    # profile 필드 존재 (최상위)
    if grep -q '"profile":' tools/delegate_tool.py; then
        check "스키마에 최상위 'profile' 필드 존재" "true"
    else
        check "스키마에 최상위 'profile' 필드 존재" "false" "DELEGATE_TASK_SCHEMA properties에 profile 필드가 없습니다."
    fi

    # provider/model/base_url/api_key/api_mode가 스키마에 없음 (보안)
    FORBIDDEN_FOUND=0
    for key in '"provider":' '"model":' '"base_url":' '"api_key":' '"api_mode":'; do
        # tasks.items.properties에서만 확인 (최상위 properties 제외)
        if grep -A5 '"tasks":' tools/delegate_tool.py | grep -q "$key" 2>/dev/null; then
            FORBIDDEN_FOUND=1
            echo -e "    ${YELLOW}⚠️  tasks.items.properties에 $key 발견!${NC}"
        fi
    done
    if [ "$FORBIDDEN_FOUND" -eq 0 ]; then
        check "tasks.items.properties에 provider/model/base_url/api_key/api_mode 없음" "true"
    else
        check "tasks.items.properties에 provider/model/base_url/api_key/api_mode 없음" "false" "모델이 직접 provider/model을 지정할 수 있는 필드가 발견되었습니다."
    fi
fi

# --- 5. 단위 테스트 실행 ---
echo ""
echo -e "${CYAN}[4/5] 단위 테스트 실행${NC}"

if [ -f "tests/tools/test_delegate.py" ]; then
    # TestAgentProfileRouting 클래스 존재 확인
    if grep -q "class TestAgentProfileRouting" tests/tools/test_delegate.py; then
        check "TestAgentProfileRouting 테스트 클래스 존재" "true"

        # 테스트 실행 (해당 클래스만)
        echo ""
        echo -e "    ${CYAN}테스트 실행 중...${NC}"
        set +e
        TEST_OUTPUT=$(python -m pytest tests/tools/test_delegate.py::TestAgentProfileRouting -v --tb=short $PYTEST_OPTS 2>&1)
        TEST_EXIT=$?
        set -euo pipefail

        if [ $TEST_EXIT -eq 0 ]; then
            # 통과한 테스트 수 계산
            PASSED=$(echo "$TEST_OUTPUT" | grep -c "PASSED" 2>/dev/null || echo "0")
            check "TestAgentProfileRouting 테스트 통과" "true" "(${PASSED}개 통과)"
        else
            FAILED_TESTS=$(echo "$TEST_OUTPUT" | grep "FAILED" 2>/dev/null || echo "unknown")
            check "TestAgentProfileRouting 테스트 통과" "false" "테스트 실패: $FAILED_TESTS"
            echo ""
            echo -e "    ${YELLOW}상세 출력:${NC}"
            echo "$TEST_OUTPUT" | tail -30
        fi

        # TestDelegateSchemaProfileFields 테스트
        if grep -q "class TestDelegateSchemaProfileFields" tests/tools/test_delegate.py; then
            set +e
            SCHEMA_OUTPUT=$(python -m pytest tests/tools/test_delegate.py::TestDelegateSchemaProfileFields -v --tb=short $PYTEST_OPTS 2>&1)
            SCHEMA_EXIT=$?
            set -euo pipefail

            if [ $SCHEMA_EXIT -eq 0 ]; then
                PASSED=$(echo "$SCHEMA_OUTPUT" | grep -c "PASSED" 2>/dev/null || echo "0")
                check "TestDelegateSchemaProfileFields 테스트 통과" "true" "(${PASSED}개 통과)"
            else
                FAILED_TESTS=$(echo "$SCHEMA_OUTPUT" | grep "FAILED" 2>/dev/null || echo "unknown")
                check "TestDelegateSchemaProfileFields 테스트 통과" "false" "테스트 실패: $FAILED_TESTS"
                echo ""
                echo -e "    ${YELLOW}상세 출력:${NC}"
                echo "$SCHEMA_OUTPUT" | tail -30
            fi
        fi
    else
        check "TestAgentProfileRouting 테스트 클래스 존재" "false" "테스트 파일에 클래스가 없습니다. 패치가 완전히 적용되지 않았습니다."
    fi

    # 기존 테스트가 여전히 통과하는지 확인 (회귀 검증)
    echo ""
    echo -e "    ${CYAN}기존 테스트 회귀 검증 중...${NC}"
    set +e
    REGRESS_OUTPUT=$(python -m pytest tests/tools/test_delegate.py -v --tb=short -k "not TestAgentProfileRouting and not TestDelegateSchemaProfileFields" $PYTEST_OPTS 2>&1)
    REGRESS_EXIT=$?
    set -euo pipefail

    if [ $REGRESS_EXIT -eq 0 ]; then
        check "기존 테스트 회귀 없음" "true"
    else
        FAILED_TESTS=$(echo "$REGRESS_OUTPUT" | grep "FAILED" 2>/dev/null || echo "unknown")
        check "기존 테스트 회귀 없음" "false" "기존 테스트 실패: $FAILED_TESTS"
        echo ""
        echo -e "    ${YELLOW}상세 출력:${NC}"
        echo "$REGRESS_OUTPUT" | tail -20
    fi
else
    check "test_delegate.py 존재" "false" "tests/tools/test_delegate.py 파일이 없습니다."
fi

# --- 6. config.yaml 확인 ---
echo ""
echo -e "${CYAN}[5/5] config.yaml agent_profiles 확인${NC}"

if [ -f "$SYDNEY_CONFIG" ]; then
    if grep -q "agent_profiles" "$SYDNEY_CONFIG"; then
        check "config.yaml에 agent_profiles 섹션 존재" "true"
        # 각 프로필 확인
        for profile in mira rumi zoe; do
            if grep -A2 "$profile:" "$SYDNEY_CONFIG" | grep -q "provider:" 2>/dev/null; then
                check "  프로필 '$profile'에 provider 설정" "true"
            else
                check "  프로필 '$profile'에 provider 설정" "false" "provider 필드가 없습니다."
            fi
            if grep -A2 "$profile:" "$SYDNEY_CONFIG" | grep -q "model:" 2>/dev/null; then
                check "  프로필 '$profile'에 model 설정" "true"
            else
                check "  프로필 '$profile'에 model 설정" "false" "model 필드가 없습니다."
            fi
        done
    else
        check "config.yaml에 agent_profiles 섹션 존재" "false" "config.yaml에 agent_profiles 섹션이 없습니다. 수동으로 추가해야 합니다."
    fi
else
    check "config.yaml 존재" "false" "$SYDNEY_CONFIG 파일을 찾을 수 없습니다."
fi

# --- 결과 요약 ---
echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  검증 결과${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""
echo -e "  총 ${TOTAL}개 검사"
echo -e "  ${GREEN}통과: ${PASS}${NC}"
if [ "$FAIL" -gt 0 ]; then
    echo -e "  ${RED}실패: ${FAIL}${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  일부 검사가 실패했습니다.${NC}"
    echo "   위 실패 항목을 확인하고 필요한 조치를 취하세요."
    exit 1
else
    echo -e "  ${GREEN}모든 검사 통과!${NC}"
    exit 0
fi
