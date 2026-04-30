[CmdletBinding()]
param(
    [string]$WorkingDir = (Get-Location).Path,
    [switch]$KeepSessionOnDetach
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
$WorktreesDir = Join-Path $WorkingDir '.worktrees'
$SwarmToolsDir = Join-Path $WorktreesDir 'swarmtools'
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
        $commandPath = Get-WslCommandPath $Name
        if ([string]::IsNullOrWhiteSpace($commandPath)) {
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

function Get-WslCommandPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Has-Command 'wsl')) {
        return $null
    }

    try {
        $output = & wsl bash -lc "command -v $Name 2>/dev/null"
        if ($LASTEXITCODE -eq 0) {
            $path = ($output | Select-Object -First 1)
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                return $path.Trim()
            }
        }
    } catch {
    }

    return $null
}

function Get-LaunchPowerShellExecutable {
    if ($script:UseWslTmux) {
        foreach ($candidate in @('pwsh', 'powershell')) {
            $commandPath = Get-WslCommandPath $candidate
            if (-not [string]::IsNullOrWhiteSpace($commandPath)) {
                return $commandPath
            }
        }

        return $null
    }

    return Get-PreferredPowerShellExecutable
}

function Get-BackendExecutable {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($script:UseWslTmux) {
        $commandPath = Get-WslCommandPath $Name
        if (-not [string]::IsNullOrWhiteSpace($commandPath)) {
            return $commandPath
        }

        return $Name
    }

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $Name
    }

    return $command.Source
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

function Get-LaunchPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($script:UseWslTmux) {
        return Get-ShellPath $Path
    }

    return $Path
}

