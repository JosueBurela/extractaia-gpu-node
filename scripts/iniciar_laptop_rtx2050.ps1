[CmdletBinding()]
param(
    [string]$Model = "qwen2.5vl:3b"
)

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "02_iniciar_servidor_ia.ps1"
& $scriptPath -Profile "rtx2050_4gb" -Model $Model -Detached
