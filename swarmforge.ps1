[CmdletBinding()]
param(
    [string]$WorkingDir = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SessionPrefix = 'swarmforge'

$Red = "`e[0;31m"
$Green = "`e[0;32m"
$Yellow = "`e[1;33m"
$Cyan = "`e[0;36m"
$Bold = "`e[1m"
$Reset = "`e[0m"

$WorkingDir = (Resolve-Path -LiteralPath $WorkingDir).Path
$ScriptDir = Split-Path -Parent $PSCommandPath
$SwarmForgeDir = Join-Path $WorkingDir 'swarmforge'
$SwarmToolsDir = Join-Path $WorkingDir 'swarmtools'
$WorktreesDir = Join-Path $WorkingDir '.worktrees'
$ConfigFile = Join-Path $SwarmForgeDir 'swarmforge.conf'
$RolesDir = $SwarmForgeDir
$ConstitutionFile = Join-Path $SwarmForgeDir 'constitution.prompt'
$StateDir = Join-Path $WorkingDir '.swarmforge'
$SessionsFile = Join-Path $StateDir 'sessions.tsv'
$PromptsDir = Join-Path $StateDir 'prompts'
$LaunchScriptsDir = Join-Path $StateDir 'launchers'

$script:Entries = [System.Collections.Generic.List[object]]::new()
$script:RoleIndex = @{}
$script:WorktreeIndex = @{}
$script:CleanupOwnerIndex = 1
$script:BashExecutable = 'bash'
$script:UseWslTmux = $false
$script:TmuxExecutable = $null
$script:TextInfo = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo

$SwarmWindowName = 'swarm'

$workingDirName = Split-Path -Leaf $WorkingDir
if ([string]::IsNullOrWhiteSpace($workingDirName)) {
    $workingDirName = 'swarm'
}

$sanitizedWorkingDirName = ($workingDirName -replace '[^A-Za-z0-9_-]', '-').Trim('-')
if ([string]::IsNullOrWhiteSpace($sanitizedWorkingDirName)) {
    $sanitizedWorkingDirName = 'swarm'
}

$script:SwarmSessionName = "$SessionPrefix-$sanitizedWorkingDirName"

function Has-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Check-Dependency {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Has-Command $Name)) {
        throw "'$Name' is required but not installed."
    }
}

function Initialize-TmuxCommand {
    if (Has-Command 'tmux') {
        $script:TmuxExecutable = (Get-Command 'tmux' -ErrorAction SilentlyContinue).Source
        return
    }

    if (Has-Command 'wsl') {
        try {
            & wsl tmux -V *> $null
            if ($LASTEXITCODE -eq 0) {
                $script:UseWslTmux = $true
                return
            }
        } catch {
        }
    }

    throw "'tmux' is required but not installed."
}

function Invoke-Tmux {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    if ($script:UseWslTmux) {
        & wsl tmux @Arguments
    } else {
        & tmux @Arguments
    }
}

function Check-BackendDependency {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($script:UseWslTmux) {
        & wsl bash -lc "command -v $Name >/dev/null 2>&1"
        if ($LASTEXITCODE -ne 0) {
            throw "'$Name' is required in the tmux environment (WSL) but was not found."
        }
        return
    }

    Check-Dependency $Name
}

function Get-PreferredPowerShellExecutable {
    foreach ($candidate in @('powershell', 'pwsh')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    return $null
}

function Get-ShellPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($script:UseWslTmux -and (Has-Command 'wsl')) {
        try {
            $converted = (& wsl wslpath -a $Path 2>$null | Select-Object -First 1)
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($converted)) {
                return $converted.Trim()
            }
        } catch {
        }
    }

    return ($Path -replace '\\', '/')
}

function ConvertTo-PosixSingleQuotedLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)

    return "'" + ($Value -replace "'", "'`"'`"'") + "'"
}

function ConvertTo-PowerShellSingleQuotedLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function ConvertTo-EncodedPowerShellCommand {
    param([Parameter(Mandatory = $true)][string]$Command)

    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
}

function Wrap-InLaunchShell {
    param([Parameter(Mandatory = $true)][string]$Command)

    return "bash -lc $(ConvertTo-PosixSingleQuotedLiteral $Command)"
}