function Get-LaunchPathSeparator {
    if ($script:UseWslTmux) {
        return ':'
    }

    return ';'
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

    if ($script:UseWslTmux) {
        return "try { & tmux kill-session -t $sessionName *> `$null } catch { }"
    }

    $cleanupPs1 = Join-Path $ScriptDir 'swarm-cleanup.ps1'
    if (Test-Path -LiteralPath $cleanupPs1) {
        $powerShellExe = Get-PreferredPowerShellExecutable
        if ([string]::IsNullOrWhiteSpace($powerShellExe)) {
            throw 'A PowerShell executable is required to launch swarm-cleanup.ps1.'
        }

        $cleanupCommand = "& {0} {1} {2}" -f `
            (ConvertTo-PowerShellSingleQuotedLiteral $cleanupPs1),
            $sessionName,
            (ConvertTo-PowerShellSingleQuotedLiteral $LaunchScriptsDir)
        $encodedCleanupCommand = ConvertTo-EncodedPowerShellCommand $cleanupCommand

        return "# swarm-cleanup.ps1`nStart-Process -WindowStyle Hidden -FilePath {0} -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', {1}) | Out-Null" -f `
            (ConvertTo-PowerShellSingleQuotedLiteral $powerShellExe),
            (ConvertTo-PowerShellSingleQuotedLiteral $encodedCleanupCommand)
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

function Invoke-GitChecked {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    $output = (& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $details = (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($details)) {
            throw $FailureMessage
        }

        throw "$FailureMessage`n$details"
    }

    return @($output)
}

function Stop-ProcessTree {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    if ($ProcessId -eq $PID) {
        return
    }

    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        Stop-ProcessTree -ProcessId ([int]$child.ProcessId)
    }

    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Stop-LaunchProcesses {
    param([Parameter(Mandatory = $true)][string]$LaunchersPath)

    if ($script:UseWslTmux -or -not (Test-Path -LiteralPath $LaunchersPath)) {
        return
    }

    $resolvedLaunchersPath = (Resolve-Path -LiteralPath $LaunchersPath).Path
    $launcherProcesses = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and
                $_.CommandLine.IndexOf($resolvedLaunchersPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            }
    )

    foreach ($process in $launcherProcesses) {
        Stop-ProcessTree -ProcessId ([int]$process.ProcessId)
    }
}

function Stop-SwarmSession {
    param([Parameter(Mandatory = $true)][string]$Session)

    if (-not [string]::IsNullOrWhiteSpace($Session)) {
        try {
            Invoke-Tmux kill-session -t $Session *> $null
        } catch {
        }
    }

    Stop-LaunchProcesses -LaunchersPath $LaunchScriptsDir
}

function Start-DetachCleanupWatcher {
    param([Parameter(Mandatory = $true)][string]$Session)

    if ($KeepSessionOnDetach) {
        return
    }

    $cleanupPs1 = Join-Path $ScriptDir 'swarm-cleanup.ps1'
    if (-not (Test-Path -LiteralPath $cleanupPs1)) {
        return
    }

    $powerShellExe = Get-PreferredPowerShellExecutable
    if ([string]::IsNullOrWhiteSpace($powerShellExe)) {
        return
    }

    $watchCommand = "& {0} {1} {2} -WaitForDetach -SupervisorProcessId {3}" -f `
        (ConvertTo-PowerShellSingleQuotedLiteral $cleanupPs1),
        (ConvertTo-PowerShellSingleQuotedLiteral $Session),
        (ConvertTo-PowerShellSingleQuotedLiteral $LaunchScriptsDir),
        $PID
    $encodedWatchCommand = ConvertTo-EncodedPowerShellCommand $watchCommand

    Start-Process -WindowStyle Hidden -FilePath $powerShellExe -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        $encodedWatchCommand
    ) | Out-Null
}

function Test-GitHeadExists {
    & git -C $WorkingDir rev-parse --verify HEAD *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-GitBranchExists {
    param([Parameter(Mandatory = $true)][string]$Branch)

    & git -C $WorkingDir show-ref --verify --quiet "refs/heads/$Branch"
    return ($LASTEXITCODE -eq 0)
}

function Get-GitBranchDisplay {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $branch = (& git -C $Path branch --show-current 2>$null | Select-Object -First 1)
        if (($LASTEXITCODE -eq 0) -and -not [string]::IsNullOrWhiteSpace($branch)) {
            return $branch.Trim()
        }

        $commit = (& git -C $Path rev-parse --short HEAD 2>$null | Select-Object -First 1)
        if (($LASTEXITCODE -eq 0) -and -not [string]::IsNullOrWhiteSpace($commit)) {
            return "detached@$($commit.Trim())"
        }
    } catch {
    }

    return 'unknown'
}

function Ensure-InitialCommit {
    Invoke-GitChecked -Arguments @('-C', $WorkingDir, 'add', '.') -FailureMessage "Failed to stage the initial repository state in $WorkingDir." | Out-Null
    Invoke-GitChecked -Arguments @('-C', $WorkingDir, 'commit', '--allow-empty', '-m', 'Initial swarmforge repository') -FailureMessage "Failed to create the initial commit in $WorkingDir. Configure git user.name and git user.email, then try again." | Out-Null
}

function Initialize-GitRepo {
    $gitDir = Join-Path $WorkingDir '.git'
    if (-not (Test-Path -LiteralPath $gitDir)) {
        Invoke-GitChecked -Arguments @('init', $WorkingDir) -FailureMessage "Failed to initialize a git repository in $WorkingDir." | Out-Null
        Invoke-GitChecked -Arguments @('-C', $WorkingDir, 'branch', '-M', 'master') -FailureMessage "Failed to rename the initial branch to 'master' in $WorkingDir." | Out-Null
    }

    Ensure-InitialGitignore

    if (-not (Test-GitHeadExists)) {
        Ensure-InitialCommit
    }
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

function Test-IsRootWorktreeName {
    param([Parameter(Mandatory = $true)][string]$Name)

    return ($Name.ToLowerInvariant() -in @('root', 'none', 'master'))
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
        $worktreeKey = $worktree.ToLowerInvariant()

        if ($keyword -ne 'window') {
            throw "Unknown config directive on line ${lineNo}: $keyword"
        }

        if ($script:RoleIndex.ContainsKey($role)) {
            throw "Duplicate role '$role' in $ConfigFile"
        }

        if ($worktreeKey -eq 'master') {
            Write-Warning "Config line ${lineNo}: worktree value 'master' is deprecated as a root-checkout alias. Use 'root' instead."
        }

        if ((-not (Test-IsRootWorktreeName $worktree)) -and $script:WorktreeIndex.ContainsKey($worktreeKey)) {
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
        $worktreePath = if (Test-IsRootWorktreeName $worktree) { $WorkingDir } else { Worktree-PathForName $worktree }

        $script:RoleIndex[$role] = $index
        if (-not (Test-IsRootWorktreeName $worktree)) {
            $script:WorktreeIndex[$worktreeKey] = $index
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
    Invoke-GitChecked -Arguments @('-C', $WorkingDir, 'worktree', 'prune') -FailureMessage "Failed to prune stale git worktree metadata in $WorkingDir." | Out-Null

    foreach ($entry in $script:Entries) {
        $worktreeName = $entry.Worktree
        $worktreePath = $entry.WorktreePath
        $branchName = "swarmforge-$worktreeName"

        if (Test-IsRootWorktreeName $worktreeName) {
            continue
        }

        $worktreeGit = Join-Path $worktreePath '.git'
        if (Test-Path -LiteralPath $worktreeGit) {
            continue
        }

        if (-not (Test-GitHeadExists)) {
            throw "Cannot create worktree '$worktreeName' because repository HEAD does not exist yet."
        }

        if (Test-GitBranchExists $branchName) {
            Invoke-GitChecked -Arguments @('-C', $WorkingDir, 'worktree', 'add', $worktreePath, $branchName) -FailureMessage "Failed to create worktree '$worktreeName' at $worktreePath from existing branch '$branchName'." | Out-Null
        } else {
            Invoke-GitChecked -Arguments @('-C', $WorkingDir, 'worktree', 'add', '-b', $branchName, $worktreePath, 'HEAD') -FailureMessage "Failed to create worktree '$worktreeName' at $worktreePath from HEAD." | Out-Null
        }

        if (-not (Test-Path -LiteralPath $worktreeGit)) {
            throw "Worktree '$worktreeName' was not created correctly at $worktreePath."
        }
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

function Check-LaunchPowerShellDependency {
    foreach ($entry in $script:Entries) {
        if (($entry.Agent -ne 'none') -or ($entry.Role -eq 'logger')) {
            $powerShellExe = Get-LaunchPowerShellExecutable
            if ([string]::IsNullOrWhiteSpace($powerShellExe)) {
                if ($script:UseWslTmux) {
                    throw 'pwsh is required in the tmux environment (WSL) to launch role sessions.'
                }

                throw 'A PowerShell executable is required to launch role sessions.'
            }

            return
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
The authoritative `swarmforge/` folder is always the version-controlled folder at the project root. Resolve every `swarmforge/...` path from the current repository root, never from `.swarmforge/` and never from inside `.worktrees/`.
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
    $roleWorktreeForLaunch = Get-LaunchPath $RoleWorktree
    $promptFileForLaunch = Get-LaunchPath $PromptFile
    $pathPrefix = (Get-LaunchPath $SwarmToolsDir) + (Get-LaunchPathSeparator) + (Get-LaunchPath $ScriptDir) + (Get-LaunchPathSeparator)

    switch ($Agent) {
        'claude' {
            $agentExecutable = Get-BackendExecutable 'claude'
            $claudePermissionMode = if ($Role -eq 'reviewer') { 'bypassPermissions' } else { 'acceptEdits' }
            $agentInvocation = "& {0} --model arn:aws:bedrock:us-east-1:856708425739:inference-profile/global.anthropic.claude-opus-4-7 --append-system-prompt-file {1} --permission-mode {2} -n {3} `$promptText" -f `
                (ConvertTo-PowerShellSingleQuotedLiteral $agentExecutable),
                (ConvertTo-PowerShellSingleQuotedLiteral $promptFileForLaunch),
                (ConvertTo-PowerShellSingleQuotedLiteral $claudePermissionMode),
                (ConvertTo-PowerShellSingleQuotedLiteral ("SwarmForge $Display"))
        }
        'codex' {
            $agentExecutable = Get-BackendExecutable 'codex'
            $codexPermissionFlag = if ($Role -eq 'reviewer') { '--dangerously-bypass-approvals-and-sandbox' } else { '--full-auto' }
            $agentInvocation = "& {0} {1} -m {2} -C {3} `$promptText" -f `
                (ConvertTo-PowerShellSingleQuotedLiteral $agentExecutable),
                (ConvertTo-PowerShellSingleQuotedLiteral $codexPermissionFlag),
                (ConvertTo-PowerShellSingleQuotedLiteral 'gpt-5.4'),
                (ConvertTo-PowerShellSingleQuotedLiteral $roleWorktreeForLaunch)
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
Set-Location $(ConvertTo-PowerShellSingleQuotedLiteral $roleWorktreeForLaunch)
`$promptText = Get-Content -LiteralPath $(ConvertTo-PowerShellSingleQuotedLiteral $promptFileForLaunch) -Raw
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
    $powerShellExe = Get-LaunchPowerShellExecutable

    if ([string]::IsNullOrWhiteSpace($powerShellExe)) {
        if ($script:UseWslTmux) {
            throw 'pwsh is required in the tmux environment (WSL) to launch role sessions.'
        }

        throw 'A PowerShell executable is required to launch role sessions.'
    }

    if ($agent -eq 'none') {
        if ($role -eq 'logger') {
            $logFile = Join-Path $WorkingDir 'logs\agent_messages.log'
            $workingDirForLaunch = Get-LaunchPath $WorkingDir
            $logFileForLaunch = Get-LaunchPath $logFile
            $sessionCommand = "Set-Location {0}; New-Item -ItemType File -Force -Path {1} | Out-Null; Write-Host 'Logger ready'; Get-Content -LiteralPath {1} -Wait" -f `
                (ConvertTo-PowerShellSingleQuotedLiteral $workingDirForLaunch),
                (ConvertTo-PowerShellSingleQuotedLiteral $logFileForLaunch)
            $initialCommand = @($powerShellExe, '-NoLogo', '-NoProfile', '-Command', $sessionCommand)
        }

        Create-RolePane -Session $session -Window $windowName -IsFirstWindow $IsFirstWindow -InitialCommand $initialCommand
        Write-Host "  ${Cyan}[$display]${Reset} opened without agent backend in $session`:$windowName.$paneIndex"
        return
    }

    Write-AgentInstructionFile -Role $role -PromptFile $promptFile

    $launchScriptPath = Write-RoleLaunchScript -Role $role -RoleWorktree $roleWorktree -PromptFile $promptFile -Agent $agent -Display $display -OwnsCleanup ($Index -eq $script:CleanupOwnerIndex)
    $initialCommand = @($powerShellExe, '-NoLogo', '-NoProfile', '-File', (Get-LaunchPath $launchScriptPath))
    Create-RolePane -Session $session -Window $windowName -IsFirstWindow $IsFirstWindow -InitialCommand $initialCommand
    Write-Host "  ${Cyan}[$display]${Reset} started in $session`:$windowName.$paneIndex"
}

function Choose-CleanupOwner {
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
Check-LaunchPowerShellDependency
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
    Stop-SwarmSession -Session $script:SwarmSessionName
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
Write-Host 'Role locations:'
foreach ($entry in $script:Entries) {
    $branch = Get-GitBranchDisplay -Path $entry.WorktreePath
    Write-Host ('  ' + $entry.DisplayName + ': ' + $entry.WorktreePath + ' [' + $branch + ']')
}
Write-Host ''

$attachHint = if ($script:UseWslTmux) { 'wsl tmux attach-session -t <session-name>' } else { 'tmux attach-session -t <session-name>' }

Write-Host ($Green + 'Tip: Use ' + $WorkingDir + '\.worktrees\swarmtools\notify-agent.ps1 role-or-index message while the swarm is running.' + $Reset)
Write-Host ($Green + 'Tip: Navigate tmux panes with Ctrl-b then an arrow key.' + $Reset)
if ($KeepSessionOnDetach) {
    Write-Host ($Green + 'Tip: Reattach manually with ' + ($attachHint -replace '<session-name>', $script:SwarmSessionName) + ' if needed.' + $Reset)
} else {
    Write-Host ($Green + 'Tip: Closing or detaching this client stops the swarm. Start with -KeepSessionOnDetach to preserve it for reattach.' + $Reset)
}
Write-Host ''

Start-DetachCleanupWatcher -Session $script:SwarmSessionName

try {
    Invoke-Tmux attach-session -t $script:SwarmSessionName
} finally {
    if (-not $KeepSessionOnDetach) {
        Stop-SwarmSession -Session $script:SwarmSessionName
    }
}
