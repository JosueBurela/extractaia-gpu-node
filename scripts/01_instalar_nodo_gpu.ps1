[CmdletBinding()]
param(
    [ValidateSet("rtx5060_8gb", "rtx2050_4gb")]
    [string]$Profile = "rtx5060_8gb",
    [switch]$Include7B
)

$ErrorActionPreference = "Stop"

$profileTitle = if ($Profile -eq "rtx2050_4gb") { "Laptop RTX 2050 (4 GB VRAM)" } else { "RTX 5060 (8 GB VRAM)" }
Write-Host ("=== ExtractaIA GPU Node - Instalador {0} ===" -f $profileTitle) -ForegroundColor Cyan

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

$ollamaCandidates = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"),
    (Join-Path $env:ProgramFiles "Ollama\ollama.exe")
)

$cloudflaredCandidates = @(
    (Join-Path $env:LOCALAPPDATA "Programs\cloudflared\cloudflared.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "cloudflared\cloudflared.exe"),
    (Join-Path $env:ProgramFiles "cloudflared\cloudflared.exe")
)

# 1. Verificar GPU NVIDIA, version de driver y espacio libre en disco
$nvidiaSmi = Resolve-ToolExecutable -CommandName "nvidia-smi" -CandidatePaths @(
    (Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI\nvidia-smi.exe"),
    (Join-Path $env:WINDIR "System32\nvidia-smi.exe")
)

if ($nvidiaSmi) {
    Write-Host "`n[OK] GPU NVIDIA detectada:" -ForegroundColor Green
    $gpuLines = @(& $nvidiaSmi --query-gpu=name,driver_version,memory.total,memory.free --format=csv,noheader)
    foreach ($line in $gpuLines) {
        Write-Host ("  " + $line)
        $parts = $line -split ","
        if ($parts.Count -ge 2) {
            $driverRaw = $parts[1].Trim()
            if ($driverRaw -match "^(\d+)") {
                $driverMajor = [int]$Matches[1]
                if ($Profile -eq "rtx5060_8gb" -and $driverMajor -lt 572) {
                    Write-Host ("[WARN] Driver NVIDIA detectado ({0}) < 572. Se recomienda actualizar a >= 572 para soporte completo de RTX 5060 Blackwell (sm_120)." -f $driverRaw) -ForegroundColor Yellow
                }
            }
        }
    }
} else {
    Write-Host "[WARN] No se encontro nvidia-smi en el PATH. Verifica tener instalados los drivers NVIDIA Game Ready / Studio (>= 572)." -ForegroundColor Yellow
}

$driveName = $env:SystemDrive.TrimEnd(":")
$systemDrive = Get-PSDrive -Name $driveName
$freeGb = [math]::Round($systemDrive.Free / 1GB, 2)
Write-Host ("Espacio libre en {0}: {1} GB" -f $env:SystemDrive, $freeGb)
if ($freeGb -lt 10) {
    throw ("Se requieren al menos 10 GB libres en disco en {0} para instalar Ollama y el modelo qwen2.5vl:3b." -f $env:SystemDrive)
}

# 2. Instalar Ollama y cloudflared via winget si no estan disponibles
function Ensure-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string]$WingetId,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [string[]]$CandidatePaths = @()
    )

    $existing = Resolve-ToolExecutable -CommandName $CommandName -CandidatePaths $CandidatePaths
    if ($existing) {
        Write-Host ("[OK] {0} ya esta instalado en: {1}" -f $DisplayName, $existing) -ForegroundColor Green
        return $existing
    }

    $wingetExe = Resolve-ToolExecutable -CommandName "winget"
    if (-not $wingetExe) {
        throw ("No se encontro 'winget'. Instala manualmente {0} ({1}) y vuelve a intentar." -f $DisplayName, $WingetId)
    }

    Write-Host ("[Instalando] {0} ({1}) via winget..." -f $DisplayName, $WingetId) -ForegroundColor Yellow
    & $wingetExe install --id $WingetId --exact --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw ("Error al instalar {0} con winget (codigo {1})." -f $DisplayName, $LASTEXITCODE)
    }

    $installed = Resolve-ToolExecutable -CommandName $CommandName -CandidatePaths $CandidatePaths
    if (-not $installed) {
        throw ("Se instalo {0} con winget, pero no se localizo el ejecutable '{1}'." -f $DisplayName, $CommandName)
    }

    Write-Host ("[OK] {0} instalado correctamente en: {1}" -f $DisplayName, $installed) -ForegroundColor Green
    return $installed
}

