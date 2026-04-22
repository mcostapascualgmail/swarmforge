[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$WindowIdsFile,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Sessions = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

Initialize-TmuxCommand

foreach ($session in $Sessions) {
    if ([string]::IsNullOrWhiteSpace($session)) {
        continue
    }

    try {
        Invoke-Tmux kill-session -t $session *> $null
    } catch {
    }
}

Start-Sleep -Seconds 1

if (Test-Path -LiteralPath $WindowIdsFile) {
    foreach ($windowId in Get-Content -LiteralPath $WindowIdsFile) {
        $value = $windowId.Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $processId = 0
        if ([int]::TryParse($value, [ref]$processId)) {
            try {
                Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            } catch {
            }
        }
    }
}
