[CmdletBinding()]
param(
    [switch]$StopOllama
)

$ErrorActionPreference = "Stop"

Write-Host "=== ExtractaIA GPU Node - Deteniendo Tunel y Servicios ===" -ForegroundColor Cyan

$repoRoot = Split-Path -Parent $PSScriptRoot
$runtimeDir = Join-Path $repoRoot ".runtime"
$pidFile = Join-Path $runtimeDir "tunnel.pid"
$urlFile = Join-Path $runtimeDir "tunnel_url.txt"

$stoppedCount = 0

if (Test-Path $pidFile) {
    $pidText = (Get-Content -Path $pidFile -ErrorAction SilentlyContinue | Out-String).Trim()
    $parsedPid = 0
    if ([int]::TryParse($pidText, [ref]$parsedPid)) {
        $proc = Get-Process -Id $parsedPid -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq "cloudflared") {
            Stop-Process -Id $parsedPid -Force -ErrorAction SilentlyContinue
            Write-Host ("[OK] Tunel cloudflared detenido (PID {0})." -f $parsedPid) -ForegroundColor Green
            $stoppedCount++
        } else {
            Write-Host ("[OK] El PID {0} guardado en tunnel.pid ya no estaba activo." -f $parsedPid) -ForegroundColor Yellow
        }
    }
    Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
}

if (Test-Path $urlFile) {
    Remove-Item -Path $urlFile -Force -ErrorAction SilentlyContinue
}

$remainingCloudflared = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match "^cloudflared(\.exe)?$" -and $_.CommandLine -match "127\.0\.0\.1:11434"
}

foreach ($orphan in $remainingCloudflared) {
    Stop-Process -Id $orphan.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host ("[OK] Tunel cloudflared residual detenido (PID {0})." -f $orphan.ProcessId) -ForegroundColor Green
    $stoppedCount++
}

if ($stoppedCount -eq 0) {
    Write-Host "[OK] No habia procesos cloudflared activos apuntando a 127.0.0.1:11434." -ForegroundColor Green
}

if ($StopOllama) {
    $ollamaProcs = Get-Process -Name "ollama", "ollama app" -ErrorAction SilentlyContinue
    if ($ollamaProcs) {
        $ollamaProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] Procesos de Ollama detenidos." -ForegroundColor Green
    } else {
        Write-Host "[OK] Ollama no estaba en ejecucion." -ForegroundColor Green
    }
}
