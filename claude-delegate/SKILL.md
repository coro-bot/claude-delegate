---
name: claude-delegate
description: Delegate bounded coding, review, analysis, debugging, or second-opinion tasks to the local Claude Code CLI through the bundled PowerShell bridge script. Use when the user explicitly asks to use Claude, Claude Code, a Claude subagent, an independent second opinion, or external cross-checking through the `claude` command.
---

# Claude Delegate

Use the local `claude` command as an external, non-interactive reviewer or worker through `scripts/claude-bridge.ps1`. Treat Claude Code as a separate agent process: give it a bounded task, collect its answer, and integrate the useful result yourself.

## Locate The Bridge

If Codex knows the directory containing this `SKILL.md`, resolve the bridge directly:

```powershell
$skillDir = "<directory containing this SKILL.md>"
$bridge = Join-Path $skillDir "scripts/claude-bridge.ps1"
```

If the skill directory is unknown, use this portable resolver:

```powershell
function Get-ClaudeDelegateBridge {
    $candidateRoots = @()

    $dir = (Get-Location).Path
    while ($dir) {
        $candidateRoots += Join-Path $dir ".codex/skills/claude-delegate"
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }

    if ($env:CODEX_HOME) {
        $candidateRoots += Join-Path $env:CODEX_HOME "skills/claude-delegate"
    }
    $candidateRoots += Join-Path $HOME ".codex/skills/claude-delegate"

    foreach ($root in ($candidateRoots | Select-Object -Unique)) {
        $candidate = Join-Path $root "scripts/claude-bridge.ps1"
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Cannot find claude-delegate/scripts/claude-bridge.ps1. Set CODEX_HOME or use the actual skill path."
}

$bridge = Get-ClaudeDelegateBridge
```

Before the first delegation in a session, run the health check:

```powershell
$check = & $bridge -Check | ConvertFrom-Json
if (-not $check.success) {
    throw (($check.error, $check.stderr, "exit_code=$($check.exit_code)" | Where-Object { $_ }) -join [Environment]::NewLine)
}
```

If the check fails, report the JSON error and do not emulate Claude's answer.

## When To Delegate

Use the bridge for bounded side tasks such as:

- Independent code review of a specific diff, file, module, or plan.
- Bug-hypothesis generation after local investigation has narrowed the scope.
- Design critique or alternative implementation options.
- Test-gap review, security review, or maintainability review.
- Summarizing a file or pasted logs from a second model's perspective.

Do not delegate:

- The immediate critical-path step when you need the result before doing anything else locally.
- Vague repo-wide work without a clear scope.
- Secret-bearing content unless the user explicitly accepts sending it to Claude/Anthropic.
- Concurrent write-heavy work in the same working tree unless the user explicitly requests it.

## Invoke Claude

Use a single-quoted here-string for literal prompts. Use a double-quoted here-string only when interpolating variables such as a captured diff.

```powershell
$prompt = @'
You are acting as an independent coding agent.

Task:
<specific bounded task>

Scope:
<exact file paths, diff, logs, or command output>

Constraints:
- Do not modify files unless explicitly asked.
- Include file paths and line references where possible.
- If evidence is insufficient, still report what you can determine, then end with a "MISSING CONTEXT:" list naming the exact files, line ranges, or command output needed.
- Do not guess and do not stop at a clarifying question; the caller may resume this session with the missing context.

Return:
<desired format>
'@

$result = & $bridge -Cwd "." -Prompt $prompt | ConvertFrom-Json
if (-not $result.success) {
    throw (($result.error, $result.stderr, $result.raw | Where-Object { $_ }) -join [Environment]::NewLine)
}

$result.agent_messages
```

The bridge sends the prompt to Claude over stdin rather than as a command-line argument, avoiding Windows argument-length limits, quoting bugs, and prompt exposure in process listings. JSON is the default output format; always parse the envelope and check `success` before trusting `agent_messages`.

By default, Claude gets only the `Read` tool. It cannot search the repo. Give exact file paths or embed the content/diff in the prompt. For read-only exploration, allow read-only search tools explicitly:

```powershell
$result = & $bridge -Cwd "." -Prompt $prompt -Tools "Read,Grep,Glob" | ConvertFrom-Json
```

For pasted or generated input, preserve line breaks:

