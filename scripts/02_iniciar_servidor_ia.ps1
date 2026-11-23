[CmdletBinding()]
param(
    [string]$Model = "qwen2.5vl:3b"
)

$ErrorActionPreference = "Stop"

Write-Host "=== ExtractaIA GPU Node · Arranque de Servidor + Túnel HTTPS ===" -ForegroundColor Cyan

# Aplicar variables de optimización en la sesión actual
$env:OLLAMA_HOST = "127.0.0.1:11434"
$env:OLLAMA_KEEP_ALIVE = "15m"
$env:OLLAMA_MAX_LOADED_MODELS = "1"
$env:OLLAMA_FLASH_ATTENTION = "1"

if (-not (Get-Command "ollama" -ErrorAction SilentlyContinue)) {
    throw "No se encontró 'ollama'. Ejecuta primero .\scripts\01_instalar_nodo_gpu.ps1"
}
if (-not (Get-Command "cloudflared" -ErrorAction SilentlyContinue)) {
    throw "No se encontró 'cloudflared'. Ejecuta primero .\scripts\01_instalar_nodo_gpu.ps1"
}

# 1. Verificar o iniciar Ollama en 127.0.0.1:11434
$running = $false
try {
    Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 2 | Out-Null
    $running = $true
} catch {
    Write-Host "Iniciando Ollama en segundo plano (127.0.0.1:11434)..." -ForegroundColor Yellow
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
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
    throw "Ollama no respondió en http://127.0.0.1:11434."
}

# 2. Warm-up: precargar el modelo en la VRAM de la RTX 5060
Write-Host ("Precargando modelo '{0}' en la VRAM de la RTX 5060..." -f $Model) -ForegroundColor Cyan
$warmupBody = @{
    model = $Model
    messages = @(
        @{ role = "user"; content = 'Responde únicamente {"status":"ready"}' }
    )
    stream = $false
    format = "json"
} | ConvertTo-Json -Depth 5

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$warmupResp = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/chat" -Method Post -ContentType "application/json" -Body $warmupBody -TimeoutSec 60
$sw.Stop()
Write-Host ("Warm-up listo en {0} ms." -f $sw.ElapsedMilliseconds) -ForegroundColor Green

# 3. Mostrar uso actual de VRAM si nvidia-smi está disponible
$nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
if ($nvidiaSmi) {
    Write-Host "`n[Estado actual de GPU / VRAM]" -ForegroundColor Cyan
    & $nvidiaSmi.Source --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader
}

# 4. Exponer túnel HTTPS efímero hacia Ollama local
Write-Host "`n=====================================================================" -ForegroundColor Yellow
Write-Host " INSTRUCCIONES PARA EXTRACTAIA (https://extractaia.dburela.com):" -ForegroundColor Yellow
Write-Host " 1) Copia la URL HTTPS 'https://xxxx.trycloudflare.com' que aparecerá abajo." -ForegroundColor White
Write-Host " 2) En el portal web selecciona: IA Local -> LLM Local (Ollama)." -ForegroundColor White
Write-Host (" 3) Pega esa URL y deja el modelo en: {0}" -f $Model) -ForegroundColor White
Write-Host " 4) Presiona Ctrl+C al finalizar la demo para cerrar el túnel al instante." -ForegroundColor White
Write-Host "=====================================================================`n" -ForegroundColor Yellow

cloudflared tunnel --url http://127.0.0.1:11434
