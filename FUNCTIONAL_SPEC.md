# Hermes Agent — Per-Task Model Routing (Agent Profiles)

## Functional Specification

### 1. Problem Statement

Hermes Agent의 `delegate_task` 도구는 기본적으로 모든 subagent가 부모와 동일한 모델을 사용하거나, `delegation.provider`/`delegation.model`로 모든 subagent를 동일한 모델로 고정한다.

사용자는 **하나의 `delegate_task` 호출 내에서 각 subagent마다 서로 다른 provider/model을 할당**할 수 있어야 한다. 예를 들어:
- `mira`는 planning 전용 모델
- `rumi`는 implementation 전용 모델
- `zoe`는 verification 전용 모델

이때 모델/provider 문자열은 **operator(사용자)만 설정**할 수 있고, LLM 모델이 임의로 지정할 수 없어야 한다.

---

### 2. Requirements

#### 2.1 설정 (Configuration)

`config.yaml`의 `delegation` 섹션 아래에 `agent_profiles`라는 이름으로 named profile을 정의할 수 있어야 한다.

```yaml
delegation:
  agent_profiles:
    <profile_name>:
      provider: <provider_name>
      model: <model_name>
      # 선택적 필드:
      base_url: <url>
      api_key: <key>
      api_mode: <mode>
      command: <command>
      args: [<arg>, ...]
```

- `<profile_name>`은 operator가 자유롭게 정한다 (예: `mira`, `rumi`, `zoe`)
- 각 profile은 `provider`와 `model`을 **필수**로 가진다
- `base_url`, `api_key`, `api_mode`, `command`, `args`는 **선택** — 지정 시 해당 subagent에만 적용
- 레거시 호환: `delegation.agents` 키도 동일한 구조로 지원

#### 2.2 API (delegate_task)

`delegate_task` 함수는 다음 두 파라미터를 추가로 받는다:

| 파라미터 | 타입 | 위치 | 설명 |
|---------|------|------|------|
| `agent` | string | 최상위 + per-task | 프로필명 지정 |
| `profile` | string | 최상위 + per-task | `agent`의 alias |

**사용 예시 (batch 모드):**
```python
delegate_task(tasks=[
    {"goal": "Plan",     "agent": "mira"},
    {"goal": "Implement", "agent": "rumi"},
    {"goal": "Verify",    "agent": "zoe"},
])
```

**사용 예시 (단일 task 모드):**
```python
delegate_task(goal="Verify the patch", agent="zoe")
```

#### 2.3 우선순위 (Resolution Precedence)

각 subagent의 provider/model은 다음 순서로 결정된다:

1. **`task["agent"]` / `task["profile"]`** — batch 모드에서 각 task별 지정
2. **최상위 `agent` / `profile`** — 단일 task 모드
3. **`delegation.provider` / `delegation.model`** — base config
4. **부모 agent 상속** — 아무것도 설정되지 않은 경우

#### 2.4 안전장치 (Safety)

- **모델이 provider/model을 직접 지정할 수 없음**: `agent`/`profile` 파라미터만 노출. `provider`, `model`, `base_url`, `api_key`, `api_mode`는 스키마에 존재하지 않음
- **알 수 없는 프로필명은 크래시가 아님**: warning 로그를 남기고 base config로 fallback
- **프로필은 라우팅 키만 override**: `_PROFILE_MERGE_KEYS`에 정의된 7개 키(`provider`, `model`, `base_url`, `api_key`, `api_mode`, `command`, `args`)만 병합. 다른 delegation 설정은 건드리지 않음

#### 2.5 동작 변경사항

- 기존: `delegate_task()` 루프 밖에서 한 번 credential resolution
- 변경: 루프 안에서 각 task마다 개별 credential resolution
- 기존 동작(프로필 미사용 시)은 완전히 동일하게 유지

---

### 3. Affected Code Areas

#### 3.1 `tools/delegate_tool.py`

| 영역 | 설명 |
|------|------|
| `delegate_task()` 함수 시그니처 | `agent`, `profile` 파라미터 추가 |
| `delegate_task()` docstring | 새 파라미터 설명 추가 |
| credential resolution 위치 | 루프 밖 → 루프 안 (per-task) |
| 단일 task 구성 | `agent`/`profile`을 task dict에 전파 |
| background metadata | `child_models` 집계 (여러 모델일 경우 joined list) |
| `_get_profile_config()` | **신규**: config에서 프로필명으로 dict 조회 |
| `_merge_delegation_profile()` | **신규**: 프로필 키를 base config에 병합 |
| `_resolve_delegation_credentials()` | `profile` 파라미터 추가, merge 로직 추가 |
| `_load_config()` | **수정**: `CLI_CONFIG`에 `agent_profiles`가 없으면 fallback 경로로 내려가서 파일 기반 config를 읽도록 조건 강화 |
| `_build_top_level_description()` | agent_profiles 언급으로 업데이트 |
| `DELEGATE_TASK_SCHEMA` | `agent`/`profile` 필드 추가 (최상위 + per-task) |
| registry 등록 | `agent`/`profile` 인자 전달 |

#### 3.2 `tests/tools/test_delegate.py`

| 영역 | 설명 |
|------|------|
| `TestAgentProfileRouting` 클래스 | **신규**: 10개 테스트 케이스 |
| `TestDelegateSchemaProfileFields` 클래스 | **신규**: 스키마 검증 3개 테스트 |
| import 추가 | `_get_profile_config`, `_merge_delegation_profile` |

#### 3.3 `website/docs/user-guide/features/delegation.md`

"Per-Task Model Routing (Profiles)" 섹션 추가 (약 50라인).

#### 3.4 `config.yaml` (프로필 설정)

`delegation.agent_profiles` 아래에 각 프로필 정의.

---

### 4. Verification Criteria

패치가 올바르게 적용되었는지 확인하려면:

1. **테스트 통과**: `python -m pytest tests/tools/test_delegate.py -v`에서 `TestAgentProfileRouting`과 `TestDelegateSchemaProfileFields`가 모두 통과
2. **스키마 확인**: `DELEGATE_TASK_SCHEMA`에 `agent`와 `profile` 필드가 존재하고, `provider`/`model`/`base_url`/`api_key`/`api_mode`는 존재하지 않음
3. **기존 동작 보존**: 프로필을 사용하지 않는 기존 테스트가 모두 통과
4. **실제 delegation**: `delegate_task(tasks=[{"goal":"...","agent":"mira"}, ...])`가 각각 다른 모델로 라우팅됨

---

### 5. Rebase / Reimplementation Guide

이 패치가 upstream 변경으로 인해 더 이상 `git am`으로 적용되지 않을 때:

1. **upstream의 변경사항 파악**: `git log --oneline tools/delegate_tool.py`로 최근 커밋 확인
2. **upstream이 같은 기능을 구현했는지 확인**: `delegation.agent_profiles` 또는 유사 키워드 검색
3. **판단**:
   - Upstream이 더 나은 구현을 제공 → 패치 폐기, config만 유지
   - Upstream이 다른 방향 → 이 명세서를 기준으로 새 코드베이스에 재구현
   - 단순 컨텍스트 충돌 → 수동 merge 후 `git am --continue`

재구현 시 핵심 로직:
```
1. delegate_task()에 agent/profile 파라미터 추가
2. config.yaml에서 delegation.agent_profiles 읽기
3. 각 task의 agent/profile명으로 프로필 조회
4. 프로필의 provider/model로 _build_child_agent() 호출
5. 알 수 없는 프로필명은 warning + fallback
```