function Ensure-CloudflaredBinary {
    param(
        [string[]]$CandidatePaths = @()
    )

    $existing = Resolve-ToolExecutable -CommandName "cloudflared" -CandidatePaths $CandidatePaths
    if ($existing) {
        Write-Host ("[OK] Cloudflare Tunnel (cloudflared) ya esta instalado en: {0}" -f $existing) -ForegroundColor Green
        return $existing
    }

    $installDir = Join-Path $env:LOCALAPPDATA "Programs\cloudflared"
    $dest = Join-Path $installDir "cloudflared.exe"
    if (-not (Test-Path $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }

    $downloadUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
    Write-Host "[Instalando] Descargando binario oficial user-space de Cloudflare Tunnel (sin bloqueo UAC)..." -ForegroundColor Yellow
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $downloadUrl -OutFile $dest -UseBasicParsing

    $sig = Get-AuthenticodeSignature -FilePath $dest
    if (-not $sig -or $sig.Status -ne "Valid") {
        $sigStatus = if ($sig) { $sig.Status } else { "Unknown" }
        Remove-Item -Path $dest -Force -ErrorAction SilentlyContinue
        throw ("Firma digital Authenticode de cloudflared.exe invalida ({0}). Descarga abortada." -f $sigStatus)
    }

    $verOut = (& $dest --version 2>&1) -join " "
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -Path $dest -Force -ErrorAction SilentlyContinue
        throw ("El binario descargado de cloudflared fallo --version (codigo {0})." -f $LASTEXITCODE)
    }

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) { $userPath = "" }
    $entries = @($userPath -split ";" | Where-Object { $_.Trim() -ne "" })
    if (-not ($entries -contains $installDir)) {
        $newUserPath = (@($installDir) + $entries) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
    }
    if ($env:Path -notlike "*$installDir*") {
        $env:Path = "$installDir;$env:Path"
    }

    Write-Host ("[OK] Cloudflare Tunnel instalado en {0} ({1})" -f $dest, $verOut) -ForegroundColor Green
    return $dest
}

$ollamaExe = Ensure-WingetPackage -CommandName "ollama" -WingetId "Ollama.Ollama" -DisplayName "Ollama" -CandidatePaths $ollamaCandidates
$cloudflaredExe = Ensure-CloudflaredBinary -CandidatePaths $cloudflaredCandidates

# 3. Configurar variables de entorno optimizadas segun perfil de VRAM
if ($Profile -eq "rtx2050_4gb") {
    $envSettings = [ordered]@{
        "OLLAMA_HOST"              = "127.0.0.1:11434"
        "OLLAMA_KEEP_ALIVE"        = "10m"
        "OLLAMA_MAX_LOADED_MODELS" = "1"
        "OLLAMA_NUM_PARALLEL"      = "1"
        "OLLAMA_FLASH_ATTENTION"   = "1"
        "OLLAMA_KV_CACHE_TYPE"     = "q4_0"
    }
} else {
    $envSettings = [ordered]@{
        "OLLAMA_HOST"              = "127.0.0.1:11434"
        "OLLAMA_KEEP_ALIVE"        = "15m"
        "OLLAMA_MAX_LOADED_MODELS" = "1"
        "OLLAMA_NUM_PARALLEL"      = "2"
        "OLLAMA_FLASH_ATTENTION"   = "1"
        "OLLAMA_KV_CACHE_TYPE"     = "q8_0"
    }
}

Write-Host ("`n=== Configurando variables de entorno VRAM ({0}) ===" -f $profileTitle) -ForegroundColor Cyan
foreach ($entry in $envSettings.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "User")
    Set-Item -Path ("Env:{0}" -f $entry.Key) -Value $entry.Value
    Write-Host ("  {0}={1}" -f $entry.Key, $entry.Value)
}

# 4. Reiniciar Ollama para garantizar que herede las nuevas variables de entorno VRAM
Write-Host "`n=== Reiniciando demonio Ollama con las nuevas variables de VRAM ===" -ForegroundColor Cyan
Get-Process -Name "ollama", "ollama app" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

Start-Process -FilePath $ollamaExe -ArgumentList "serve" -WindowStyle Hidden

$ollamaReady = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 1
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 2 | Out-Null
        $ollamaReady = $true
        break
    } catch { }
}

if (-not $ollamaReady) {
    throw "No fue posible iniciar Ollama en http://127.0.0.1:11434 tras aplicar las variables de entorno."
}

$ollamaVersion = (& $ollamaExe --version 2>&1) -join " "
Write-Host ("[OK] Ollama activo en http://127.0.0.1:11434 ({0})" -f $ollamaVersion) -ForegroundColor Green

# 5. Descargar modelo multimodal recomendado
Write-Host "`n=== Descargando modelo qwen2.5vl:3b (~3.2 GB, optimo para 8 GB VRAM) ===" -ForegroundColor Cyan
& $ollamaExe pull qwen2.5vl:3b
if ($LASTEXITCODE -ne 0) {
    throw ("Fallo la descarga del modelo qwen2.5vl:3b (codigo {0})." -f $LASTEXITCODE)
}

if ($Include7B) {
    Write-Host "`n=== Descargando modelo opcional qwen2.5vl:7b (~6.0 GB) ===" -ForegroundColor Cyan
    & $ollamaExe pull qwen2.5vl:7b
    if ($LASTEXITCODE -ne 0) {
        throw ("Fallo la descarga del modelo qwen2.5vl:7b (codigo {0})." -f $LASTEXITCODE)
    }
}

Write-Host "`n[OK] Instalacion completada. Ejecuta ahora:" -ForegroundColor Green
Write-Host "  1) powershell -ExecutionPolicy Bypass -File .\scripts\03_probar_extraccion_local.ps1" -ForegroundColor White
Write-Host "  2) powershell -ExecutionPolicy Bypass -File .\scripts\02_iniciar_servidor_ia.ps1 -Detached" -ForegroundColor White
