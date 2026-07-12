#!/bin/bash
# =============================================================================
# reapply-on-update.sh — Hermes Update 후 커스텀 패치 자동 재적용 wrapper
# =============================================================================
# 사용법:
#   bash scripts/reapply-on-update.sh [--dry-run] [--force]
#
# 목적:
#   Hermes 자동 업데이트가 `git reset --hard origin/main`으로 우리 커밋을
#   dangling 상태로 내리는 패턴을 처리합니다. 원본 apply-patch.sh는
#   hermes-agent-profile-routing.patch (원본 패치 파일)에 의존하지만, 이건
#   컨텍스트 변경에 취약합니다. 이 wrapper는:
#
#     1. 우리 마지막 "re-apply" 커밋을 reflog/fsck에서 찾음
#     2. 그 커밋과 그 부모의 diff를 추출
#     3. 현재 upstream HEAD 위에 git apply --reject로 재생
#     4. 깨끗하면 verify-patch.sh 실행
#     5. 충돌이 있으면 .rej 파일과 함께 해결 가이드 출력
#
# 디자인 노트:
#   - 원본 apply-patch.sh를 호출하지 않습니다 (그건 새 설치용).
#   - verify-patch.sh는 동일하게 재사용.
#   - 충돌이 생기면 자동 해결하지 않습니다 — 사용자가 diff를 보고 결정.
#   - --dry-run: 실제 변경 없이 무엇을 할지 미리 출력.
#   - --force: working tree dirty여도 stash 후 진행 (주의: 작업물 손실 가능).
#
# 의존성: bash, git, python3 (verify-patch.sh가 pytest 호출 시 사용)
# =============================================================================

set -euo pipefail

# --- 설정 ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HERMES_REPO="/c/Users/SYKIM/AppData/Local/hermes/hermes-agent"
VERIFY_SCRIPT="$SCRIPT_DIR/verify-patch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 인자 파싱 ---
DRY_RUN=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --force) FORCE=1 ;;
        -h|--help)
            echo "Usage: bash scripts/reapply-on-update.sh [--dry-run] [--force]"
            echo "  --dry-run: Show what would happen without making changes"
            echo "  --force:   Stash dirty working tree before proceeding (use with care)"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown argument: $arg${NC}" >&2
            exit 2
            ;;
    esac
done

run_cmd() {
    # run_cmd <description> <command...>
    # Dry-run 모드에서는 명령을 출력만 하고 실행하지 않음
    local desc="$1"; shift
    echo -e "${CYAN}\$ ${NC}$*"
    if [ "$DRY_RUN" -eq 0 ]; then
        "$@"
    fi
}

echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  Hermes Update 후 패치 자동 재적용${NC}"
echo -e "${CYAN}  (reapply-on-update.sh)${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

# --- 1. Hermes repo 확인 ---
if [ ! -d "$HERMES_REPO" ]; then
    echo -e "${RED}❌ Hermes repo를 찾을 수 없습니다: $HERMES_REPO${NC}"
    exit 1
fi

cd "$HERMES_REPO"
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "${RED}❌ $HERMES_REPO가 git 저장소가 아닙니다.${NC}"
    exit 1
fi

CURRENT_HEAD=$(git rev-parse --short HEAD)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo -e "${GREEN}✅ Hermes repo:${NC} $HERMES_REPO"
echo -e "${GREEN}✅ 현재 상태:${NC} branch=$CURRENT_BRANCH HEAD=$CURRENT_HEAD"
echo ""

# --- 2. 우리 마지막 re-apply 커밋 찾기 ---
# 우선순위: reflog → HEAD의 history → fsck dangling
# "profile-routing" 또는 "TestAgentProfileRouting"을 메시지에 포함한 커밋.
echo -e "${CYAN}[1/6] 우리 마지막 re-apply 커밋 검색${NC}"

LAST_PATCH_COMMIT=""
# 1) HEAD history
LAST_PATCH_COMMIT=$(git log --oneline --grep="profile-routing" -1 --format='%H' 2>/dev/null || true)
# 2) 모든 ref (refs/original/* 포함 가능)
if [ -z "$LAST_PATCH_COMMIT" ]; then
    LAST_PATCH_COMMIT=$(git log --all --oneline --grep="profile-routing" -1 --format='%H' 2>/dev/null || true)
