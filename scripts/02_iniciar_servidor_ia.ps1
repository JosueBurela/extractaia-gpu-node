[CmdletBinding()]
param(
    [ValidateSet("rtx5060_8gb", "rtx2050_4gb")]
    [string]$Profile = "rtx5060_8gb",
    [string]$Model = "qwen2.5vl:3b",
    [switch]$Detached,
    [switch]$KeepAlive,
    [ValidateSet("http2", "auto", "quic")]
    [string]$Protocol = "http2",
    [string]$RegisterUrl = "",
    [string]$NodeToken = "",
    [string]$NodeId = "",
    [string]$NodeLabel = "",
    [int]$Priority = 0
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$dotenvPath = Join-Path $repoRoot ".env"
$dotenvMap = @{}
if (Test-Path $dotenvPath) {
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
}

if (-not $RegisterUrl -and $dotenvMap.ContainsKey("EXTRACTAIA_REGISTER_URL")) { $RegisterUrl = $dotenvMap["EXTRACTAIA_REGISTER_URL"] }
if (-not $NodeToken -and $dotenvMap.ContainsKey("GPU_NODE_TOKEN")) { $NodeToken = $dotenvMap["GPU_NODE_TOKEN"] }
if (-not $NodeId -and $dotenvMap.ContainsKey("GPU_NODE_ID")) { $NodeId = $dotenvMap["GPU_NODE_ID"] }
if (-not $NodeLabel -and $dotenvMap.ContainsKey("GPU_NODE_LABEL")) { $NodeLabel = $dotenvMap["GPU_NODE_LABEL"] }
if ($Priority -le 0 -and $dotenvMap.ContainsKey("GPU_NODE_PRIORITY")) {
    $parsedPrio = 0
    if ([int]::TryParse($dotenvMap["GPU_NODE_PRIORITY"], [ref]$parsedPrio)) { $Priority = $parsedPrio }
}
if (-not $NodeId) { $NodeId = if ($Profile -eq "rtx2050_4gb") { "laptop-rtx2050" } else { "pc-rtx5060" } }
if (-not $NodeLabel) { $NodeLabel = if ($Profile -eq "rtx2050_4gb") { "Laptop RTX 2050 (4 GB)" } else { "Desktop RTX 5060 (8 GB)" } }
if ($Priority -le 0) { $Priority = if ($Profile -eq "rtx2050_4gb") { 20 } else { 10 } }

Write-Host ("=== ExtractaIA GPU Node - Arranque ({0}) + Tunel HTTPS ===" -f $Profile) -ForegroundColor Cyan

function Refresh-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$userPath;$machinePath"
}

function Resolve-ToolExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [string[]]$CandidatePaths = @()
    )

    Refresh-SessionPath
    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) {
        return $cmd.Source
    }

    foreach ($candidate in $CandidatePaths) {
        if ($candidate -and (Test-Path $candidate)) {
            $dir = Split-Path -Parent $candidate
            if ($env:Path -notlike "*$dir*") {
                $env:Path = "$dir;$env:Path"
            }
            return $candidate
        }
    }

    return $null
}

# Aplicar variables de optimizacion VRAM segun perfil
$env:OLLAMA_HOST = "127.0.0.1:11434"
$env:OLLAMA_MAX_LOADED_MODELS = "1"
$env:OLLAMA_FLASH_ATTENTION = "1"
if ($Profile -eq "rtx2050_4gb") {
    $env:OLLAMA_KEEP_ALIVE = "10m"
    $env:OLLAMA_NUM_PARALLEL = "1"
    $env:OLLAMA_KV_CACHE_TYPE = "q8_0"
} else {
    $env:OLLAMA_KEEP_ALIVE = "15m"
    $env:OLLAMA_NUM_PARALLEL = "2"
    $env:OLLAMA_KV_CACHE_TYPE = "q8_0"
}

