#Requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string]$Prompt,

    [string]$Cwd = ".",

    [ValidateSet("text", "json", "stream-json")]
    [string]$OutputFormat = "json",

    [string]$SessionId = "",

    [switch]$Continue,

    [switch]$NoSessionPersistence,

    [string]$Model = "",

    [string]$FallbackModel = "",

    [string]$MaxBudgetUsd = "",

    [string]$JsonSchema = "",

    [string[]]$AllowedTools = @(),

    [string[]]$DisallowedTools = @(),

    [string]$Tools = "",

    [ValidateSet("", "default", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions")]
    [string]$PermissionMode = "",

    [switch]$AllowWrites,

    [switch]$Bare,

    [int]$TimeoutSec = 300,

    [switch]$Help
)

$ErrorActionPreference = "Stop"
try {
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
}
catch {
    # Codex may run this script with fully redirected stdio and no console handle.
}
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if ($Help) {
    @"
Claude Code PowerShell bridge for Codex skills.

Examples:
  .\claude-bridge.ps1 -Cwd . -Prompt "Review src/auth.ts for bugs" -OutputFormat json
  .\claude-bridge.ps1 -Cwd . -SessionId <id> -Prompt "Now propose a minimal patch as unified diff only"
  .\claude-bridge.ps1 -Cwd . -Prompt "Implement in an isolated worktree" -AllowWrites -PermissionMode acceptEdits

Defaults:
  Prompts are sent over stdin, not command-line arguments.
  Without -AllowWrites, Claude runs with --tools Read, disallowed write tools, and --permission-mode default.

Returns:
  JSON with success, session_id, agent_messages, exit_code, stderr, and optional error/raw/structured_output.
"@
    exit 0
}

function ConvertTo-BridgeJson {
    param([hashtable]$Value)
    $Value | ConvertTo-Json -Depth 30
}

function Exit-WithJson {
    param(
        [hashtable]$Value,
        [int]$Code
    )
    ConvertTo-BridgeJson $Value
    exit $Code
}

function Has-Prop {
    param(
        [object]$Node,
        [string]$Name
    )
    return ($null -ne $Node -and $Node -is [pscustomobject] -and $Node.PSObject.Properties.Name -contains $Name)
}

function Get-TextFromNode {
    param([object]$Node)

    if ($null -eq $Node) {
        return ""
    }

    if ($Node -is [string]) {
        return $Node
    }

    if ($Node -is [System.Array]) {
        $parts = foreach ($item in $Node) {
            Get-TextFromNode -Node $item
        }
        return ($parts -join "")
    }

    if ($Node -is [pscustomobject]) {
        foreach ($name in @("text", "result")) {
            if (Has-Prop $Node $name) {
                $value = $Node.$name
                if ($value -is [string]) {
                    return $value
                }
            }
        }

        foreach ($name in @("content", "delta", "message")) {
            if (Has-Prop $Node $name) {
                $text = Get-TextFromNode -Node $Node.$name
                if ($text) {
                    return $text
                }
            }
        }
    }

    return ""
}

if ($TimeoutSec -lt 1) {
    Exit-WithJson @{
        success = $false
        error = "TimeoutSec must be greater than zero."
    } 2
}

if ($SessionId -and $Continue) {
    Exit-WithJson @{
        success = $false
        error = "Use either -SessionId or -Continue, not both."
    } 2
}

if (-not $AllowWrites -and $PermissionMode -eq "bypassPermissions") {
    Exit-WithJson @{
        success = $false
        error = "Refusing -PermissionMode bypassPermissions without -AllowWrites."
    } 2
}

$claude = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claude) {
    Exit-WithJson @{
        success = $false
        error = "The 'claude' command is not available on PATH."
    } 127
}

$resolvedCwd = Resolve-Path -LiteralPath $Cwd -ErrorAction SilentlyContinue
if (-not $resolvedCwd) {
    Exit-WithJson @{
        success = $false
        error = "The working directory '$Cwd' does not exist."
    } 2
}

