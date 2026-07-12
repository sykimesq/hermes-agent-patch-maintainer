#!/bin/bash
# =============================================================================
# apply-patch.sh — Hermes Custom Patch 적용 스크립트
# =============================================================================
# 사용법: bash scripts/apply-patch.sh
#
# Hermes Agent 업데이트 후, 커스텀 패치(agent별 모델 라우팅)를
# 자동으로 적용하고 검증합니다.
#
# 동작:
#   1. Hermes repo 존재 확인
#   2. git status 확인 (dirty 체크)
#   3. git am으로 패치 적용 시도
#   4. 실패 시 3-way merge 재시도
#   5. 성공 시 verify-patch.sh 실행
#   6. 실패 시 충돌 유형 진단 및 안내
# =============================================================================

set -euo pipefail

# --- 설정 ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HERMES_REPO="/c/Users/SYKIM/AppData/Local/hermes/hermes-agent"
PATCH_FILE="$PROJECT_DIR/patch/hermes-agent-profile-routing.patch"
SPEC_FILE="$PROJECT_DIR/FUNCTIONAL_SPEC.md"
VERIFY_SCRIPT="$SCRIPT_DIR/verify-patch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  Hermes Custom Patch 적용${NC}"
echo -e "${CYAN}  Per-Task Model Routing (Agent Profiles)${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

# --- 1. 패치 파일 존재 확인 ---
if [ ! -f "$PATCH_FILE" ]; then
    echo -e "${RED}❌ 패치 파일을 찾을 수 없습니다:${NC}"
    echo "   $PATCH_FILE"
    exit 1
fi
echo -e "${GREEN}✅ 패치 파일 확인:${NC} $(basename "$PATCH_FILE")"

# --- 2. Hermes repo 존재 확인 ---
if [ ! -d "$HERMES_REPO" ]; then
    echo -e "${RED}❌ Hermes repo를 찾을 수 없습니다:${NC}"
    echo "   $HERMES_REPO"
    echo ""
    echo -e "${YELLOW}⚠️  Hermes가 디렉토리 교체 방식으로 업데이트되었을 수 있습니다.${NC}"
    echo "   이 경우 git am 방식의 패치 적용이 불가능합니다."
    echo ""
    echo -e "${CYAN}다음 중 하나를 선택하세요:${NC}"
    echo ""
    echo "  A) Hermes repo가 다른 경로에 있다면:"
    echo "     export HERMES_REPO=/올바른/경로"
    echo "     bash $0"
    echo ""
    echo "  B) 디렉토리가 통째로 교체되었다면:"
    echo "     FUNCTIONAL_SPEC.md($SPEC_FILE)를 참조하여"
    echo "     Sydney에게 재구현을 요청하세요."
    echo ""
    exit 1
fi
echo -e "${GREEN}✅ Hermes repo 확인:${NC} $HERMES_REPO"

# --- 3. git repo 확인 ---
cd "$HERMES_REPO"
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "${RED}❌ $HERMES_REPO가 git 저장소가 아닙니다.${NC}"
    echo "   수동 재구현이 필요합니다. FUNCTIONAL_SPEC.md를 참조하세요."
    exit 1
fi
echo -e "${GREEN}✅ Git 저장소 확인${NC}"

# --- 4. 현재 브랜치 및 상태 출력 ---
BRANCH=$(git rev-parse --abbrev-ref HEAD)
HEAD_HASH=$(git rev-parse --short HEAD)
echo -e "${GREEN}✅ 현재 브랜치:${NC} $BRANCH ($HEAD_HASH)"

# --- 5. dirty 체크 ---
if ! git diff --quiet HEAD; then
    echo -e "${YELLOW}⚠️  작업 디렉토리가 dirty합니다.${NC}"
    echo "   수정된 파일이 있으면 git am이 실패할 수 있습니다."
    echo ""
    git status --short
    echo ""
    echo -e "${CYAN}선택:${NC}"
    echo "  1) git stash로 변경사항 임시 저장 후 재시도"
    echo "  2) git commit으로 변경사항 확정 후 재시도"
    echo "  3) 현재 상태 유지하고 강제 진행 (비권장)"
    echo ""
    echo -e "${YELLOW}git stash를 권장합니다:${NC}"
    echo "   git stash"
    echo "   bash $0"
    exit 1
fi
echo -e "${GREEN}✅ 작업 디렉토리 clean${NC}"