function Get-CleanupCommand {
    $sessionName = ConvertTo-PowerShellSingleQuotedLiteral $script:SwarmSessionName

    $cleanupPs1 = Join-Path $ScriptDir 'swarm-cleanup.ps1'
    if (Test-Path -LiteralPath $cleanupPs1) {
        $powerShellExe = Get-PreferredPowerShellExecutable
        if ([string]::IsNullOrWhiteSpace($powerShellExe)) {
            throw 'A PowerShell executable is required to launch swarm-cleanup.ps1.'
        }

        return "Start-Process -WindowStyle Hidden -FilePath {0} -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', {1}, {2}) | Out-Null" -f `
            (ConvertTo-PowerShellSingleQuotedLiteral $powerShellExe),
            (ConvertTo-PowerShellSingleQuotedLiteral $cleanupPs1),
            $sessionName
    }

    $cleanupSh = Join-Path $ScriptDir 'swarm-cleanup.sh'
    if (-not (Test-Path -LiteralPath $cleanupSh)) {
        throw 'Neither swarm-cleanup.ps1 nor swarm-cleanup.sh was found.'
    }

    $bashExecutable = (Get-Command 'bash' -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($bashExecutable)) {
        throw 'bash is required to launch swarm-cleanup.sh.'
    }

    return "Start-Process -WindowStyle Hidden -FilePath {0} -ArgumentList @({1}) | Out-Null" -f `
        (ConvertTo-PowerShellSingleQuotedLiteral $bashExecutable),
        ((@(
                    (ConvertTo-PowerShellSingleQuotedLiteral $cleanupSh),
                    $sessionName
                )) -join ', ')
}

function Ensure-InitialGitignore {
    $gitignoreFile = Join-Path $WorkingDir '.gitignore'
    $requiredEntries = @(
        '.swarmforge/'
        '.worktrees/'
        'swarmtools/'
        'logs/'
        'agent_context/'
    )

    if (-not (Test-Path -LiteralPath $gitignoreFile)) {
        Set-Content -LiteralPath $gitignoreFile -Value $requiredEntries -Encoding utf8
        return
    }

    $existing = Get-Content -LiteralPath $gitignoreFile
    foreach ($entry in $requiredEntries) {
        if ($existing -notcontains $entry) {
            Add-Content -LiteralPath $gitignoreFile -Value $entry
        }
    }
}

function Initialize-GitRepo {
    $gitDir = Join-Path $WorkingDir '.git'
    if (Test-Path -LiteralPath $gitDir) {
        return
    }

    & git init $WorkingDir *> $null
    & git -C $WorkingDir branch -M master *> $null
    Ensure-InitialGitignore
    & git -C $WorkingDir add . *> $null
    & git -C $WorkingDir commit -m 'Initial swarmforge repository' *> $null
}

function Display-NameForRole {
    param([Parameter(Mandatory = $true)][string]$Role)

    $parts = (($Role -replace '[-_]', ' ') -split '\s+') | Where-Object { $_ }
    $labelParts = foreach ($part in $parts) {
        $script:TextInfo.ToTitleCase($part.ToLowerInvariant())
    }

    return ($labelParts -join ' ')
}

function Worktree-PathForName {
    param([Parameter(Mandatory = $true)][string]$Name)
    return (Join-Path $WorktreesDir $Name)
}

function Parse-Config {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw "Config not found at $ConfigFile"
    }

    if (-not (Test-Path -LiteralPath $ConstitutionFile)) {
        throw "Constitution prompt not found at $ConstitutionFile"
    }

    $lineNo = 0
    foreach ($rawLine in Get-Content -LiteralPath $ConfigFile) {
        $lineNo++
        $line = $rawLine.Trim()

        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }

        $fields = $line -split '\s+'
        if ($fields.Count -ne 4) {
            throw "Invalid config line ${lineNo}: $line"
        }

        $keyword = $fields[0]
        $role = $fields[1]
        $agent = $fields[2].ToLowerInvariant()
        $worktree = $fields[3]

        if ($keyword -ne 'window') {
            throw "Unknown config directive on line ${lineNo}: $keyword"
        }

        if ($script:RoleIndex.ContainsKey($role)) {
            throw "Duplicate role '$role' in $ConfigFile"
        }

        if (($worktree -ne 'none') -and ($worktree -ne 'master') -and $script:WorktreeIndex.ContainsKey($worktree)) {
            throw "Duplicate worktree '$worktree' in $ConfigFile"
        }

        if ($worktree.Contains('/') -or $worktree.Contains('\') -or $worktree -eq '.' -or $worktree -eq '..') {
            throw "Invalid worktree '$worktree' for role '$role'"
        }

        switch ($agent) {
            'claude' { }
            'codex' { }
            'none' { }
            default { throw "Unsupported agent '$agent' for role '$role'" }
        }

        $rolePrompt = Join-Path $RolesDir "$role.prompt"
        if (($agent -ne 'none') -and -not (Test-Path -LiteralPath $rolePrompt)) {
            throw "Missing role prompt $rolePrompt"
        }

        $index = $script:Entries.Count + 1
        $displayName = Display-NameForRole $role
        $session = $script:SwarmSessionName
        $windowName = $SwarmWindowName
        $paneIndex = $index - 1
        $worktreePath = if ($worktree -in @('none', 'master')) { $WorkingDir } else { Worktree-PathForName $worktree }

        $script:RoleIndex[$role] = $index
        if ($worktree -notin @('none', 'master')) {
            $script:WorktreeIndex[$worktree] = $index
        }

        $null = $script:Entries.Add([pscustomobject]@{
                Index       = $index
                Role        = $role
                Agent       = $agent
                Session     = $session
                Window      = $windowName
                Pane        = $paneIndex
                DisplayName = $displayName
                Worktree    = $worktree
                WorktreePath = $worktreePath
            })
    }

    if ($script:Entries.Count -eq 0) {
        throw "No windows defined in $ConfigFile"
    }
}