if (-not $AllowWrites) {
    if (-not $Tools -and $AllowedTools.Count -eq 0) {
        $Tools = "Read"
    }
    if ($DisallowedTools.Count -eq 0) {
        $DisallowedTools = @("Write,Edit,NotebookEdit,Bash")
    }
    if (-not $PermissionMode) {
        $PermissionMode = "default"
    }
}

$argsList = [System.Collections.Generic.List[string]]::new()
if ($Bare) {
    $argsList.Add("--bare")
}
$argsList.Add("--print")
$argsList.Add("--output-format")
$argsList.Add($OutputFormat)

if ($OutputFormat -eq "stream-json") {
    $argsList.Add("--verbose")
}
if ($SessionId) {
    $argsList.Add("--resume")
    $argsList.Add($SessionId)
}
if ($Continue) {
    $argsList.Add("--continue")
}
if ($NoSessionPersistence) {
    $argsList.Add("--no-session-persistence")
}
if ($Model) {
    $argsList.Add("--model")
    $argsList.Add($Model)
}
if ($FallbackModel) {
    $argsList.Add("--fallback-model")
    $argsList.Add($FallbackModel)
}
if ($MaxBudgetUsd) {
    $argsList.Add("--max-budget-usd")
    $argsList.Add($MaxBudgetUsd)
}
if ($JsonSchema) {
    $argsList.Add("--json-schema")
    $argsList.Add($JsonSchema)
}
$allowedToolList = @($AllowedTools | Where-Object { $_ })
if ($allowedToolList.Count -gt 0) {
    $argsList.Add("--allowedTools")
    $argsList.Add(($allowedToolList -join ","))
}
$disallowedToolList = @($DisallowedTools | Where-Object { $_ })
if ($disallowedToolList.Count -gt 0) {
    $argsList.Add("--disallowedTools")
    $argsList.Add(($disallowedToolList -join ","))
}
if ($Tools) {
    $argsList.Add("--tools")
    $argsList.Add($Tools)
}
if ($PermissionMode) {
    $argsList.Add("--permission-mode")
    $argsList.Add($PermissionMode)
}

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $claude.Source
$psi.WorkingDirectory = $resolvedCwd.Path
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
$psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
$psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
foreach ($arg in $argsList) {
    [void]$psi.ArgumentList.Add($arg)
}

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $psi

try {
    [void]$process.Start()
}
catch {
    Exit-WithJson @{
        success = $false
        exit_code = 1
        session_id = $null
        agent_messages = ""
        stderr = ""
        error = "Failed to run Claude Code: $($_.Exception.Message)"
    } 1
}

$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
$inputTask = $process.StandardInput.WriteAsync($Prompt)
if (-not $inputTask.Wait($TimeoutSec * 1000)) {
    try {
        $process.Kill($true)
    }
    catch {
        try {
            $process.Kill()
        }
        catch {
        }
    }
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $process.Dispose()
    Exit-WithJson @{
        success = $false
        exit_code = 124
        session_id = $null
        agent_messages = ""
        stderr = $stderr.Trim()
        error = "Claude Code timed out while receiving the prompt after $TimeoutSec seconds."
        raw = $stdout
    } 124
}
$inputError = $null
try {
    $null = $inputTask.GetAwaiter().GetResult()
}
catch {
    $inputError = $_.Exception.Message
}
try {
    $process.StandardInput.Close()
}
catch {
}
$waitTask = $process.WaitForExitAsync()

if (-not $waitTask.Wait($TimeoutSec * 1000)) {
    try {
        $process.Kill($true)
    }
    catch {
        try {
            $process.Kill()
        }
        catch {
        }
    }
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $process.Dispose()
    Exit-WithJson @{
        success = $false
        exit_code = 124
        session_id = $null
        agent_messages = ""
        stderr = $stderr.Trim()
        error = "Claude Code timed out after $TimeoutSec seconds."
        raw = $stdout
    } 124
}

$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderr = $stderrTask.GetAwaiter().GetResult()
$exitCode = $process.ExitCode

$process.Dispose()

