[CmdletBinding()]
param(
    [switch]$Include7B
)

$ErrorActionPreference = "Stop"

Write-Host "=== ExtractaIA GPU Node · Instalador RTX 5060 (8 GB VRAM) ===" -ForegroundColor Cyan

# 1. Verificar GPU NVIDIA y espacio libre en disco
$nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
if (-not $nvidiaSmi) {
    $fallbackSmi = Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    if (Test-Path $fallbackSmi) {
        $nvidiaSmi = Get-Command $fallbackSmi
    }
}

if ($nvidiaSmi) {
    Write-Host "`n[GPU detectada]" -ForegroundColor Green
    & $nvidiaSmi.Source --query-gpu=name,driver_version,memory.total,memory.free --format=csv,noheader
} else {
    Write-Warning "No se encontró nvidia-smi en el PATH. Verifica tener instalados los drivers NVIDIA Game Ready / Studio."
}

$systemDrive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
$freeGb = [math]::Round($systemDrive.Free / 1GB, 2)
Write-Host ("Espacio libre en {0}: {1} GB" -f $env:SystemDrive, $freeGb)
if ($freeGb -lt 10) {
    throw "Se requieren al menos 10 GB libres en disco para instalar Ollama y el modelo qwen2.5vl:3b."
}

# 2. Instalar Ollama y cloudflared vía winget si no están disponibles
function Ensure-WingetPackage {
    param(
        [string]$CommandName,
        [string]$WingetId,
        [string]$DisplayName
    )

    if (Get-Command $CommandName -ErrorAction SilentlyContinue) {
        Write-Host "[OK] $DisplayName ya está instalado." -ForegroundColor Green
        return
    }

    if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) {
        throw "No se encontró 'winget'. Instala manualmente $DisplayName ($WingetId)."
    }

    Write-Host "[Instalando] $DisplayName ($WingetId)..." -ForegroundColor Yellow
    winget install --id $WingetId --exact --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "Error al instalar $DisplayName con winget (código $LASTEXITCODE)."
    }
}

Ensure-WingetPackage -CommandName "ollama" -WingetId "Ollama.Ollama" -DisplayName "Ollama"
Ensure-WingetPackage -CommandName "cloudflared" -WingetId "Cloudflare.cloudflared" -DisplayName "Cloudflare Tunnel (cloudflared)"

# Refrescar PATH de la sesión actual por si winget acaba de instalar los binarios
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$env:Path = "$userPath;$machinePath"

# 3. Configurar variables de entorno optimizadas para RTX 5060 (8 GB VRAM)
$envSettings = @{
    "OLLAMA_HOST"               = "127.0.0.1:11434"
    "OLLAMA_KEEP_ALIVE"         = "15m"
    "OLLAMA_MAX_LOADED_MODELS"  = "1"
    "OLLAMA_NUM_PARALLEL"       = "2"
    "OLLAMA_FLASH_ATTENTION"    = "1"
    "OLLAMA_KV_CACHE_TYPE"      = "q8_0"
}

Write-Host "`n[Configurando variables de optimización VRAM RTX 5060 (8 GB)]" -ForegroundColor Cyan
foreach ($entry in $envSettings.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "User")
    Set-Item -Path ("Env:{0}" -f $entry.Key) -Value $entry.Value
    Write-Host ("  {0}={1}" -f $entry.Key, $entry.Value)
}

# 4. Asegurar demonio Ollama activo antes de descargar modelos
$ollamaReady = $false
try {
    Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 2 | Out-Null
    $ollamaReady = $true
} catch {
    Write-Host "`nIniciando servicio local de Ollama..." -ForegroundColor Yellow
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 2 | Out-Null
            $ollamaReady = $true
            break
        } catch { }
    }
}

if (-not $ollamaReady) {
    throw "No fue posible iniciar Ollama en http://127.0.0.1:11434."
}

# 5. Descargar modelo multimodal recomendado
Write-Host "`n[Descargando qwen2.5vl:3b (~3.2 GB, óptimo para 8 GB VRAM)]" -ForegroundColor Cyan
ollama pull qwen2.5vl:3b
if ($LASTEXITCODE -ne 0) {
    throw "Falló la descarga de qwen2.5vl:3b."
}

if ($Include7B) {
    Write-Host "`n[Descargando qwen2.5vl:7b (~6.0 GB, respaldo con 32 GB RAM)]" -ForegroundColor Cyan
    ollama pull qwen2.5vl:7b
}

Write-Host "`nInstalación completada. Ejecuta ahora:" -ForegroundColor Green
Write-Host "  1) .\scripts\03_probar_extraccion_local.ps1" -ForegroundColor White
Write-Host "  2) .\scripts\02_iniciar_servidor_ia.ps1" -ForegroundColor White
