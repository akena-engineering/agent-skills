---
name: usage-budget
description: Use when the user asks to pace work against the Claude plan rate limit, to check how much of the 5-hour or weekly window is left, to adapt effort to the remaining budget, or to pause until the limit renews. Triggers include "kontroluj limit", "check the limit", "ile zostalo limitu", "slow down when close to the limit", "sleep until the limit resets".
---

# Usage budget

Measure the account rate limit, then apply the matching tier of restraint. The 5-hour window governs the tier, because it runs out first.

## Measure

Run:

    ~/.claude/skills/usage-budget/check-usage.sh

The output ends with a `TIER:` line and a `DIRECTIVE:` line. Follow the directive for the rest of the task. Report the 5h number to the user in one short line. Do not paste the whole block.

## Tiers

| 5h used | Tier | What changes |
| --- | --- | --- |
| below 60% | NORMAL | No restriction. |
| 60-84% | CONSERVE | No workflows. One subagent at a time. Narrow file reads. Short answers. |
| 85-94% | MINIMAL | No subagents, no workflows, no web research. Smallest change that satisfies the request. Skip optional verification. |
| 95% and above | PAUSE | Stop new work. Checkpoint, report, wait for the reset. |

## When to measure again

The number goes stale inside a long task. Measure again:

- at the start of the task;
- before you start any subagent or workflow;
- before a large read or a broad search;
- after about 20 tool calls in one task;
- before you tell the user that you will continue.

Do not measure more often than once per minute. Each call is one HTTP request.

## Pause procedure

Start the pause at 95%, not at 100%. At 100% the harness blocks your own API calls. You cannot start the wait after that point.

1. Stop starting new work.
2. Bring the current step to a safe stop. Save the files. Do not leave a half-applied edit.
3. Tell the user what is done, what remains, and when the window resets.
4. Start the waiter with the Bash tool and `run_in_background: true`:

       ~/.claude/skills/usage-budget/wait-for-reset.sh

The waiter polls every 5 minutes. It exits when the 5h window falls below 60%. The exit wakes you. Then continue from the checkpoint in step 3.

The waiter lives as long as the session. If the user closes the terminal, the wait ends. Tell the user this when you start it.

## Failures

- Exit code 2 means that there is no OAuth token. Plan limits do not apply to API-key, Bedrock, and Vertex sessions. Say so and work normally.
- Exit code 3 means that the request failed or the response shape changed. The endpoint is internal and can change between CLI versions. Say that the budget is unknown, do not guess a number, and work as if the tier is CONSERVE.

## Source

`GET https://api.anthropic.com/api/oauth/usage`, with the OAuth token from the macOS Keychain item `Claude Code-credentials` and the header `anthropic-beta: oauth-2025-04-20`. This is the same endpoint that the `/usage` command uses. It is internal and undocumented.
