# ANTIGRAVITY_SETUP.md — Runbook Autónomo de Despliegue GPU (`RTX 5060 8 GB`)

Guía determinista paso a paso para que **Antigravity** diagnostique, instale, valide con inferencia visual real en GPU y levante el túnel HTTPS de este equipo hacia **ExtractaIA API** (`https://extractaia.dburela.com`).

---

## 0. Objetivo y Especificaciones del Nodo

- **Hardware objetivo**: Windows 11 · **NVIDIA GeForce RTX 5060 (8 GB VRAM, Blackwell `sm_120`)** · **32 GB RAM** · **AMD Ryzen 5 5500X3D**.
- **Arquitectura de conexión**:

```text
Navegador / Evaluador
        │
        ▼  HTTPS (TLS 1.3)
https://extractaia.dburela.com   (Oracle Cloud: Portal React + Backend + Validador JSON)
        │
        ▼  Túnel Inverso Cloudflare Quick Tunnel (TCP HTTP/2 saliente, sin abrir puertos)
127.0.0.1:11434                  (Ollama local en Windows 11)
        │
        ▼  CUDA + Flash Attention + KV Cache q8_0
NVIDIA GeForce RTX 5060 (8 GB VRAM) · Modelo qwen2.5vl:3b
```

- **Presupuesto de VRAM (8 GB)**:

| Modelo | Peso en disco | VRAM estimada (`Q4` + contexto) | Ejecución en RTX 5060 | Latencia esperada |
|---|---|---|---|---|
| **`qwen2.5vl:3b` (Por defecto)** | ~3.2 GB | ~4.0 – 4.6 GB | **100 % en GPU VRAM** | **1.0 – 2.5 s / imagen** |
| `qwen2.5vl:7b` (Opcional `-Include7B`) | ~6.0 GB | ~7.6 – 8.8 GB | Parcial en GPU + respaldo en 32 GB RAM | 5 – 12 s / imagen |

---

## 1. Reglas de Seguridad y Aislamiento

- **Binding estricto**: `OLLAMA_HOST=127.0.0.1:11434`. Ninguna interfaz LAN o WAN escucha conexiones entrantes directas.
- **Túnel efímero**: `.runtime\tunnel_url.txt` contiene una URL aleatoria `https://*.trycloudflare.com` válida únicamente mientras viva el proceso `cloudflared` (`.runtime\tunnel.pid`).
- **Red compatible con escuela/universidad**: `-Protocol http2` evita bloqueos de tráfico UDP/QUIC (puerto `7844`).
- **Cero retención en disco**: Ni ExtractaIA ni `03_probar_extraccion_local.ps1` escriben documentos ni capturas de prueba en disco.

---

## 2. Fase 0 — Pre-flight (Diagnóstico Obligatorio)

Ejecuta primero este bloque de solo lectura en PowerShell dentro de la raíz del repositorio para validar prerequisitos antes de instalar nada:

```powershell
$os = (Get-CimInstance Win32_OperatingSystem).Caption
$driveName = $env:SystemDrive.TrimEnd(':')
$freeGb = [math]::Round((Get-PSDrive $driveName).Free / 1GB, 2)
$wingetOk = [bool](Get-Command winget -ErrorAction SilentlyContinue)
$ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
$cfCmd = Get-Command cloudflared -ErrorAction SilentlyContinue
$port11434 = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue

Write-Host "OS: $os | FreeDisk($env:SystemDrive): $freeGb GB | winget: $wingetOk"
Write-Host ("Ollama PATH: {0} | Cloudflared PATH: {1} | Port 11434 Listen: {2}" -f [bool]$ollamaCmd, [bool]$cfCmd, [bool]$port11434)

$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $smi -and (Test-Path "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")) {
    $smi = Get-Command "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
}
if ($smi) {
    & $smi.Source --query-gpu=name,driver_version,memory.total,memory.free --format=csv,noheader
} else {
    Write-Warning "nvidia-smi no encontrado."
}
```

### Gate de aprobación de Fase 0
- `FreeDisk` $\ge$ **`10` GB**. Si es menor, **detente** e informa al usuario cuánto espacio falta liberar.
- `nvidia-smi` reporta GPU NVIDIA (`RTX 5060` o equivalente) y `driver_version` $\ge$ **`572.xx`**. Si el driver es menor a `572`, advierte al usuario que el soporte Blackwell (`sm_120`) puede degradar a CPU si no actualiza el driver NVIDIA.
- Si `winget` es `False`, revisa la **Sección 7 (Troubleshooting)** para instalar desde enlaces oficiales.