$lines = @($stdout -split "\r?\n" | Where-Object { $_ -ne "" })
$sessionIdOut = $null
$agentMessages = ""
$structuredOutput = $null
$isError = $false
$parseErrors = @()

if ($OutputFormat -eq "text") {
    $agentMessages = $stdout.Trim()
}
elseif ($OutputFormat -eq "json") {
    $rawText = $stdout.Trim()
    try {
        $obj = $rawText | ConvertFrom-Json -ErrorAction Stop
        if (Has-Prop $obj "session_id") {
            $sessionIdOut = $obj.session_id
        }
        if ((Has-Prop $obj "is_error") -and $obj.is_error) {
            $isError = $true
        }
        if ((Has-Prop $obj "subtype") -and ([string]$obj.subtype).ToLowerInvariant().Contains("error")) {
            $isError = $true
        }
        if (Has-Prop $obj "structured_output") {
            $structuredOutput = $obj.structured_output
        }
        $agentMessages = Get-TextFromNode -Node $obj
    }
    catch {
        $parseErrors += "Failed to parse JSON output: $($_.Exception.Message)"
        $agentMessages = $rawText
    }
}
else {
    $assistantParts = [System.Collections.Generic.List[string]]::new()
    $finalResult = ""
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed) {
            continue
        }

        try {
            $obj = $trimmed | ConvertFrom-Json -ErrorAction Stop
            if ((Has-Prop $obj "session_id") -and $obj.session_id) {
                $sessionIdOut = $obj.session_id
            }
            if ((Has-Prop $obj "is_error") -and $obj.is_error) {
                $isError = $true
            }

            if ((Has-Prop $obj "type") -and $obj.type -eq "result") {
                if ((Has-Prop $obj "subtype") -and ([string]$obj.subtype).ToLowerInvariant().Contains("error")) {
                    $isError = $true
                }
                if (Has-Prop $obj "structured_output") {
                    $structuredOutput = $obj.structured_output
                }
                $finalResult = Get-TextFromNode -Node $obj
                continue
            }

            $role = $null
            if (Has-Prop $obj "role") {
                $role = $obj.role
            }
            if ((Has-Prop $obj "message") -and (Has-Prop $obj.message "role")) {
                $role = $obj.message.role
            }

            $isDelta = $false
            if (Has-Prop $obj "delta") {
                $isDelta = $true
            }
            if ((Has-Prop $obj "type") -and ([string]$obj.type).EndsWith("_delta")) {
                $isDelta = $true
            }

            if ($role -eq "assistant" -or $isDelta) {
                $text = Get-TextFromNode -Node $obj
                if ($text) {
                    $assistantParts.Add($text)
                }
            }
        }
        catch {
            $parseErrors += "Failed to parse stream JSON line: $trimmed"
        }
    }

    if ($finalResult) {
        $agentMessages = $finalResult
    }
    else {
        $agentMessages = ($assistantParts -join [Environment]::NewLine)
    }
}

$success = ($exitCode -eq 0 -and $parseErrors.Count -eq 0 -and -not $isError -and -not $inputError)
$result = @{
    success = $success
    exit_code = $exitCode
    session_id = $sessionIdOut
    agent_messages = $agentMessages.Trim()
}

if ($stderr.Trim()) {
    $result.stderr = $stderr.Trim()
}

if ($null -ne $structuredOutput) {
    $result.structured_output = $structuredOutput
}

if (-not $success) {
    $errorParts = @()
    if ($parseErrors.Count -gt 0) {
        $errorParts += $parseErrors
    }
    if ($isError) {
        $errorParts += "Claude Code reported an error result."
    }
    if ($exitCode -ne 0) {
        $errorParts += "Claude Code exited with status $exitCode."
    }
    if ($inputError) {
        $errorParts += "Failed to write prompt to Claude Code stdin: $inputError"
    }
    $result.error = ($errorParts -join [Environment]::NewLine).Trim()
    $result.raw = $stdout
}

ConvertTo-BridgeJson $result
if ($success) {
    exit 0
}
elseif ($exitCode -ne 0) {
    exit $exitCode
}
else {
    exit 1
}
