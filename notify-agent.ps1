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
            (Split-Path -Parent $PSCommandPath),
            (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
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