# --- 6. 이미 패치가 적용되었는지 확인 ---
if git log --oneline -1 | grep -q "hermes-agent-profile-routing" 2>/dev/null; then
    echo -e "${YELLOW}⚠️  패치가 이미 적용된 것으로 보입니다.${NC}"
    echo "   (마지막 커밋 메시지에 'hermes-agent-profile-routing' 포함)"
    echo ""
    echo -e "${CYAN}선택:${NC}"
    echo "  1) 검증만 실행: bash scripts/verify-patch.sh"
    echo "  2) 패치를 다시 적용하려면: git reset --hard HEAD~1 후 재실행"
    echo ""
    echo -e "${YELLOW}검증을 실행합니다...${NC}"
    cd "$PROJECT_DIR"
    bash "$VERIFY_SCRIPT"
    exit $?
fi

# --- 7. 패치 적용 시도 ---
echo ""
echo -e "${CYAN}▶ 패치 적용 중...${NC}"

# git am 시도
if git am "$PATCH_FILE" 2>&1; then
    echo -e "${GREEN}✅ 패치 적용 성공!${NC}"
    echo "   커밋: $(git log --oneline -1)"
else
    echo -e "${YELLOW}⚠️  git am 실패. 3-way merge 시도 중...${NC}"
    git am --abort 2>/dev/null || true

    if git am --3way "$PATCH_FILE" 2>&1; then
        echo -e "${GREEN}✅ 3-way merge로 패치 적용 성공!${NC}"
        echo "   커밋: $(git log --oneline -1)"
    else
        echo -e "${RED}❌ 패치 적용 실패.${NC}"
        echo ""
        echo -e "${CYAN}========== 충돌 진단 ==========${NC}"
        echo ""

        # 충돌 파일 확인
        CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
        if [ -n "$CONFLICT_FILES" ]; then
            echo -e "${YELLOW}충돌이 발생한 파일:${NC}"
            echo "$CONFLICT_FILES" | sed 's/^/  - /'
            echo ""
        fi

        # 충돌 유형 분석
        echo -e "${CYAN}충돌 유형 분석:${NC}"
        echo ""

        # upstream에 agent_profiles 관련 코드가 있는지 확인
        if grep -r "agent_profiles" tools/delegate_tool.py > /dev/null 2>&1; then
            echo -e "  ${GREEN}🔍 발견:${NC} upstream에 'agent_profiles' 관련 코드가 이미 존재합니다."
            echo "  → Hermes가 공식적으로 이 기능을 지원하기 시작했을 가능성이 높습니다."
            echo "  → 패치를 폐기하고, config.yaml만 유지하는 것을 권장합니다."
            echo ""
            echo -e "  ${CYAN}권장 조치:${NC}"
            echo "    git am --abort"
            echo "    # config.yaml의 delegation.agent_profiles 섹션만 확인"
        else
            echo -e "  ${YELLOW}🔍 발견:${NC} upstream에 agent_profiles 관련 코드가 없습니다."
            echo "  → 단순 컨텍스트 충돌일 가능성이 높습니다."
            echo ""
            echo -e "  ${CYAN}권장 조치:${NC}"
            echo "    충돌 마커를 수동으로 해결한 후:"
            echo "      git add <파일>"
            echo "      git am --continue"
            echo ""
            echo "    또는 Sydney에게 충돌 해결을 요청하세요."
        fi

        echo ""
        echo -e "${CYAN}참조:${NC} $SPEC_FILE"
        exit 1
    fi
fi

# --- 8. 검증 ---
echo ""
echo -e "${CYAN}▶ 검증 실행 중...${NC}"
cd "$PROJECT_DIR"
if bash "$VERIFY_SCRIPT"; then
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  ✅ 모든 작업 완료!${NC}"
    echo -e "${GREEN}  패치 적용 + 검증 통과${NC}"
    echo -e "${GREEN}============================================${NC}"
else
    echo ""
    echo -e "${RED}============================================${NC}"
    echo -e "${RED}  ❌ 검증 실패${NC}"
    echo -e "${RED}  패치는 적용되었지만 검증을 통과하지 못했습니다.${NC}"
    echo -e "${RED}============================================${NC}"
    echo ""
    echo -e "${YELLOW}가능한 원인:${NC}"
    echo "  - upstream 변경으로 인해 테스트가 깨짐"
    echo "  - 패치가 완전히 적용되지 않음"
    echo ""
    echo -e "${CYAN}권장 조치:${NC}"
    echo "  Sydney에게 'hermes-agent-patch-maintainer 패치 검증 실패를 수정해줘' 요청"
    exit 1
fi