$ollamaExe = Resolve-ToolExecutable -CommandName "ollama" -CandidatePaths @(
    (Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"),
    (Join-Path $env:ProgramFiles "Ollama\ollama.exe")
)
if (-not $ollamaExe) {
    throw "No se encontro 'ollama'. Ejecuta primero .\scripts\01_instalar_nodo_gpu.ps1"
}

$cloudflaredExe = Resolve-ToolExecutable -CommandName "cloudflared" -CandidatePaths @(
    (Join-Path $env:LOCALAPPDATA "Programs\cloudflared\cloudflared.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "cloudflared\cloudflared.exe"),
    (Join-Path $env:ProgramFiles "cloudflared\cloudflared.exe")
)
if (-not $cloudflaredExe) {
    throw "No se encontro 'cloudflared'. Ejecuta primero .\scripts\01_instalar_nodo_gpu.ps1"
}

# 1. Verificar o iniciar Ollama en 127.0.0.1:11434
$running = $false
try {
    Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 2 | Out-Null
    $running = $true
} catch {
    Write-Host "Iniciando Ollama en segundo plano (127.0.0.1:11434)..." -ForegroundColor Yellow
    Start-Process -FilePath $ollamaExe -ArgumentList "serve" -WindowStyle Hidden
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 2 | Out-Null
            $running = $true
            break
        } catch { }
    }
}

if (-not $running) {
    throw "Ollama no respondio en http://127.0.0.1:11434."
}

# 2. Warm-up: precargar el modelo en la VRAM del nodo GPU
Write-Host ("Precargando modelo '{0}' en la VRAM ({1})..." -f $Model, $Profile) -ForegroundColor Cyan
$warmupBody = @{
    model = $Model
    messages = @(
        @{ role = "user"; content = 'Responde unicamente {"status":"ready"}' }
    )
    stream = $false
    format = "json"
} | ConvertTo-Json -Depth 5

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$warmupResp = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/chat" -Method Post -ContentType "application/json" -Body $warmupBody -TimeoutSec 180
$sw.Stop()
Write-Host ("[OK] Warm-up completado en {0} ms." -f $sw.ElapsedMilliseconds) -ForegroundColor Green

# 3. Verificar descarga a GPU en ollama ps y mostrar uso de VRAM con nvidia-smi
Write-Host "`n=== Estado de carga de modelos (ollama ps) ===" -ForegroundColor Cyan
$ollamaPsLines = @(& $ollamaExe ps 2>&1)
$ollamaPsText = ($ollamaPsLines -join "`n")
Write-Host $ollamaPsText
if ($ollamaPsText -match "100%\s+CPU" -and $ollamaPsText -notmatch "GPU") {
    Write-Host "[WARN] El modelo esta corriendo en 100% CPU en lugar de GPU. Actualiza Ollama a la ultima version y el driver NVIDIA >= 572 para soporte RTX 5060 Blackwell (sm_120)." -ForegroundColor Yellow
}

