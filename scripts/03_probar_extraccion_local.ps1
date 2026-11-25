[CmdletBinding()]
param(
    [string]$Model = "qwen2.5vl:3b",
    [string]$OllamaUrl = "http://127.0.0.1:11434",
    [switch]$SkipVision
)

$ErrorActionPreference = "Stop"

$baseUrl = $OllamaUrl.TrimEnd("/")
Write-Host ("=== ExtractaIA GPU Node - Validacion contra {0} ({1}) ===" -f $baseUrl, $Model) -ForegroundColor Cyan

function Resolve-ToolExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [string[]]$CandidatePaths = @()
    )

    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) {
        return $cmd.Source
    }

    foreach ($candidate in $CandidatePaths) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

function ConvertFrom-LlmJson {
    param([Parameter(Mandatory = $true)][string]$RawText)

    $clean = $RawText.Trim()
    if ($clean -match "^```(?:json)?\s*([\s\S]*?)\s*```$") {
        $clean = $Matches[1].Trim()
    }
    return ($clean | ConvertFrom-Json)
}

function New-SyntheticInvoicePngBase64 {
    Add-Type -AssemblyName System.Drawing

    $bitmap = $null
    $graphics = $null
    $headerFont = $null
    $bodyFont = $null
    $stream = $null

    try {
        $bitmap = New-Object System.Drawing.Bitmap(800, 360)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $graphics.Clear([System.Drawing.Color]::White)

        $headerFont = New-Object System.Drawing.Font("Consolas", 18, [System.Drawing.FontStyle]::Bold)
        $bodyFont = New-Object System.Drawing.Font("Consolas", 13, [System.Drawing.FontStyle]::Regular)
        $brush = [System.Drawing.Brushes]::Black

        $graphics.DrawString("FACTURA ELECTRONICA", $headerFont, $brush, 32, 24)
        $lines = @(
            "RFC EMISOR: TSO210415AB9",
            "FOLIO: FAC-5060",
            "FECHA: 2026-11-23",
            "SUBTOTAL: 1000.00",
            "IVA: 160.00",
            "TOTAL: 1160.00",
            "CONCEPTO: 2 SRV Procesamiento IA 500.00"
        )

        $y = 74
        foreach ($line in $lines) {
            $graphics.DrawString($line, $bodyFont, $brush, 32, $y)
            $y += 36
        }

        $stream = New-Object System.IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return [Convert]::ToBase64String($stream.ToArray())
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($bodyFont) { $bodyFont.Dispose() }
        if ($headerFont) { $headerFont.Dispose() }
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
    }
}

$ollamaExe = Resolve-ToolExecutable -CommandName "ollama" -CandidatePaths @(
    (Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"),
    (Join-Path $env:ProgramFiles "Ollama\ollama.exe")
)

if ($baseUrl -match "^https?://(127\.0\.0\.1|localhost)(:\d+)?$") {
    $ollamaUp = $false
    try {
        Invoke-RestMethod -Uri ("{0}/api/tags" -f $baseUrl) -Method Get -TimeoutSec 2 | Out-Null
        $ollamaUp = $true
    } catch { }

    if (-not $ollamaUp) {
        if (-not $ollamaExe) {
            throw "Ollama no esta activo en $baseUrl y no se encontro ollama.exe. Ejecuta primero .\scripts\01_instalar_nodo_gpu.ps1"
        }
        Write-Host ("Iniciando Ollama automaticamente en {0}..." -f $baseUrl) -ForegroundColor Yellow
        Start-Process -FilePath $ollamaExe -ArgumentList "serve" -WindowStyle Hidden
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 1
            try {
                Invoke-RestMethod -Uri ("{0}/api/tags" -f $baseUrl) -Method Get -TimeoutSec 2 | Out-Null
                $ollamaUp = $true
                break
            } catch { }
        }
        if (-not $ollamaUp) {
            throw ("Ollama no respondio en {0} tras 20 segundos." -f $baseUrl)
        }
    }
}

# 1. Verificar endpoints de catalogo (/api/tags y /v1/models)
$tags = Invoke-RestMethod -Uri ("{0}/api/tags" -f $baseUrl) -Method Get -TimeoutSec 8
$modelsList = Invoke-RestMethod -Uri ("{0}/v1/models" -f $baseUrl) -Method Get -TimeoutSec 8

$modelNames = @($tags.models | ForEach-Object { $_.name })
if (-not ($modelNames -contains $Model)) {
    Write-Host ("[WARN] El modelo '{0}' no aparece exactamente en /api/tags ({1})." -f $Model, ($modelNames -join ", ")) -ForegroundColor Yellow
} else {
    Write-Host ("[OK] Catalogo /api/tags y /v1/models activos ({0} modelos)." -f $modelsList.data.Count) -ForegroundColor Green
}