function Write-SessionsFile {
    $tab = [char]9
    $lines = foreach ($entry in $script:Entries) {
        [string]::Join($tab, @(
                [string]$entry.Index
                [string]$entry.Role
                [string]$entry.Session
                [string]$entry.Window
                [string]$entry.Pane
                [string]$entry.DisplayName
                [string]$entry.Agent
            ))
    }

    Set-Content -LiteralPath $SessionsFile -Value $lines -Encoding utf8
}

function Check-HelperScripts {
    $cleanupAvailable = (Test-Path -LiteralPath (Join-Path $ScriptDir 'swarm-cleanup.ps1')) -or (Test-Path -LiteralPath (Join-Path $ScriptDir 'swarm-cleanup.sh'))
    if (-not $cleanupAvailable) {
        throw "Required cleanup helper not found in $ScriptDir"
    }

    $logAvailable = (Test-Path -LiteralPath (Join-Path $ScriptDir 'swarmlog.ps1')) -or (Test-Path -LiteralPath (Join-Path $ScriptDir 'swarmlog.sh'))
    if (-not $logAvailable) {
        throw "Required log helper not found in $ScriptDir"
    }
}

function Write-NotifyScript {
    $notifyScript = @'
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Target,

    [Parameter(Position = 1, Mandatory = $true, ValueFromRemainingArguments = $true)]
    [string[]]$MessageParts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Has-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Find-ProjectRoot {
    $candidates = [System.Collections.Generic.List[string]]::new()

    foreach ($path in @(
            (Get-Location).Path,
            (Split-Path -Parent $PSScriptRoot),
            $PSScriptRoot
        )) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        try {
            $resolved = (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
        } catch {
            continue
        }

        if (-not $candidates.Contains($resolved)) {
            $null = $candidates.Add($resolved)
        }
    }

    foreach ($candidate in $candidates) {
        $current = $candidate
        while (-not [string]::IsNullOrWhiteSpace($current)) {
            if (Test-Path -LiteralPath (Join-Path $current '.swarmforge\sessions.tsv')) {
                return $current
            }

            $parent = Split-Path -Parent $current
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
                break
            }

            $current = $parent
        }
    }

    return $null
}

$script:UseWslTmux = $false

function Initialize-TmuxCommand {
    if (Has-Command 'tmux') {
        $script:TmuxExecutable = (Get-Command 'tmux' -ErrorAction SilentlyContinue).Source
        return
    }

    if (Has-Command 'wsl') {
        try {
            & wsl tmux -V *> $null
            if ($LASTEXITCODE -eq 0) {
                $script:UseWslTmux = $true
                return
            }
        } catch {
        }
    }

    throw "'tmux' is required but not installed."
}

function Invoke-Tmux {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    if ($script:UseWslTmux) {
        & wsl tmux @Arguments
    } else {
        & tmux @Arguments
    }
}

