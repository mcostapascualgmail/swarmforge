[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Source,

    [Parameter(Position = 1, Mandatory = $true)]
    [string]$Message
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$LogFile = Join-Path (Get-Location) 'logs\agent_messages.log'
$LogLine = "[$Timestamp] [$Source] $Message"

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null
Add-Content -LiteralPath $LogFile -Value $LogLine

Write-Output "[$Source] $Message"