$nvidiaSmi = Resolve-ToolExecutable -CommandName "nvidia-smi" -CandidatePaths @(
    (Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI\nvidia-smi.exe"),
    (Join-Path $env:WINDIR "System32\nvidia-smi.exe")
)
if ($nvidiaSmi) {
    Write-Host "`n=== Estado actual de GPU / VRAM ===" -ForegroundColor Cyan
    & $nvidiaSmi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader
}

# 4. Iniciar tunel HTTPS hacia 127.0.0.1:11434
if ($Detached) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $runtimeDir = Join-Path $repoRoot ".runtime"
    if (-not (Test-Path $runtimeDir)) {
        New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    }

    $pidFile = Join-Path $runtimeDir "tunnel.pid"
    $urlFile = Join-Path $runtimeDir "tunnel_url.txt"
    $outLog = Join-Path $runtimeDir "cloudflared.out.log"
    $errLog = Join-Path $runtimeDir "cloudflared.err.log"

    if (Test-Path $pidFile) {
        $oldPidText = (Get-Content $pidFile -ErrorAction SilentlyContinue | Out-String).Trim()
        $oldPid = 0
        if ([int]::TryParse($oldPidText, [ref]$oldPid)) {
            $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($oldProc -and $oldProc.ProcessName -eq "cloudflared") {
                Write-Host ("[WARN] Deteniendo tunel cloudflared previo (PID {0})..." -f $oldPid) -ForegroundColor Yellow
                Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
            }
        }
        Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
    }

    Remove-Item -Path $urlFile, $outLog, $errLog -Force -ErrorAction SilentlyContinue

    Write-Host ("`nIniciando tunel Cloudflare desacoplado (protocol={0})..." -f $Protocol) -ForegroundColor Cyan
    $proc = Start-Process -FilePath $cloudflaredExe `
        -ArgumentList @("tunnel", "--url", "http://127.0.0.1:11434", "--protocol", $Protocol, "--no-autoupdate") `
        -WindowStyle Hidden `
        -RedirectStandardOutput $outLog `
        -RedirectStandardError $errLog `
        -PassThru

    $tunnelUrl = $null
    $urlPattern = "https://[a-z0-9-]+\.trycloudflare\.com"
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        foreach ($logPath in @($errLog, $outLog)) {
            if (Test-Path $logPath) {
                $content = Get-Content -Path $logPath -Raw -ErrorAction SilentlyContinue
                if ($content -and ($content -match $urlPattern)) {
                    $tunnelUrl = $Matches[0]
                    break
                }
            }
        }
        if ($tunnelUrl) {
            break
        }
        if ($proc.HasExited) {
            $errTail = if (Test-Path $errLog) { (Get-Content -Path $errLog -Tail 30 -ErrorAction SilentlyContinue) -join "`n" } else { "(sin salida en cloudflared.err.log)" }
            throw ("cloudflared termino inesperadamente (exit {0}). Ultimas lineas de cloudflared.err.log:`n{1}" -f $proc.ExitCode, $errTail)
        }
    }

    if (-not $tunnelUrl) {
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
        $errTail = if (Test-Path $errLog) { (Get-Content -Path $errLog -Tail 30 -ErrorAction SilentlyContinue) -join "`n" } else { "(sin salida en cloudflared.err.log)" }
        throw ("No se detecto URL de trycloudflare.com en 30 segundos. Ultimas lineas de cloudflared.err.log:`n{0}" -f $errTail)
    }

    Set-Content -Path $pidFile -Value ([string]$proc.Id) -Encoding ASCII -NoNewline
    Set-Content -Path $urlFile -Value $tunnelUrl -Encoding ASCII -NoNewline

    Write-Host ("Verificando conectividad externa en {0}..." -f $tunnelUrl) -ForegroundColor Cyan
    $remoteVerified = $false
    $lastRemoteError = ""
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        try {
            $tagsResp = Invoke-RestMethod -Uri ("{0}/api/tags" -f $tunnelUrl) -Method Get -TimeoutSec 8
            $modelsResp = Invoke-RestMethod -Uri ("{0}/v1/models" -f $tunnelUrl) -Method Get -TimeoutSec 8
            if ($null -ne $tagsResp -and $null -ne $modelsResp) {
                $remoteVerified = $true
                break
            }
        } catch {
            $lastRemoteError = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    }

    if (-not $remoteVerified) {
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -Path $pidFile, $urlFile -Force -ErrorAction SilentlyContinue
        $errTail = if (Test-Path $errLog) { (Get-Content -Path $errLog -Tail 30 -ErrorAction SilentlyContinue) -join "`n" } else { "" }
        throw ("El tunel {0} no respondio HTTP 200 en /api/tags y /v1/models tras 8 reintentos. Ultimo error: {1}`n{2}" -f $tunnelUrl, $lastRemoteError, $errTail)
    }

    $poolRegistered = $false
    if ($RegisterUrl -and $NodeToken -and ($NodeToken -ne "REEMPLAZAR_POR_TOKEN_OPERADOR")) {
        $regEndpoint = ("{0}/api/v1/internal/gpu-nodes/register" -f $RegisterUrl.TrimEnd("/"))
        $regBody = @{
            id       = $NodeId
            label    = $NodeLabel
            base_url = $tunnelUrl
            model    = $Model
            priority = $Priority
        } | ConvertTo-Json -Depth 4
        Write-Host ("Registrando nodo '{0}' en pool ExtractaIA ({1})..." -f $NodeId, $regEndpoint) -ForegroundColor Cyan
        $regResp = Invoke-RestMethod -Uri $regEndpoint -Method Post -Headers @{ "X-Node-Token" = $NodeToken } -ContentType "application/json" -Body $regBody -TimeoutSec 12
        if ($null -ne $regResp.node) {
            $poolRegistered = $true
            Write-Host ("[OK] Nodo '{0}' registrado en el pool productivo (prioridad {1})." -f $NodeId, $Priority) -ForegroundColor Green
        }
    }

    Write-Host "`n=====================================================================" -ForegroundColor Green
    Write-Host "STATUS=READY" -ForegroundColor Green
    Write-Host ("TUNNEL_URL={0}" -f $tunnelUrl) -ForegroundColor White
    Write-Host ("TUNNEL_PID={0}" -f $proc.Id) -ForegroundColor White
    Write-Host ("PROFILE={0}" -f $Profile) -ForegroundColor White
    Write-Host ("MODEL={0}" -f $Model) -ForegroundColor White
    Write-Host ("PROTOCOL={0}" -f $Protocol) -ForegroundColor White
    Write-Host ("NODE_ID={0}" -f $NodeId) -ForegroundColor White
    Write-Host ("POOL_REGISTERED={0}" -f $poolRegistered) -ForegroundColor White
    Write-Host "PORTAL_URL=https://extractaia.dburela.com" -ForegroundColor White
    Write-Host "=====================================================================" -ForegroundColor Green

    if ($KeepAlive) {
        Write-Host "Modo KeepAlive activo: manteniendo tunel HTTPS y nodo GPU en linea. Presiona Ctrl+C para detener." -ForegroundColor Yellow
        try {
            while (-not $proc.HasExited) {
                Start-Sleep -Seconds 5
            }
            Write-Host ("[WARN] cloudflared finalizo inesperadamente (codigo {0})." -f $proc.ExitCode) -ForegroundColor Yellow
        } finally {
            if ($poolRegistered -and $RegisterUrl -and $NodeToken -and ($NodeToken -ne "REEMPLAZAR_POR_TOKEN_OPERADOR")) {
                try {
                    $delUrl = ("{0}/api/v1/internal/gpu-nodes/{1}" -f $RegisterUrl.TrimEnd("/"), $NodeId)
                    Invoke-RestMethod -Uri $delUrl -Method Delete -Headers @{ "X-Node-Token" = $NodeToken } -TimeoutSec 8 | Out-Null
                } catch { }
            }
            if (-not $proc.HasExited) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
    exit 0
}

Write-Host "`n=====================================================================" -ForegroundColor Yellow
Write-Host " EXTRACTAIA GPU NODE ACTIVO (https://extractaia.dburela.com):" -ForegroundColor Yellow
Write-Host (" 1) Perfil: {0} | Modelo: {1} | Nodo: {2}" -f $Profile, $Model, $NodeId) -ForegroundColor White
Write-Host " 2) El tunel HTTPS atiende peticiones Doc-to-SQL de notas e imagenes." -ForegroundColor White
Write-Host " 3) Si configuraste .env local, inicia con -Detached para auto-registro en el pool." -ForegroundColor White
Write-Host " 4) Presiona Ctrl+C al finalizar para cerrar el tunel al instante." -ForegroundColor White
Write-Host "=====================================================================`n" -ForegroundColor Yellow

& $cloudflaredExe tunnel --url http://127.0.0.1:11434 --protocol $Protocol --no-autoupdate