function Resolve-Target {
    param([Parameter(Mandatory = $true)][string]$LookupTarget)

    $normalizedTarget = $LookupTarget.ToLowerInvariant()

    foreach ($line in Get-Content -LiteralPath $SessionsFile) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $fields = $line -split "`t"
        if ($fields.Count -lt 5) {
            continue
        }

        $index = $fields[0]
        $role = $fields[1]
        $session = $fields[2]
        $window = if ($fields.Count -ge 7) { $fields[3] } else { '0' }
        $pane = if ($fields.Count -ge 7) { $fields[4] } else { '0' }
        $label = if ($fields.Count -ge 7) { "$session`:$window.$pane" } else { $session }

        if ($normalizedTarget -eq $index.ToLowerInvariant() -or $normalizedTarget -eq $role.ToLowerInvariant()) {
            return [pscustomobject]@{
                Session = $session
                Window = $window
                Pane = $pane
                Label = $label
            }
        }
    }

    return $null
}

Initialize-TmuxCommand

$RootDir = Find-ProjectRoot
if ([string]::IsNullOrWhiteSpace($RootDir)) {
    Write-Error 'Could not find the SwarmForge project root containing .swarmforge\sessions.tsv.'
    exit 1
}

$SessionsFile = Join-Path $RootDir '.swarmforge\sessions.tsv'
$LogFile = Join-Path $RootDir 'logs\agent_messages.log'

if (-not (Test-Path -LiteralPath $SessionsFile)) {
    Write-Error "Sessions file not found: $SessionsFile"
    exit 1
}

$TargetTarget = Resolve-Target -LookupTarget $Target
if ($null -eq $TargetTarget) {
    Write-Error "Unknown target: $Target"
    exit 1
}

$Message = $MessageParts -join ' '
$Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null
Add-Content -LiteralPath $LogFile -Value "[$Timestamp] [$($TargetTarget.Label)] $Message"

Invoke-Tmux send-keys -t "$($TargetTarget.Session)`:$($TargetTarget.Window).$($TargetTarget.Pane)" -l -- $Message
Start-Sleep -Milliseconds 150
Invoke-Tmux send-keys -t "$($TargetTarget.Session)`:$($TargetTarget.Window).$($TargetTarget.Pane)" C-m
Start-Sleep -Milliseconds 50
Invoke-Tmux send-keys -t "$($TargetTarget.Session)`:$($TargetTarget.Window).$($TargetTarget.Pane)" C-j
'@

    $notifyScriptPath = Join-Path $SwarmToolsDir 'notify-agent.ps1'
    Set-Content -LiteralPath $notifyScriptPath -Value $notifyScript -Encoding utf8
}

function Prepare-Workspace {
    foreach ($path in @(
            (Join-Path $WorkingDir 'logs')
            (Join-Path $WorkingDir 'agent_context')
            (Join-Path $WorkingDir 'features')
            $StateDir
            $PromptsDir
            $LaunchScriptsDir
            $SwarmToolsDir
            $WorktreesDir
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }

    Check-HelperScripts
    Write-SessionsFile
    Write-NotifyScript
}

function Prepare-Worktrees {
    foreach ($entry in $script:Entries) {
        $worktreeName = $entry.Worktree
        $worktreePath = $entry.WorktreePath
        $branchName = "swarmforge-$worktreeName"

        if ($worktreeName -in @('none', 'master')) {
            continue
        }

        $worktreeGit = Join-Path $worktreePath '.git'
        if (Test-Path -LiteralPath $worktreeGit) {
            continue
        }

        & git -C $WorkingDir worktree add --force -B $branchName $worktreePath HEAD *> $null
    }
}

function Check-BackendDependencies {
    foreach ($entry in $script:Entries) {
        switch ($entry.Agent) {
            'claude' { Check-BackendDependency 'claude' }
            'codex' { Check-BackendDependency 'codex' }
        }
    }
}

function Create-RolePane {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$Window,
        [Parameter(Mandatory = $true)][bool]$IsFirstWindow,
        [string[]]$InitialCommand = @()
    )

    if ($IsFirstWindow) {
        if ($InitialCommand.Count -gt 0) {
            Invoke-Tmux new-session -d -s $Session -n $Window -- @InitialCommand *> $null
        } else {
            Invoke-Tmux new-session -d -s $Session -n $Window *> $null
        }

        # Keep exited agent panes visible so startup failures are observable.
        Invoke-Tmux set-option -t $Session remain-on-exit on *> $null
        Invoke-Tmux set-option -t $Session automatic-rename off *> $null
        Invoke-Tmux set-window-option -t "$Session`:$Window" pane-border-status top *> $null
        return
    }

    if ($InitialCommand.Count -gt 0) {
        Invoke-Tmux split-window -d -t "$Session`:$Window" -- @InitialCommand *> $null
    } else {
        Invoke-Tmux split-window -d -t "$Session`:$Window" *> $null
    }

    Invoke-Tmux select-layout -t "$Session`:$Window" tiled *> $null
}

