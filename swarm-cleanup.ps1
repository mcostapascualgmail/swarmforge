[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Session
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

if (-not [string]::IsNullOrWhiteSpace($Session)) {
    try {
        Invoke-Tmux kill-session -t $Session *> $null
    } catch {
    }
}
