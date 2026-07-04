#Requires -Version 7.0

param(
    [Parameter(Mandatory = $false)]
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

    [switch]$Check,

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

function Limit-Text {
    param(
        [string]$Text,
        [int]$MaxChars = 8192
    )
    if (-not $Text -or $Text.Length -le $MaxChars) {
        return $Text
    }
    $omitted = $Text.Length - $MaxChars
    return "[truncated $omitted chars]`n" + $Text.Substring($Text.Length - $MaxChars)
}

function Get-ClaudeLaunch {
    $commands = @(Get-Command claude -All -ErrorAction SilentlyContinue)
    if ($commands.Count -eq 0) {
        return $null
    }

    $preferred = @()
    $preferred += @($commands | Where-Object { $_.Source -match '\.exe$' })
    $preferred += @($commands | Where-Object { $_.Source -match '\.(cmd|bat)$' })
    $preferred += @($commands | Where-Object { $_.Source -match '\.ps1$' })
    $preferred += @($commands)

    $command = $preferred | Where-Object { $_ } | Select-Object -First 1
    $source = $command.Source

    if ($source -match '\.ps1$') {
        return @{
            FileName = "pwsh"
            PrefixArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $source)
            Source = $source
        }
    }

    if ($source -match '\.(cmd|bat)$') {
        $comspec = if ($env:ComSpec) { $env:ComSpec } else { "cmd.exe" }
        return @{
            FileName = $comspec
            PrefixArgs = @("/d", "/s", "/c", "`"$source`"")
            Source = $source
        }
    }

    return @{
        FileName = $source
        PrefixArgs = @()
        Source = $source
    }
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

if (-not $Check -and -not $Prompt) {
    Exit-WithJson @{
        success = $false
        error = "Prompt is required unless -Check is specified."
    } 2
}

if ($SessionId -and $Continue) {
    Exit-WithJson @{
        success = $false
        error = "Use either -SessionId or -Continue, not both."
    } 2
}

if ($JsonSchema -and $OutputFormat -eq "text") {
    Exit-WithJson @{
        success = $false
        error = "-JsonSchema requires -OutputFormat json or -OutputFormat stream-json."
    } 2
}

if ($MaxBudgetUsd) {
    $budgetValue = 0.0
    if (-not [double]::TryParse($MaxBudgetUsd, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$budgetValue) -or $budgetValue -le 0) {
        Exit-WithJson @{
            success = $false
            error = "-MaxBudgetUsd must be a positive invariant-culture number, such as 0.50."
        } 2
    }
}

if (-not $AllowWrites -and $PermissionMode -eq "bypassPermissions") {
    Exit-WithJson @{
        success = $false
        error = "Refusing -PermissionMode bypassPermissions without -AllowWrites."
    } 2
}

$writeToolNames = @("write", "edit", "notebookedit", "bash")
if (-not $AllowWrites) {
    $requestedTools = @()
    if ($Tools) {
        $requestedTools += ($Tools -split '[,\s]+' | Where-Object { $_ })
    }
    foreach ($toolEntry in $AllowedTools) {
        if ($toolEntry) {
            $requestedTools += ($toolEntry -split '[,\s]+' | Where-Object { $_ })
        }
    }

    foreach ($requestedTool in $requestedTools) {
        $toolName = ([string]$requestedTool).Trim()
        foreach ($writeToolName in $writeToolNames) {
            if ($toolName.ToLowerInvariant().StartsWith($writeToolName)) {
                Exit-WithJson @{
                    success = $false
                    error = "Refusing tool '$toolName' without -AllowWrites."
                } 2
            }
        }
    }
}

$claudeLaunch = Get-ClaudeLaunch
if (-not $claudeLaunch) {
    Exit-WithJson @{
        success = $false
        error = "The 'claude' command is not available on PATH."
    } 127
}

if ($Check) {
    $versionPsi = [System.Diagnostics.ProcessStartInfo]::new()
    $versionPsi.FileName = $claudeLaunch.FileName
    $versionPsi.UseShellExecute = $false
    $versionPsi.RedirectStandardOutput = $true
    $versionPsi.RedirectStandardError = $true
    $versionPsi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $versionPsi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    foreach ($arg in $claudeLaunch.PrefixArgs) {
        [void]$versionPsi.ArgumentList.Add($arg)
    }
    [void]$versionPsi.ArgumentList.Add("--version")

    $versionProcess = [System.Diagnostics.Process]::new()
    $versionProcess.StartInfo = $versionPsi
    try {
        [void]$versionProcess.Start()
        $versionStdoutTask = $versionProcess.StandardOutput.ReadToEndAsync()
        $versionStderrTask = $versionProcess.StandardError.ReadToEndAsync()
        if (-not $versionProcess.WaitForExit([Math]::Min($TimeoutSec * 1000, 30000))) {
            $versionProcess.Kill($true)
            $versionProcess.WaitForExit(5000) | Out-Null
        }
        $versionStdout = $versionStdoutTask.GetAwaiter().GetResult()
        $versionStderr = $versionStderrTask.GetAwaiter().GetResult()
        $checkExitCode = if ($versionProcess.ExitCode -eq 0) { 0 } else { $versionProcess.ExitCode }
        Exit-WithJson @{
            success = ($versionProcess.ExitCode -eq 0)
            pwsh_version = $PSVersionTable.PSVersion.ToString()
            claude_path = $claudeLaunch.Source
            claude_version = $versionStdout.Trim()
            stderr = (Limit-Text $versionStderr.Trim())
            exit_code = $versionProcess.ExitCode
        } $checkExitCode
    }
    catch {
        Exit-WithJson @{
            success = $false
            pwsh_version = $PSVersionTable.PSVersion.ToString()
            claude_path = $claudeLaunch.Source
            error = "Failed to run Claude Code version check: $($_.Exception.Message)"
        } 1
    }
    finally {
        $versionProcess.Dispose()
    }
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
    $DisallowedTools = @($DisallowedTools + @("Write", "Edit", "NotebookEdit", "Bash") | Select-Object -Unique)
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
$psi.FileName = $claudeLaunch.FileName
$psi.WorkingDirectory = $resolvedCwd.Path
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
$psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
$psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
foreach ($arg in $claudeLaunch.PrefixArgs) {
    [void]$psi.ArgumentList.Add($arg)
}
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
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$timeoutMs = $TimeoutSec * 1000
$inputTask = $process.StandardInput.WriteAsync($Prompt)
$remainingMs = [Math]::Max(1, $timeoutMs - [int]$stopwatch.ElapsedMilliseconds)
if (-not $inputTask.Wait($remainingMs)) {
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
    $process.WaitForExit(5000) | Out-Null
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $process.Dispose()
    Exit-WithJson @{
        success = $false
        exit_code = 124
        session_id = $null
        agent_messages = ""
        stderr = (Limit-Text $stderr.Trim())
        error = "Claude Code timed out while receiving the prompt after $TimeoutSec seconds."
        raw = (Limit-Text $stdout)
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

$remainingMs = [Math]::Max(1, $timeoutMs - [int]$stopwatch.ElapsedMilliseconds)
if (-not $waitTask.Wait($remainingMs)) {
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
    $process.WaitForExit(5000) | Out-Null
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $process.Dispose()
    Exit-WithJson @{
        success = $false
        exit_code = 124
        session_id = $null
        agent_messages = ""
        stderr = (Limit-Text $stderr.Trim())
        error = "Claude Code timed out after $TimeoutSec seconds."
        raw = (Limit-Text $stdout)
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
    $result.stderr = Limit-Text $stderr.Trim()
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
        $unsupportedFlagMatch = [regex]::Match($stderr, '(?i)(unknown|unrecognized|invalid).{0,80}(--[A-Za-z0-9][A-Za-z0-9-]*)')
        if ($unsupportedFlagMatch.Success) {
            $errorParts += "Installed Claude Code CLI may not support '$($unsupportedFlagMatch.Groups[2].Value)'; upgrade Claude Code or omit the corresponding bridge parameter."
        }
        $errorParts += "Claude Code exited with status $exitCode."
    }
    if ($inputError) {
        $errorParts += "Failed to write prompt to Claude Code stdin: $inputError"
    }
    $result.error = ($errorParts -join [Environment]::NewLine).Trim()
    $result.raw = Limit-Text $stdout
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
