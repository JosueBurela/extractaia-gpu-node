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

# Dar de baja del pool interno si existe .env configurado
$dotenvPath = Join-Path $repoRoot ".env"
if (Test-Path $dotenvPath) {
    $dotenvMap = @{}
    foreach ($rawLine in (Get-Content -Path $dotenvPath -ErrorAction SilentlyContinue)) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        $eqIdx = $line.IndexOf("=")
        if ($eqIdx -gt 0) {
            $k = $line.Substring(0, $eqIdx).Trim()
            $v = $line.Substring($eqIdx + 1).Trim().Trim('"').Trim("'")
            $dotenvMap[$k] = $v
        }
    }
    $regUrl = $dotenvMap["EXTRACTAIA_REGISTER_URL"]
    $tok = $dotenvMap["GPU_NODE_TOKEN"]
    $nodeId = $dotenvMap["GPU_NODE_ID"]
    if ($regUrl -and $tok -and $nodeId -and ($tok -ne "REEMPLAZAR_POR_TOKEN_OPERADOR")) {
        try {
            $delUrl = ("{0}/api/v1/internal/gpu-nodes/{1}" -f $regUrl.TrimEnd("/"), $nodeId)
            Invoke-RestMethod -Uri $delUrl -Method Delete -Headers @{ "X-Node-Token" = $tok } -TimeoutSec 8 | Out-Null
            Write-Host ("[OK] Nodo '{0}' dado de baja del pool de ExtractaIA." -f $nodeId) -ForegroundColor Green
        } catch {
            Write-Host ("[WARN] No se pudo dar de baja '{0}' en el pool: {1}" -f $nodeId, $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

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
