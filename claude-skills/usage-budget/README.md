# usage-budget

Pace the work against the Claude plan rate limit.

## Purpose

The Claude plan has a 5-hour window and a 7-day window. When a window fills up, the
harness blocks the API calls and the session stops in the middle of the work. This
skill measures the remaining budget and reduces the effort before the limit is
reached.

## What it does

- Reads the account rate limit state from the OAuth usage endpoint. This is the same
  endpoint that the `/usage` command uses.
- Maps the 5-hour utilization to one of four tiers: NORMAL, CONSERVE, MINIMAL, and
  PAUSE. The 5-hour window governs the tier, because it runs out first.
- Applies the tier as a directive. A high tier removes subagents, workflows, web
  research, and broad file reads.
- Warns when the 7-day window is at 90% or above, or when the overage credits are
  exhausted.
- At 95% it stops new work, checkpoints the task, and starts a background waiter. The
  waiter polls every 5 minutes. It exits when the 5-hour window falls below 60%. The
  exit wakes the model, and the work continues from the checkpoint.

## Files

| File | Purpose |
| --- | --- |
| `SKILL.md` | The tier table, the measurement schedule, and the pause procedure. |
| `check-usage.sh` | Prints the usage block with a `TIER:` line and a `DIRECTIVE:` line. `--pct5` prints only the 5-hour percentage. |
| `wait-for-reset.sh` | Blocks until the 5-hour window has room again. Run it in the background. |

## Triggers

The skill starts on requests such as "check the limit", "kontroluj limit", "ile
zostalo limitu", "slow down when close to the limit", and "sleep until the limit
resets".

## Example usage

Ask Claude to watch the limit:

```
> kontroluj limit
> check the limit before you start
> slow down when close to the limit
> sleep until the limit resets
```

Claude runs the check and reports one short line, for example
`5h window: 17% used, resets in 2h 25m (NORMAL)`.

You can also run the scripts by hand.

Print the full status block:

```sh
~/.claude/skills/usage-budget/check-usage.sh
```

```
5h window: 17% used, resets in 2h 25m   <- governs the tier
7d window: 69% used, resets in 1d 12h
TIER: NORMAL
DIRECTIVE: work normally. No restriction.
```

Print only the 5-hour percentage, for a script or a prompt:

```sh
~/.claude/skills/usage-budget/check-usage.sh --pct5
```

```
17
```

Wait until the 5-hour window falls below 60%:

```sh
~/.claude/skills/usage-budget/wait-for-reset.sh
```

The waiter blocks. Claude starts it in the background, and the exit wakes the model.
Two optional arguments change the resume threshold and the poll interval in seconds:

```sh
~/.claude/skills/usage-budget/wait-for-reset.sh 40 60
```

## Requirements

- macOS. `check-usage.sh` reads the OAuth token from the Keychain item
  `Claude Code-credentials`.
- `jq` and `curl`.
- An OAuth session. Plan limits do not apply to API-key, Bedrock, and Vertex
  sessions. In that case the script exits with code 2.

The usage endpoint is internal and undocumented. It can change between CLI versions.
If the response shape changes, the script exits with code 3 and the budget is
reported as unknown.