fi
# 3) Reflog (직전 reset으로 dangling된 커밋도 잡힘)
if [ -z "$LAST_PATCH_COMMIT" ]; then
    LAST_PATCH_COMMIT=$(git reflog --grep="profile-routing" -1 --format='%H' 2>/dev/null | head -1 || true)
fi
# 4) Fsck dangling
if [ -z "$LAST_PATCH_COMMIT" ]; then
    LAST_PATCH_COMMIT=$(git fsck --lost-found 2>/dev/null | grep "dangling commit" | awk '{print $3}' | while read sha; do
        msg=$(git log -1 --format='%s' "$sha" 2>/dev/null || true)
        if echo "$msg" | grep -q "profile-routing\|TestAgentProfileRouting"; then
            echo "$sha"; break
        fi
    done)
fi

if [ -z "$LAST_PATCH_COMMIT" ]; then
    echo -e "${RED}❌ 우리 re-apply 커밋을 어디에서도 찾을 수 없습니다.${NC}"
    echo ""
    echo -e "${YELLOW}가능한 원인:${NC}"
    echo "  1. 패치가 한 번도 적용된 적이 없음 → apply-patch.sh를 먼저 실행"
    echo "  2. 너무 오래된 업데이트로 dangling 커밋이 GC됨"
    echo "  3. 다른 메시지 규칙으로 커밋됨 (--grep 패턴이 안 맞음)"
    echo ""
    echo -e "${CYAN}해결:${NC} 다음 중 하나:"
    echo "  A) 최초 설치: bash scripts/apply-patch.sh"
    echo "  B) FUNCTIONAL_SPEC.md를 보고 Sydney에게 재구현 요청"
    exit 1
fi

COMMIT_MSG=$(git log -1 --format='%s' "$LAST_PATCH_COMMIT")
echo -e "${GREEN}✅ 마지막 re-apply 커밋 발견:${NC}"
echo "     $LAST_PATCH_COMMIT  $COMMIT_MSG"
echo ""

# --- 3. upstream에서 새 커밋이 들어왔는지 확인 ---
echo -e "${CYAN}[2/6] upstream 새 커밋 확인${NC}"

# UPSTREAM_BASE = 우리가 마지막으로 패치한 직전의 upstream HEAD.
#
# 우리 re-apply 커밋은 보통 두 개의 커밋 구조:
#   test commit (HEAD)  ← LAST_PATCH_COMMIT
#   patch commit        ← LAST_PATCH_COMMIT^
#   upstream HEAD       ← LAST_PATCH_COMMIT^^  ← 우리가 찾고 싶은 것
#
# 드물게 첫 re-apply가 단일 커밋(직접 패치)일 수 있음. 그 경우:
#   patch commit (HEAD) ← LAST_PATCH_COMMIT
#   upstream HEAD       ← LAST_PATCH_COMMIT^  ← 우리가 찾고 싶은 것
#
# 구분: LAST_PATCH_COMMIT^의 subject가 "patch("로 시작하면 patch 커밋
# (= 우리 구조의 패치 커밋), 그러면 두 단계 거슬러. 아니면(test 커밋)
# 마찬가지로 두 단계 거슬러. 단, patch 커밋이 HEAD인 단일 커밋 re-apply는
# 한 단계만 거슬러.
PARENT_OF_LAST=$(git rev-parse "$LAST_PATCH_COMMIT^" 2>/dev/null || echo "")
if [ -z "$PARENT_OF_LAST" ]; then
    echo -e "${RED}❌ re-apply 커밋의 부모를 찾을 수 없습니다 (corrupt?).${NC}"
    exit 1
fi
PARENT_OF_LAST_SUBJECT=$(git log -1 --format='%s' "$PARENT_OF_LAST" 2>/dev/null || echo "")

if [ -z "$PARENT_OF_LAST_SUBJECT" ] || [ "$PARENT_OF_LAST_SUBJECT" = "$COMMIT_MSG" ]; then
    # 부모가 없거나 자기 자신과 같음 → 비정상
    echo -e "${RED}❌ re-apply 커밋의 부모 subject를 확인할 수 없습니다.${NC}"
    exit 1
fi

# UPSTREAM_BASE 결정:
#   LAST_PATCH_COMMIT의 subject가 test이고, 부모가 patch이면 → 두 단계
#   LAST_PATCH_COMMIT의 subject가 patch이면 → 한 단계
if echo "$COMMIT_MSG" | grep -q "^patch(" && ! echo "$PARENT_OF_LAST_SUBJECT" | grep -q "^test("; then
    # LAST_PATCH_COMMIT 자체가 patch 커밋 → 부모가 upstream base
    UPSTREAM_BASE="$PARENT_OF_LAST"
