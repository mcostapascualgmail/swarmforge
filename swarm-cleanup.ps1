[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Session,

    [Parameter(Position = 1)]
    [string]$LaunchersDir,

    [Parameter(Position = 2)]
    [switch]$WaitForDetach,

    [Parameter(Position = 3)]
    [int]$InitialAttachTimeoutSeconds = 120,

    [Parameter(Position = 4)]
    [int]$SupervisorProcessId = 0
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

function Get-TmuxClientCount {
    param([Parameter(Mandatory = $true)][string]$SessionName)

    try {
        $clients = @(Invoke-Tmux list-clients -t $SessionName 2>$null)
        if ($LASTEXITCODE -ne 0) {
            return -1
        }

        return $clients.Count
    } catch {
        return -1
    }
}

function Test-ProcessIsRunning {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    if ($ProcessId -le 0) {
        return $true
    }

    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Wait-ForDetach {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$ParentProcessId
    )

    $sawClient = $false
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ($true) {
        if (-not (Test-ProcessIsRunning -ProcessId $ParentProcessId)) {
            return
        }

        $clientCount = Get-TmuxClientCount -SessionName $SessionName
        if ($clientCount -lt 0) {
            return
        }

        if ($clientCount -gt 0) {
            $sawClient = $true
        } elseif ($sawClient) {
            return
        } elseif ((Get-Date) -ge $deadline) {
            return
        }

        Start-Sleep -Milliseconds 500
    }
}

Initialize-TmuxCommand

if ($WaitForDetach) {
    Wait-ForDetach -SessionName $Session -TimeoutSeconds $InitialAttachTimeoutSeconds -ParentProcessId $SupervisorProcessId
}

if (-not [string]::IsNullOrWhiteSpace($Session)) {
    try {
        Invoke-Tmux kill-session -t $Session *> $null
    } catch {
    }
}

Stop-LaunchProcesses -LaunchersPath $LaunchersDir
