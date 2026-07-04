---
name: claude-delegate
description: Delegate bounded coding, review, analysis, debugging, or second-opinion tasks to the local Claude Code CLI through the bundled PowerShell bridge script. Use when the user explicitly asks to use Claude, Claude Code, a Claude subagent, an independent second opinion, or external cross-checking through the `claude` command.
---

# Claude Delegate

Use the local `claude` command as an external, non-interactive reviewer or worker through `scripts/claude-bridge.ps1`. Treat Claude Code as a separate agent process: give it a bounded task, collect its answer, and integrate the useful result yourself.

## Preconditions

The bridge requires PowerShell 7+ and an authenticated Claude Code CLI. Before the first delegation in a session, verify the CLI is available:

```powershell
$PSVersionTable.PSVersion
Get-Command claude
claude --version
```

If `claude` is missing or unauthenticated, report that and do not emulate its answer.

## When To Delegate

Use the PowerShell bridge for bounded side tasks such as:

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

## Invocation Pattern

Resolve the bundled bridge from the installed skill location instead of hardcoding a user-specific path:

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

Run Claude from the directory that contains the relevant project context:

```powershell
$prompt = @'
You are acting as an independent coding agent.

Task:
<specific bounded task>

Scope:
<files, diff, command output, or directories to inspect>

Constraints:
- Do not modify files unless explicitly asked.
- Focus on actionable findings.
- Include file paths and line references where possible.
- Say when evidence is insufficient.

Return:
<desired format>
'@

& $bridge -Cwd "." -Prompt $prompt -OutputFormat json
```

The bridge sends the prompt to Claude over stdin rather than as a command-line argument. This avoids Windows argument-length limits, quoting bugs, and prompt exposure in process listings.

For pasted or generated input, embed it in the prompt after preserving line breaks:

```powershell
$bridge = Get-ClaudeDelegateBridge
$diff = (git diff -- path/to/file) -join "`n"
$prompt = @"
Review this diff for correctness bugs and missing tests.
Return concise findings with severity and file references.

$diff
"@
& $bridge -Cwd "." -Prompt $prompt -OutputFormat json
```

Prefer the bridge over direct `claude -p` so output parsing and session handling stay consistent. Do not start `claude` without `-p` unless the user explicitly wants an interactive Claude Code session outside Codex.

By default, the bridge runs Claude in a read-only posture: `--tools Read`, write-oriented tools disallowed, and `--permission-mode default`. Use `-AllowWrites` only when the user explicitly wants Claude to modify files or when running inside an isolated worktree.

Use `-OutputFormat stream-json` for long-running calls where session metadata matters. Use `-TimeoutSec <seconds>` for longer jobs. Use `-Bare` for scripted calls that should not load Claude hooks, skills, plugins, MCP servers, or local `CLAUDE.md`.

## Prompting Rules

Give Claude the smallest complete context that can answer the question. Include:

- The objective.
- The exact files, directories, diff, logs, or command output to inspect.
- Whether it may edit files.
- The expected output shape.
- Any constraints from the user or repo instructions that matter.

Ask for summaries, not raw exploration logs. If using Claude for review, request findings first and require file references.

For code changes, ask Claude to return a unified diff only:

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

## Safer Write Delegation

For implementation work, prefer an isolated git worktree:

```powershell
git worktree add ../repo-claude-agent -b claude/<task-name>
Set-Location ../repo-claude-agent
$bridge = Get-ClaudeDelegateBridge
& $bridge -Cwd "." -Prompt "Implement <task>. Keep changes scoped. Run relevant tests and summarize changed files." -OutputFormat json -AllowWrites -PermissionMode acceptEdits -TimeoutSec 900
```

Then return to the original workspace, inspect the worktree diff, and integrate only the parts you accept.