elif echo "$PARENT_OF_LAST_SUBJECT" | grep -q "^patch("; then
    # LAST_PATCH_COMMIT = test 커밋, 부모가 patch 커밋 → 두 단계
    UPSTREAM_BASE=$(git rev-parse "$LAST_PATCH_COMMIT^^" 2>/dev/null || echo "")
else
    # 판별 불가 → 안전한 보수적 기본값: 한 단계만 거슬러 올라가서 diff 추출
    # (diff가 너무 작으면 사용자 알림)
    UPSTREAM_BASE="$PARENT_OF_LAST"
fi
if [ -z "$UPSTREAM_BASE" ]; then
    echo -e "${RED}❌ UPSTREAM_BASE 결정 실패.${NC}"
    exit 1
fi
echo "     UPSTREAM_BASE = $(git rev-parse --short "$UPSTREAM_BASE")  (우리가 마지막으로 패치한 직전 upstream HEAD)"

# 우리 re-apply 커밋이 HEAD의 ancestor인지 확인
if git merge-base --is-ancestor "$LAST_PATCH_COMMIT" HEAD 2>/dev/null; then
    echo -e "${YELLOW}⚠️  패치가 이미 HEAD에 살아있습니다 (ancestor of HEAD).${NC}"
    echo "   re-apply가 불필요합니다. 검증만 실행할까요? (자동 진행)"
    echo ""

    if [ "$DRY_RUN" -eq 0 ]; then
        echo -e "${CYAN}[verify] verify-patch.sh 실행${NC}"
        cd "$PROJECT_DIR"
        bash "$VERIFY_SCRIPT"
        exit $?
    else
        echo "(dry-run: verify-patch.sh는 실행하지 않음)"
        exit 0
    fi
fi

# UPSTREAM_BASE..HEAD: upstream이 가져온 새 커밋들
NEW_UPSTREAM=$(git log --oneline "$UPSTREAM_BASE"..HEAD 2>/dev/null || echo "")
if [ -z "$NEW_UPSTREAM" ]; then
    # NEW_UPSTREAM이 비어있는 이유:
    #   (a) UPSTREAM_BASE == HEAD (upstream 변경 없음, 우리만 dangling)
    #       → UPSTREAM_BASE 자체에 diff를 직접 적용
    #   (b) UPSTREAM_BASE가 HEAD의 ancestor가 아님 (이상한 상태)
    #       → 사용자에게 알리고 중단
    if [ "$UPSTREAM_BASE" = "$(git rev-parse HEAD)" ]; then
        echo -e "${CYAN}ℹ️  UPSTREAM_BASE가 현재 HEAD와 같습니다.${NC}"
        echo "     upstream에는 새 커밋이 없지만 우리 패치는 dangling 상태입니다."
        echo "     → UPSTREAM_BASE 위에 diff를 직접 적용합니다."
        # UPSTREAM_BASE_HEAD_IDENTICAL=1 마커만 세팅하고 continue
        UPSTREAM_BASE_HEAD_IDENTICAL=1
    else
        # 진짜로 upstream이 비어있는 게 아닌 경우
        if git merge-base --is-ancestor "$UPSTREAM_BASE" HEAD 2>/dev/null; then
            echo -e "${YELLOW}⚠️  새 upstream 커밋이 없습니다 (HEAD == UPSTREAM_BASE).${NC}"
            echo "     re-apply 대상이 없습니다. 종료."
            exit 0
        else
            echo -e "${RED}❌ UPSTREAM_BASE($(git rev-parse --short "$UPSTREAM_BASE"))가${NC}"
            echo -e "${RED}   HEAD($(git rev-parse --short HEAD))의 ancestor가 아닙니다.${NC}"
            echo "     우리가 찾은 re-apply 커밋이 잘못된 것일 수 있습니다."
            echo "     reflog 확인: git reflog --grep=profile-routing"
            exit 1
        fi
    fi
else
    UPSTREAM_BASE_HEAD_IDENTICAL=0
fi