---

## 3. Fase 1 — Instalación y Configuración VRAM RTX 5060

Ejecuta el instalador maestro desde la raíz del repositorio:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\01_instalar_nodo_gpu.ps1
```

*(Solo si el usuario pidió explícitamente el modelo grande adicional, agrega `-Include7B`.)*

### Qué realiza exactamente el script
1. Instala `Ollama.Ollama` y `Cloudflare.cloudflared` vía `winget` si faltan, resolviendo rutas típicas de Windows sin requerir reinicio.
2. Configura como variables de entorno de usuario (`[Environment]::SetEnvironmentVariable(..., "User")`) y de sesión:
   - `OLLAMA_HOST=127.0.0.1:11434`
   - `OLLAMA_KEEP_ALIVE=15m`
   - `OLLAMA_MAX_LOADED_MODELS=1`
   - `OLLAMA_NUM_PARALLEL=2`
   - `OLLAMA_FLASH_ATTENTION=1`
   - `OLLAMA_KV_CACHE_TYPE=q8_0`
3. Reinicia cualquier proceso previo de `ollama` / `ollama app` para garantizar que el servicio herede estas 6 variables VRAM.
4. Descarga el modelo **`qwen2.5vl:3b`** (~3.2 GB).

### Gate de verificación de Fase 1
Ejecuta y comprueba que `qwen2.5vl:3b` aparezca listado:

```powershell
(Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 5).models | Select-Object name, size
```

Si devuelve error o no aparece `qwen2.5vl:3b`, consulta la **Sección 7**.

---

## 4. Fase 2 — Validación Multimodal Real en GPU

Ejecuta la prueba funcional completa (texto + imagen PNG sintética generada en RAM):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\03_probar_extraccion_local.ps1
```

### Gate de verificación de Fase 2 (Critico)
1. **Test 1 (Texto → JSON)** responde JSON válido con campos fiscales (`document_type`, `headers`, `partidas`).
2. **Test 2 (Imagen PNG en RAM → Visión → JSON)** responde JSON válido procesando la imagen base64 en el mismo formato que usa el backend de ExtractaIA.
3. **`ollama ps`** confirma descarga en **GPU** (ej. `100% GPU` o porcentaje mayoritario en `GPU`).
   - **CRÍTICO**: Si `ollama ps` muestra **`100% CPU`** y `0% GPU`, **NO avances a Fase 3**; aplica de inmediato la solución para RTX 5060 Blackwell de la **Sección 7**.
4. **`nvidia-smi`** muestra incremento real de VRAM ocupada (~4 GB).

---

## 5. Fase 3 — Encendido del Túnel HTTPS (`-Detached`)

Inicia el túnel Cloudflare en segundo plano con verificación automática de extremo a extremo:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\02_iniciar_servidor_ia.ps1 -Detached
```

*(Por defecto utiliza `--protocol http2` para redes universitarias; si el usuario requiere `auto` o `quic`, pásalo con `-Protocol auto`.)*

### Gate de verificación de Fase 3
El script imprimirá `STATUS=READY`, guardará `.runtime\tunnel.pid` y `.runtime\tunnel_url.txt`, y probará `GET <TUNNEL_URL>/api/tags` y `GET <TUNNEL_URL>/v1/models`. Verifica explícitamente el archivo generado:

```powershell
$tunnelUrl = (Get-Content .\.runtime\tunnel_url.txt -Raw).Trim()
Write-Host "TUNNEL_URL=$tunnelUrl"
Invoke-RestMethod -Uri "$tunnelUrl/v1/models" -TimeoutSec 10 | ConvertTo-Json -Depth 4
```

Ambos endpoints deben responder **HTTP 200** con `qwen2.5vl:3b` listado.

---

## 6. Fase 4 — Plantilla Exacta de Entrega al Usuario

Una vez superadas las Fases 0 a 3, entrega al usuario este bloque exacto sustituyendo los valores reales medidos en las pruebas:

```markdown
Tu nodo GPU **NVIDIA GeForce RTX 5060 (8 GB VRAM)** quedó instalado, validado en **GPU** y conectado por túnel HTTPS cifrado.

