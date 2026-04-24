[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Session,

    [Parameter(Position = 1)]
    [string]$LaunchersDir
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
    param([string]$LaunchersPath)

    if ($script:UseWslTmux -or [string]::IsNullOrWhiteSpace($LaunchersPath) -or -not (Test-Path -LiteralPath $LaunchersPath)) {
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

Initialize-TmuxCommand

if (-not [string]::IsNullOrWhiteSpace($Session)) {
    try {
        Invoke-Tmux kill-session -t $Session *> $null
    } catch {
    }
}

Stop-LaunchProcesses -LaunchersPath $LaunchersDir