$endpoint = ("{0}/v1/chat/completions" -f $baseUrl)
$systemPrompt = 'Eres el motor de extraccion documental de ExtractaIA API. Devuelve UNICAMENTE JSON valido con document_type, headers (rfc_emisor, folio, fecha, subtotal, iva, total) y partidas.'

# 2. Test 1 - Contrato JSON sobre texto plano
Write-Host "`n=== Test 1: Contrato JSON (Texto -> OpenAI Chat Completions) ===" -ForegroundColor Cyan
$textPayload = @{
    model = $Model
    temperature = 0.1
    response_format = @{ type = "json_object" }
    messages = @(
        @{ role = "system"; content = $systemPrompt },
        @{
            role = "user"
            content = 'Archivo: factura_prueba.pdf. Texto: FACTURA ELECTRONICA RFC_EMISOR:TSO210415AB9 FOLIO:FAC-5060 FECHA:2026-11-23 SUBTOTAL:1000.00 IVA:160.00 TOTAL:1160.00 Concepto: 2 SRV Procesamiento a 500.00 c/u.'
        }
    )
} | ConvertTo-Json -Depth 8

$sw1 = [System.Diagnostics.Stopwatch]::StartNew()
$resp1 = Invoke-RestMethod -Uri $endpoint -Method Post -ContentType "application/json" -Body $textPayload -TimeoutSec 150
$sw1.Stop()

$parsed1 = ConvertFrom-LlmJson -RawText ([string]$resp1.choices[0].message.content)
Write-Host ("[OK] Test 1 completado en {0} ms." -f $sw1.ElapsedMilliseconds) -ForegroundColor Green
$parsed1 | ConvertTo-Json -Depth 8

# 3. Test 2 - Inferencia multimodal real con PNG en memoria (cero escritura en disco)
if (-not $SkipVision) {
    Write-Host "`n=== Test 2: Inferencia Multimodal Real (PNG sintetico en RAM -> Vision) ===" -ForegroundColor Cyan
    $pngBase64 = New-SyntheticInvoicePngBase64
    $visionPayload = @{
        model = $Model
        temperature = 0.1
        response_format = @{ type = "json_object" }
        messages = @(
            @{ role = "system"; content = $systemPrompt },
            @{
                role = "user"
                content = @(
                    @{
                        type = "text"
                        text = "Analiza esta imagen (factura_vision_test.png, pagina 1/1) y devuelve unicamente el JSON."
                    },
                    @{
                        type = "image_url"
                        image_url = @{
                            url = ("data:image/png;base64,{0}" -f $pngBase64)
                        }
                    }
                )
            }
        )
    } | ConvertTo-Json -Depth 8

    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    $resp2 = Invoke-RestMethod -Uri $endpoint -Method Post -ContentType "application/json" -Body $visionPayload -TimeoutSec 150
    $sw2.Stop()

    $parsed2 = ConvertFrom-LlmJson -RawText ([string]$resp2.choices[0].message.content)
    if ($null -eq $parsed2.headers -and $null -eq $parsed2.document_type) {
        throw "La respuesta multimodal no incluyo 'document_type' ni 'headers'."
    }
    Write-Host ("[OK] Test 2 (Vision PNG en RAM) completado en {0} ms." -f $sw2.ElapsedMilliseconds) -ForegroundColor Green
    $parsed2 | ConvertTo-Json -Depth 8
} else {
    Write-Host "`n[WARN] Test 2 (Vision PNG) omitido por bandera -SkipVision." -ForegroundColor Yellow
}

# 4. Verificacion de descarga a GPU en ollama ps y VRAM en nvidia-smi
$ollamaExe = Resolve-ToolExecutable -CommandName "ollama" -CandidatePaths @(
    (Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"),
    (Join-Path $env:ProgramFiles "Ollama\ollama.exe")
)
if ($ollamaExe) {
    Write-Host "`n=== Estado de ejecucion del modelo (ollama ps) ===" -ForegroundColor Cyan
    $psOutput = @(& $ollamaExe ps 2>&1)
    $psJoined = ($psOutput -join "`n")
    Write-Host $psJoined
    if ($psJoined -match "100%\s+CPU" -and $psJoined -notmatch "GPU") {
        Write-Host "[WARN] ollama ps reporto ejecucion en 100% CPU. Actualiza Ollama y el driver NVIDIA >= 572 para habilitar RTX 5060 Blackwell (sm_120)." -ForegroundColor Yellow
    } else {
        Write-Host "[OK] Verificacion de carga GPU completada." -ForegroundColor Green
    }
}

$nvidiaSmi = Resolve-ToolExecutable -CommandName "nvidia-smi" -CandidatePaths @(
    (Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI\nvidia-smi.exe"),
    (Join-Path $env:WINDIR "System32\nvidia-smi.exe")
)
if ($nvidiaSmi) {
    Write-Host "`n=== VRAM utilizada en NVIDIA GPU ===" -ForegroundColor Cyan
    & $nvidiaSmi --query-gpu=name,memory.used,memory.total,temperature.gpu --format=csv,noheader
}