function Write-AgentInstructionFile {
    param(
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$PromptFile
    )

    $content = @"
Read swarmforge/constitution.prompt, then read every file it refers to recursively, and obey all of those instructions.
Read swarmforge/$Role.prompt, then read every file it refers to recursively, and follow all of those instructions.
"@

    Set-Content -LiteralPath $PromptFile -Value $content -Encoding utf8
}

function Write-RoleLaunchScript {
    param(
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$RoleWorktree,
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Display,
        [Parameter(Mandatory = $true)][bool]$OwnsCleanup
    )

    $launchScriptPath = Join-Path $LaunchScriptsDir "$Role.ps1"
    $pathPrefix = $SwarmToolsDir + ';' + $ScriptDir + ';'

    switch ($Agent) {
        'claude' {
            $agentExecutable = (Get-Command 'claude' -ErrorAction SilentlyContinue).Source
            $agentInvocation = "& {0} --append-system-prompt-file {1} --permission-mode acceptEdits -n {2} `$promptText" -f `
                (ConvertTo-PowerShellSingleQuotedLiteral $agentExecutable),
                (ConvertTo-PowerShellSingleQuotedLiteral $PromptFile),
                (ConvertTo-PowerShellSingleQuotedLiteral ("SwarmForge $Display"))
        }
        'codex' {
            $agentExecutable = (Get-Command 'codex' -ErrorAction SilentlyContinue).Source
            $agentInvocation = "& {0} -C {1} `$promptText" -f `
                (ConvertTo-PowerShellSingleQuotedLiteral $agentExecutable),
                (ConvertTo-PowerShellSingleQuotedLiteral $RoleWorktree)
        }
        default {
            throw "Unsupported agent '$Agent' for role '$Role'"
        }
    }

    $cleanupBlock = ''
    if ($OwnsCleanup) {
        $cleanupBlock = @"
`$exitCode = if (`$null -ne `$LASTEXITCODE) { [int]`$LASTEXITCODE } else { 0 }
$(Get-CleanupCommand)
exit `$exitCode
"@
    }

    $content = @"
`$env:PATH = $(ConvertTo-PowerShellSingleQuotedLiteral $pathPrefix) + `$env:PATH
Set-Location $(ConvertTo-PowerShellSingleQuotedLiteral $RoleWorktree)
`$promptText = Get-Content -LiteralPath $(ConvertTo-PowerShellSingleQuotedLiteral $PromptFile) -Raw
$agentInvocation
$cleanupBlock
"@

    Set-Content -LiteralPath $launchScriptPath -Value $content -Encoding utf8
    return $launchScriptPath
}

function Launch-Role {
    param(
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][bool]$IsFirstWindow
    )

    $entry = $script:Entries[$Index - 1]
    $role = $entry.Role
    $agent = $entry.Agent
    $session = $entry.Session
    $windowName = $entry.Window
    $paneIndex = $entry.Pane
    $display = $entry.DisplayName
    $roleWorktree = $entry.WorktreePath
    $promptFile = Join-Path $PromptsDir "$role.md"
    $initialCommand = @()
    $powerShellExe = Get-PreferredPowerShellExecutable

    if ([string]::IsNullOrWhiteSpace($powerShellExe)) {
        throw 'A PowerShell executable is required to launch role sessions.'
    }

    if ($agent -eq 'none') {
        if ($role -eq 'logger') {
            $logFile = Join-Path $WorkingDir 'logs\agent_messages.log'
            $sessionCommand = "Set-Location {0}; New-Item -ItemType File -Force -Path {1} | Out-Null; Write-Host 'Logger ready'; Get-Content -LiteralPath {1} -Wait" -f `
                (ConvertTo-PowerShellSingleQuotedLiteral $WorkingDir),
                (ConvertTo-PowerShellSingleQuotedLiteral $logFile)
            $initialCommand = @($powerShellExe, '-NoLogo', '-NoProfile', '-Command', $sessionCommand)
        }

        Create-RolePane -Session $session -Window $windowName -IsFirstWindow $IsFirstWindow -InitialCommand $initialCommand
        Write-Host "  ${Cyan}[$display]${Reset} opened without agent backend in $session`:$windowName.$paneIndex"
        return
    }

    Write-AgentInstructionFile -Role $role -PromptFile $promptFile

    $launchScriptPath = Write-RoleLaunchScript -Role $role -RoleWorktree $roleWorktree -PromptFile $promptFile -Agent $agent -Display $display -OwnsCleanup ($Index -eq $script:CleanupOwnerIndex)
    $initialCommand = @($powerShellExe, '-NoLogo', '-NoProfile', '-File', $launchScriptPath)
    Create-RolePane -Session $session -Window $windowName -IsFirstWindow $IsFirstWindow -InitialCommand $initialCommand
    Write-Host "  ${Cyan}[$display]${Reset} started in $session`:$windowName.$paneIndex"
}