```powershell
$diff = (git diff -- path/to/file) -join "`n"
$prompt = @"
Review this diff for correctness bugs and missing tests.
Return concise findings with severity and file references.

$diff
"@

$result = & $bridge -Cwd "." -Prompt $prompt | ConvertFrom-Json
```

Prefer the bridge over direct `claude -p` so output parsing and session handling stay consistent. Do not start `claude` without `-p` unless the user explicitly wants an interactive Claude Code session outside Codex.

## Output Envelope

The bridge returns one JSON envelope:

```json
{
  "success": true,
  "exit_code": 0,
  "session_id": "...",
  "agent_messages": "Claude's response",
  "stderr": "...",
  "structured_output": {},
  "error": "...",
  "raw": "..."
}
```

On failure, inspect `error`, `stderr`, and `raw`. `stderr` and `raw` may be truncated to keep the envelope manageable.

To continue a Claude conversation, pass the previous `session_id`:

```powershell
$sessionId = $result.session_id
$result = & $bridge -Cwd "." -SessionId $sessionId -Prompt "Now focus only on missing tests." | ConvertFrom-Json
```

Only resume with a `session_id` from a `success: true` envelope. After a timeout, retry the full prompt or use `-Continue` intentionally. Use `-SessionId` or `-Continue`, never both. The bridge rejects the combination.

For machine-readable answers, pass `-JsonSchema <schema>` with an inline JSON Schema string and read `structured_output`. `-JsonSchema` requires JSON or stream-json output.

## Timeouts And Long Jobs

The default timeout is 300 seconds. Raise it for implementation-sized tasks:

```powershell
$result = & $bridge -Cwd "." -Prompt $prompt -TimeoutSec 900 | ConvertFrom-Json
```

A timeout returns `success: false`, `exit_code: 124`, and any partial output in `raw`. Prefer `-OutputFormat stream-json` for long jobs so partial output is more likely to be salvageable on timeout.

Use `-MaxBudgetUsd <amount>` for cost-sensitive delegations, especially write-capable work. Use `-Bare` for scripted calls that should not load Claude hooks, skills, plugins, MCP servers, or local `CLAUDE.md`.

## Prompting Rules

Give Claude the smallest complete context that can answer the question. Include:

- The objective.
- Exact files, directories, diff, logs, or command output to inspect.
- Whether it may edit files.
- The expected output shape.
- Any user or repo constraints that matter.

Ask for summaries, not raw exploration logs. If using Claude for review, request findings first and require file references.

For code changes in the main working tree, ask Claude to return a unified diff only:

```text
OUTPUT: Unified Diff Patch ONLY.
Strictly prohibit actual file modification.
```

## Handling Results

After Claude returns:

1. Treat the result as advice, not ground truth.
2. Verify claims against local files, tests, or commands before acting on them.
3. Preserve the main Codex responsibility for final edits, tests, and user-facing conclusions.
4. Clearly attribute material conclusions that came from Claude when reporting them.

If Claude changes files, inspect the diff before continuing:

```powershell
git status --short
git diff
```

The preferred workflow is that Claude proposes changes and Codex applies them after verification. Avoid letting Claude edit the current working tree directly unless the user explicitly asked for it.

## Write Delegation

Without `-AllowWrites`, the bridge refuses any requested tool whose name begins with `Write`, `Edit`, `NotebookEdit`, or `Bash`, including scoped forms like `Bash(git log:*)`, and refuses `-PermissionMode bypassPermissions`.

`-AllowWrites` removes all default tool restrictions, including `Bash`; that is why the worktree isolation below matters.

For implementation work, prefer an isolated git worktree and keep Codex in the original workspace:

```powershell
git worktree add ../repo-claude-agent -b claude/<task-name>

$result = & $bridge -Cwd "../repo-claude-agent" `
    -Prompt "Implement <task>. Keep changes scoped. Run relevant tests and summarize changed files." `
    -AllowWrites `
    -PermissionMode acceptEdits `
    -TimeoutSec 900 `
    -MaxBudgetUsd "2.00" |
    ConvertFrom-Json

if (-not $result.success) {
    throw (($result.error, $result.stderr, $result.raw | Where-Object { $_ }) -join [Environment]::NewLine)
}
```

Then inspect the worktree diff from the main workspace and integrate only what you accept.
