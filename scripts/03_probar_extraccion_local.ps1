[CmdletBinding()]
param(
    [string]$Model = "qwen2.5vl:3b",
    [string]$OllamaUrl = "http://127.0.0.1:11434"
)

$ErrorActionPreference = "Stop"

Write-Host ("=== Prueba de Extracción Local contra {0} ({1}) ===" -f $OllamaUrl, $Model) -ForegroundColor Cyan

# Verificar catálogo local de modelos
$tags = Invoke-RestMethod -Uri ("{0}/api/tags" -f $OllamaUrl.TrimEnd('/')) -Method Get -TimeoutSec 5
$modelNames = @($tags.models | ForEach-Object { $_.name })
if (-not ($modelNames -contains $Model)) {
    Write-Warning ("El modelo '{0}' no aparece en la lista exacta ({1}). Se intentará invocar de todas formas." -f $Model, ($modelNames -join ", "))
}

$endpoint = ("{0}/v1/chat/completions" -f $OllamaUrl.TrimEnd('/'))
$payload = @{
    model = $Model
    temperature = 0.1
    response_format = @{ type = "json_object" }
    messages = @(
        @{
            role = "system"
            content = 'Eres el motor de ExtractaIA. Devuelve ÚNICAMENTE JSON válido con document_type, headers (rfc_emisor, folio, fecha, subtotal, iva, total) y partidas.'
        },
        @{
            role = "user"
            content = 'Archivo: factura_prueba.pdf. Texto: FACTURA ELECTRONICA RFC_EMISOR:TSO210415AB9 FOLIO:FAC-5060 FECHA:23/11/2026 SUBTOTAL:1000.00 IVA:160.00 TOTAL:1160.00 Concepto: 2 SRV Procesamiento a 500.00 c/u.'
        }
    )
} | ConvertTo-Json -Depth 6

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$response = Invoke-RestMethod -Uri $endpoint -Method Post -ContentType "application/json" -Body $payload -TimeoutSec 45
$sw.Stop()

$content = $response.choices[0].message.content
Write-Host ("Tiempo de respuesta: {0} ms" -f $sw.ElapsedMilliseconds) -ForegroundColor Green

# Validar que el contenido es JSON parseable
$parsed = $content | ConvertFrom-Json
Write-Host "`n[JSON devuelto por el modelo]" -ForegroundColor Cyan
$parsed | ConvertTo-Json -Depth 6

$nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
if ($nvidiaSmi) {
    Write-Host "`n[VRAM utilizada en RTX 5060]" -ForegroundColor Cyan
    & $nvidiaSmi.Source --query-gpu=name,memory.used,memory.total,temperature.gpu --format=csv,noheader
}
