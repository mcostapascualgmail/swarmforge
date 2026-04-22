[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Target,

    [Parameter(Position = 1, Mandatory = $true, ValueFromRemainingArguments = $true)]
    [string[]]$MessageParts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootDir = Split-Path -Parent $PSCommandPath
$SessionsFile = Join-Path $RootDir '.swarmforge\sessions.tsv'
$LogFile = Join-Path $RootDir 'logs\agent_messages.log'

function Has-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
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