if [ -n "$NEW_UPSTREAM" ]; then
    NEW_COMMIT_COUNT=$(echo "$NEW_UPSTREAM" | grep -c .)
    echo -e "${GREEN}✅ 새 upstream 커밋 ${NEW_COMMIT_COUNT}개 발견:${NC}"
    echo "$NEW_UPSTREAM" | sed 's/^/     /'
    echo ""
fi

# --- 4. Working tree dirty 체크 ---
echo -e "${CYAN}[3/6] Working tree 상태 확인${NC}"
if ! git diff --quiet HEAD 2>/dev/null; then
    echo -e "${YELLOW}⚠️  Working tree가 dirty합니다.${NC}"
    git status --short | sed 's/^/     /'
    echo ""

    if [ "$FORCE" -eq 1 ]; then
        echo -e "${YELLOW}--force 모드: stash로 백업 후 진행${NC}"
        if [ "$DRY_RUN" -eq 0 ]; then
            git stash push -u -m "reapply-on-update.sh backup $(date -Iseconds)" > /dev/null
            echo -e "${GREEN}✅ stash 완료. 복구: git stash pop${NC}"
        fi
    else
        echo -e "${RED}진행 중단. 다음 중 선택하세요:${NC}"
        echo "  1) git stash로 백업 후 --force 옵션으로 재실행"
        echo "  2) 현재 변경사항을 직접 커밋 후 재실행"
        echo "  3) 변경사항 무시 (--force)"
        exit 1
    fi
else
    echo -e "${GREEN}✅ Working tree clean${NC}"
fi
echo ""

# --- 5. Diff 추출 + apply ---
echo -e "${CYAN}[4/6] Diff 추출${NC}"
echo "     re-apply 커밋의 upstream base($(git rev-parse --short "$UPSTREAM_BASE"))부터"
echo "     re-apply 커밋($(git rev-parse --short "$LAST_PATCH_COMMIT"))까지의 diff를 추출합니다."

# 임시 diff 파일
# mktemp는 MSYS bash에서 /tmp를 반환하는데, cmd shell에서 이를 다르게 해석하는
# 경우가 있음. Hermes repo 안의 임시 디렉토리로 만들어서 경로 충돌 회피.
TMPDIR_FOR_DIFF="$HERMES_REPO/.reapply-tmp"
rm -rf "$TMPDIR_FOR_DIFF"
mkdir -p "$TMPDIR_FOR_DIFF"
trap 'rm -rf "$TMPDIR_FOR_DIFF"' EXIT

DIFF_FILE="$TMPDIR_FOR_DIFF/reapply.diff"
# 우리 re-apply 커밋 두 개(테스트 + 패치)의 누적 diff 추출.
# 단, re-apply 커밋이 둘인지 하나인지 모름 — 부모와의 diff 한 번에 추출.
run_cmd "git diff $UPSTREAM_BASE..$LAST_PATCH_COMMIT" \
    git diff "$UPSTREAM_BASE".."$LAST_PATCH_COMMIT" > "$DIFF_FILE"

if [ "$DRY_RUN" -eq 1 ]; then
    # dry-run에서는 run_cmd가 실행되지 않아 파일이 비어있을 수 있음.
    # 표시용이므로 단순히 "(건너뜀)"으로 통일.
    echo "     (dry-run: 실제 diff 추출은 생략, 아래 적용 대상 파일만 표시)"
else
    if [ -s "$DIFF_FILE" ]; then
        DIFF_SIZE=$(wc -l < "$DIFF_FILE")
        echo -e "     ${GREEN}✅ diff 추출 완료: ${DIFF_SIZE} 라인${NC}"
    else
        echo -e "     ${RED}❌ diff 추출 실패 (빈 파일)${NC}"
        exit 1
    fi
fi
echo ""

# 변경 대상 파일 목록 출력 (dry-run에서도 추출이 실제로 일어나므로 가능)
echo "     적용 대상 파일:"
if [ "$DRY_RUN" -eq 0 ]; then
    git diff --name-only "$UPSTREAM_BASE".."$LAST_PATCH_COMMIT" 2>/dev/null | sed 's/^/       - /'
else
    # dry-run에서도 git diff name-only는 사용 가능 (diff 추출과 별개)
    git diff --name-only "$UPSTREAM_BASE".."$LAST_PATCH_COMMIT" 2>/dev/null | sed 's/^/       - /'
fi
echo ""

# --- 6. Apply ---
echo -e "${CYAN}[5/6] git apply --reject (충돌 시 .rej 보존)${NC}"