### Datos para conectar en ExtractaIA
1. Abre: **https://extractaia.dburela.com**
2. Entra al laboratorio y selecciona la tarjeta **IA Local** → **LLM Local (Ollama)**.
3. En el campo de URL pega exactamente:
   `<PEGAR_AQUI_LA_URL_DE_.runtime/tunnel_url.txt>`
4. En modelo confirma:
   `qwen2.5vl:3b`
5. Sube una factura, ticket o receta (`JPG`, `PNG` o `WebP`) para demostrar la extracción corriendo directo en tu RTX 5060.

### Verificación completada en tu equipo
- **Estado GPU (`ollama ps`)**: `<RESULTADO_GPU_PERCENT>`
- **Latencia de prueba multimodal (imagen PNG)**: `<LATENCIA_TEST2_MS> ms`
- **PID del túnel (`cloudflared`)**: `<TUNNEL_PID>`

### Cómo apagar el túnel al terminar la exposición
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\04_detener_servidor_ia.ps1
```
*(Agrega `-StopOllama` si también quieres detener Ollama por completo).*
```

---

## 7. Matriz de Troubleshooting Determinista

| Síntoma | Causa raíz | Solución exacta |
|---|---|---|
| **`ollama ps` muestra `100% CPU` en RTX 5060** | Driver NVIDIA anterior a Blackwell `sm_120` (`< 572`) o versión desactualizada de Ollama. | 1) Actualizar driver NVIDIA Game Ready/Studio a $\ge 572.x$.<br>2) Ejecutar `winget upgrade --id Ollama.Ollama --exact` (o reinstalar desde `https://ollama.com/download/OllamaSetup.exe`).<br>3) Reiniciar Ollama y repetir Fase 2. |
| **`cloudflared` falla con timeout / error QUIC 7844 en Wi-Fi escolar** | Firewall institucional bloquea tráfico UDP saliente. | Ya mitigado por defecto usando `-Protocol http2`. Si se usó otro protocolo, ejecuta:<br>`.\scripts\02_iniciar_servidor_ia.ps1 -Detached -Protocol http2`. |
| **`winget` no está disponible en Windows** | App Installer no instalado en esa compilación de Windows. | Instalar binarios oficiales directamente:<br>- Ollama: `https://ollama.com/download/OllamaSetup.exe`<br>- Cloudflared (x64): `https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.msi`<br>Luego volver a correr `01_instalar_nodo_gpu.ps1`. |
| **Puerto `11434` ocupado / Ollama no aplica variables VRAM** | Ollama Tray (`ollama app.exe`) arrancó antes que el script con configuración por defecto. | Ejecutar:<br>`Get-Process "ollama","ollama app" -EA SilentlyContinue \| Stop-Process -Force`<br>y re-ejecutar `01_instalar_nodo_gpu.ps1` o `02_iniciar_servidor_ia.ps1 -Detached`. |
| **El túnel devuelve HTTP 502 o `DNS resolution failed` tras arrancar** | Propagación DNS temporal de `trycloudflare.com` o caída local de Ollama. | 1) Verificar `Invoke-RestMethod http://127.0.0.1:11434/api/tags`.<br>2) Leer últimas líneas de `.\.runtime\cloudflared.err.log`.<br>3) Reiniciar túnel con `.\scripts\04_detener_servidor_ia.ps1` y luego `.\scripts\02_iniciar_servidor_ia.ps1 -Detached`. |

---

## 8. Apagado y Desinstalación Limpia (Post-Exposición)

### Apagar solo la sesión actual (conservando Ollama listo para futuras demos)
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\04_detener_servidor_ia.ps1 -StopOllama
```

### Desinstalar todo por completo después de entregar la materia (opcional)
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\04_detener_servidor_ia.ps1 -StopOllama
ollama rm qwen2.5vl:3b
winget uninstall Ollama.Ollama
winget uninstall Cloudflare.cloudflared
foreach ($k in @("OLLAMA_HOST","OLLAMA_KEEP_ALIVE","OLLAMA_MAX_LOADED_MODELS","OLLAMA_NUM_PARALLEL","OLLAMA_FLASH_ATTENTION","OLLAMA_KV_CACHE_TYPE")) {
    [Environment]::SetEnvironmentVariable($k, $null, "User")
}
```
