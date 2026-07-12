# Hermes Agent — Patch Maintainer

Custom patch for [Hermes Agent](https://hermes-agent.nousresearch.com) that adds **per-task model routing** to `delegate_task` via operator-defined agent profiles.

## What This Patch Does

By default, every subagent spawned by `delegate_task` uses the same model (parent's model or `delegation.provider`/`delegation.model`). This patch allows each subagent in a batch to use a **different provider/model** by naming a profile from `config.yaml`:

```python
delegate_task(tasks=[
    {"goal": "Plan the approach",     "agent": "mira"},
    {"goal": "Implement the change",  "agent": "rumi"},
    {"goal": "Verify the result",     "agent": "zoe"},
])
```

### Key Design

- **Operator-controlled**: The model can only *name* a profile — it cannot specify arbitrary provider/model/base_url/api_key
- **Safe fallback**: Unknown profile names log a warning and fall back to base delegation credentials (never crashes)
- **Strict allow-list**: Only 7 routing keys (`provider`, `model`, `base_url`, `api_key`, `api_mode`, `command`, `args`) are merged from a profile
- **Backward compatible**: Existing `delegate_task()` calls without `agent`/`profile` work identically

## Repository Structure

```
├── FUNCTIONAL_SPEC.md          # Durable specification (implementation-agnostic)
├── patch/
│   └── hermes-agent-profile-routing.patch   # Git-format patch file
├── scripts/
│   ├── apply-patch.sh          # Apply patch to Hermes source tree
│   ├── apply-patch.bat         # Windows batch variant
│   ├── verify-patch.sh         # Verify patch is active
│   ├── verify-patch.bat        # Windows batch variant
│   ├── reapply-on-update.sh    # Reapply after `hermes update` resets commits
│   └── reapply-on-update.bat   # Windows batch variant
└── config/
    └── agent_profiles.yaml     # Reference config template
```

## Usage

### Apply the patch

```bash
cd ~/.hermes/hermes-agent
git am /path/to/patch/hermes-agent-profile-routing.patch
```

### Verify

```bash
cd ~/.hermes/hermes-agent
python -m pytest tests/tools/test_delegate.py -k "TestAgentProfileRouting or TestDelegateSchemaProfileFields" -v
```

### Reapply after `hermes update`

`hermes update` runs `git reset --hard origin/main`, which drops custom commits. Use the reapply script:

```bash
bash scripts/reapply-on-update.sh
```

## Configuration

Add profiles to your Hermes profile's `config.yaml`:

```yaml
delegation:
  agent_profiles:
    mira:
      provider: <provider>
      model: <model>
    rumi:
      provider: <provider>
      model: <model>
    zoe:
      provider: <provider>
      model: <model>
```

## License

MIT