# .rej 파일이 이미 있으면 정리 (잔여물 방지)
find . -maxdepth 3 -name '*.rej' -not -path './.git/*' -delete 2>/dev/null || true

if [ "$DRY_RUN" -eq 1 ]; then
    echo "     (dry-run: apply 생략)"
    APPLY_RESULT=0
else
    # Windows에서 git apply가 POSIX 경로(/c/...)를 못 읽는 경우가 있음.
    # cygpath -w로 Windows 경로 변환 시도 (POSIX 환경에선 no-op).
    if command -v cygpath >/dev/null 2>&1; then
        DIFF_FILE_WIN=$(cygpath -w "$DIFF_FILE" 2>/dev/null || echo "$DIFF_FILE")
    else
        DIFF_FILE_WIN="$DIFF_FILE"
    fi
    # git apply를 그대로 보여줌 (사용자가 출력 추적 가능)
    if git apply --reject --whitespace=fix "$DIFF_FILE_WIN" 2>&1; then
        APPLY_RESULT=0
    else
        APPLY_RESULT=$?
    fi
fi
echo ""

if [ "$APPLY_RESULT" -eq 0 ]; then
    echo -e "${GREEN}✅ 패치 적용 성공 (충돌 0건)${NC}"
else
    echo -e "${YELLOW}⚠️  일부 hunks가 자동 적용 실패. .rej 파일을 확인하세요.${NC}"
    echo ""
    echo -e "${CYAN}[진단] 충돌 hunks 위치:${NC}"
    find . -maxdepth 3 -name '*.rej' -not -path './.git/*' 2>/dev/null | sed 's/^/     /' || true
    echo ""

    # 충돌 hunks가 무엇인지 grep으로 미리 보여줌
    for rej in $(find . -maxdepth 3 -name '*.rej' -not -path './.git/*' 2>/dev/null); do
        echo -e "${YELLOW}--- $(basename "$rej") (충돌 hunks) ---${NC}"
        # 'error:' 라인이 .rej 파일에는 없고 stderr에만 있으니, our diff에서 reversed lookup
        echo "     (해당 .rej를 텍스트 에디터로 열어 충돌 hunks를 확인)"
        echo ""
    done

    echo -e "${CYAN}[복구 가이드]${NC}"
    echo "  1) .rej 파일을 열어 충돌 hunks를 확인"
    echo "  2) 새 upstream의 delegate_tool.py 컨텍스트를 보고 수동 병합"
    echo "  3) 병합이 끝나면:"
    echo "       rm -f \$(find . -name '*.rej' -not -path './.git/*')"
    echo "       bash scripts/reapply-on-update.sh        # 이 스크립트 재실행"
    echo ""
    echo "  또는 FUNCTIONAL_SPEC.md의 §5 '재구현 가이드'를 보고"
    echo "  Sydney에게 수동 병합을 요청하세요."
    echo ""
    exit 1
fi

# --- 7. 검증 ---
echo -e "${CYAN}[6/6] verify-patch.sh 실행${NC}"
if [ "$DRY_RUN" -eq 0 ]; then
    cd "$PROJECT_DIR"
    if bash "$VERIFY_SCRIPT"; then
        echo ""
        echo -e "${CYAN}============================================${NC}"
        echo -e "${GREEN}  ✅ 재적용 + 검증 완료${NC}"
        echo -e "${CYAN}============================================${NC}"
        echo ""
        echo "변경사항을 커밋하려면:"
        echo "  cd $HERMES_REPO"
        echo "  git add tools/delegate_tool.py tests/tools/test_delegate.py"
        echo "  git commit -m 'patch(hermes-agent-profile-routing): re-apply after upstream update'"
        echo "  git commit -m 'test(delegate): re-apply TestAgentProfileRouting + TestDelegateSchemaProfileFields'"
    else
        echo ""
        echo -e "${RED}❌ 검증 실패${NC}"
        echo "  패치는 적용됐으나 검증 실패. Sydney에게 디버깅 요청하세요."
        exit 1
    fi
else
    echo "     (dry-run: verify-patch.sh 실행 생략)"
    echo ""
    echo -e "${CYAN}============================================${NC}"
    echo -e "${GREEN}  (dry-run) 재실행하여 실제 적용: --dry-run 제거${NC}"
    echo -e "${CYAN}============================================${NC}"
fi