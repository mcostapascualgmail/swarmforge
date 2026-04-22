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

function Resolve-Session {
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

        if ($normalizedTarget -eq $index.ToLowerInvariant() -or $normalizedTarget -eq $role.ToLowerInvariant()) {
            return $session
        }
    }

    return $null
}

Initialize-TmuxCommand

if (-not (Test-Path -LiteralPath $SessionsFile)) {
    Write-Error "Sessions file not found: $SessionsFile"
    exit 1
}

$TargetSession = Resolve-Session -LookupTarget $Target
if ([string]::IsNullOrWhiteSpace($TargetSession)) {
    Write-Error "Unknown target: $Target"
    exit 1
}

$Message = $MessageParts -join ' '
$Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null
Add-Content -LiteralPath $LogFile -Value "[$Timestamp] [$TargetSession] $Message"

Invoke-Tmux send-keys -t "$TargetSession`:0.0" -l -- $Message
Start-Sleep -Milliseconds 150
Invoke-Tmux send-keys -t "$TargetSession`:0.0" C-m
Start-Sleep -Milliseconds 50
Invoke-Tmux send-keys -t "$TargetSession`:0.0" C-j