function Choose-CleanupOwner {
    foreach ($entry in $script:Entries) {
        if ($entry.Agent -eq 'codex') {
            $script:CleanupOwnerIndex = $entry.Index
            return
        }
    }

    if ($script:RoleIndex.ContainsKey('architect')) {
        $architectIndex = [int]$script:RoleIndex['architect']
        if ($script:Entries[$architectIndex - 1].Agent -ne 'none') {
            $script:CleanupOwnerIndex = $architectIndex
            return
        }
    }

    foreach ($entry in $script:Entries) {
        if ($entry.Agent -ne 'none') {
            $script:CleanupOwnerIndex = $entry.Index
            return
        }
    }
}

Initialize-TmuxCommand
Check-Dependency 'git'
Initialize-GitRepo
Parse-Config
Check-BackendDependencies
Prepare-Workspace
Prepare-Worktrees
Choose-CleanupOwner

$hasSession = $false

try {
    Invoke-Tmux has-session -t $script:SwarmSessionName *> $null
    $hasSession = ($LASTEXITCODE -eq 0)
} catch {
    $hasSession = $false
}

if ($hasSession) {
    Write-Host "${Yellow}Existing SwarmForge session found: $($script:SwarmSessionName). Killing it...${Reset}"
    Invoke-Tmux kill-session -t $script:SwarmSessionName *> $null
}

Write-Host ($Cyan + $Bold)
Write-Host '  +-----------------------------------------------+'
Write-Host '  |           SwarmForge v1.0 Starting            |'
Write-Host '  |   Disciplined agents build better software    |'
Write-Host '  +-----------------------------------------------+'
Write-Host $Reset

Write-Host ($Green + 'Starting SwarmForge session...' + $Reset)
foreach ($entry in $script:Entries) {
    Launch-Role -Index $entry.Index -IsFirstWindow ($entry.Index -eq 1)
    Start-Sleep -Milliseconds 750
}

foreach ($entry in $script:Entries) {
    Invoke-Tmux select-pane -t "$($entry.Session):$($entry.Window).$($entry.Pane)" -T $entry.DisplayName *> $null
}

Invoke-Tmux select-window -t "$($script:SwarmSessionName):$($script:Entries[0].Window)" *> $null
Invoke-Tmux select-pane -t "$($script:Entries[0].Session):$($script:Entries[0].Window).$($script:Entries[0].Pane)" *> $null

Write-Host ''
Write-Host ($Green + $Bold + 'SwarmForge is ready.' + $Reset)
Write-Host ('Working directory: ' + $WorkingDir)
Write-Host ('Session: ' + $script:SwarmSessionName)
Write-Host ('Window: ' + $SwarmWindowName)
Write-Host 'Panes:'
foreach ($entry in $script:Entries) {
    Write-Host ('  ' + $entry.DisplayName + ': ' + $entry.Session + ':' + $entry.Window + '.' + $entry.Pane)
}
Write-Host ''

$attachHint = if ($script:UseWslTmux) { 'wsl tmux attach-session -t <session-name>' } else { 'tmux attach-session -t <session-name>' }

Write-Host ($Green + 'Tip: Use ' + $WorkingDir + '\swarmtools\notify-agent.ps1 role-or-index message while the swarm is running.' + $Reset)
Write-Host ($Green + 'Tip: Navigate tmux panes with Ctrl-b then an arrow key.' + $Reset)
Write-Host ($Green + 'Tip: Reattach manually with ' + ($attachHint -replace '<session-name>', $script:SwarmSessionName) + ' if needed.' + $Reset)
Write-Host ''

Invoke-Tmux attach-session -t $script:SwarmSessionName
