# ExtractaIA GPU Node — Servidor Local RTX 5060 (8 GB VRAM)

Repositorio dedicado para convertir una PC Windows 11 con **NVIDIA GeForce RTX 5060 (8 GB VRAM)**, **32 GB RAM** y **AMD Ryzen 5 5500X3D** en un nodo de inferencia multimodal local para **ExtractaIA API** (`https://extractaia.dburela.com`), sin abrir puertos en el router y con costo de tokens `$0.00`.

---

## Instalación Automática con Antigravity (Recomendado — 1 Solo Prompt)

Si vas a habilitar la PC con **Antigravity**, no necesitas ejecutar comandos a mano: Antigravity lee automáticamente [`AGENTS.md`](./AGENTS.md) y [`ANTIGRAVITY_SETUP.md`](./ANTIGRAVITY_SETUP.md), instala **Ollama** y **cloudflared**, aplica los parámetros VRAM de la **RTX 5060**, verifica inferencia visual real en **GPU** y levanta el túnel HTTPS listo para usar.

### Pasos para el dueño de la PC
1. Abre **Antigravity** en Windows 11.
2. Copia y pega este **prompt exacto** (ya incluye el enlace real de este repositorio):

```text
Clona (o abre si ya está clonado) el repositorio https://github.com/JosueBurela/extractaia-gpu-node y configúrame esta PC Windows con RTX 5060 como nodo de IA local para ExtractaIA.
Lee obligatoriamente AGENTS.md y ANTIGRAVITY_SETUP.md dentro del repositorio y ejecuta en orden estricto las Fases 0, 1, 2, 3 y 4 sin omitir ninguna verificación:
1) Verifica disco libre, driver NVIDIA y soporte GPU (nada de correr en 100% CPU).
2) Instala Ollama + cloudflared, configura las variables VRAM RTX 5060 y descarga qwen2.5vl:3b.
3) Ejecuta .\scripts\03_probar_extraccion_local.ps1 y confirma extracción JSON válida con imagen PNG y carga en GPU.
4) Inicia el túnel desacoplado con .\scripts\02_iniciar_servidor_ia.ps1 -Detached, comprueba HTTP 200 desde el túnel y entrégame la URL exacta para pegar en https://extractaia.dburela.com junto con el comando para apagarlo al terminar.
```

3. Cuando Antigravity termine, abre **[https://extractaia.dburela.com](https://extractaia.dburela.com)** → selecciona **IA Local** → **LLM Local (Ollama)** → pega la URL `https://*.trycloudflare.com` que te entregó y deja el modelo en **`qwen2.5vl:3b`**.

> Documentación de ingeniería incluida en el repo:
> - [`AGENTS.md`](./AGENTS.md) — Reglas automáticas y guardrails de seguridad para Antigravity.
> - [`ANTIGRAVITY_SETUP.md`](./ANTIGRAVITY_SETUP.md) — Runbook técnico completo con Fases 0–4, matriz de troubleshooting y limpieza.

---

## 1. Arquitectura de Conexión Segura

```text
Navegador / Usuario
        │
        ▼  HTTPS (TLS 1.3)
https://extractaia.dburela.com  (Oracle Cloud · Portal + Backend + Validación JSON)
        │
        ▼  Túnel Inverso Cifrado (Cloudflare Quick Tunnel, HTTP/2 saliente)
127.0.0.1:11434                 (PC Windows con Ollama)
        │
        ▼  CUDA / Flash Attention / KV Cache q8_0
NVIDIA GeForce RTX 5060 (8 GB VRAM) · Modelo qwen2.5vl:3b
```

- **Aislamiento de red:** Ollama escucha únicamente en `127.0.0.1:11434`. Ningún puerto del módem/router queda expuesto a Internet.
- **Compatible con Wi-Fi universitario:** El túnel utiliza `--protocol http2` (TCP 443) por defecto para evitar bloqueos de UDP/QUIC en redes escolares.
- **Ciclo efímero del túnel:** Al detener el proceso (con `.\scripts\04_detener_servidor_ia.ps1` o `Ctrl+C`), la URL temporal `https://*.trycloudflare.com` deja de existir al instante.
- **Validación centralizada:** ExtractaIA API sanea y valida el JSON Schema fiscal, el cuadre aritmético y la estructura RFC/CURP antes de entregar la respuesta al cliente.

---

## 2. Presupuesto de VRAM para RTX 5060 (8 GB)

| Modelo en Ollama | Peso en disco | VRAM estimada (Q4 + contexto) | Ejecución en RTX 5060 (8 GB) | Latencia estimada |
|---|---|---|---|---|
| **`qwen2.5vl:3b` (Recomendado)** | ~3.2 GB | ~4.0 – 4.6 GB | **100 % en GPU VRAM** | **1 – 2.5 s / imagen** |
| `qwen2.5vl:7b` (Opcional `-Include7B`) | ~6.0 GB | ~7.6 – 8.8 GB | Parcial en GPU + respaldo en 32 GB RAM | 5 – 12 s / imagen |

---

## 3. Arranque Manual (PowerShell)

Si prefieres ejecutarlo manualmente en PowerShell desde la raíz del repositorio:

### Paso 1 — Instalar Ollama, Cloudflared, variables VRAM y descargar `qwen2.5vl:3b`
```powershell
# Desktop RTX 5060 (8 GB VRAM, perfil por defecto):
powershell -ExecutionPolicy Bypass -File .\scripts\01_instalar_nodo_gpu.ps1

# Laptop RTX 2050 (4 GB VRAM, KV Cache q4_0 + paralelismo 1):
powershell -ExecutionPolicy Bypass -File .\scripts\01_instalar_nodo_gpu.ps1 -Profile rtx2050_4gb
```
*(Opcional: agrega `-Include7B` en RTX 5060 si deseas descargar también `qwen2.5vl:7b`).*

### Paso 2 — Validar texto + imagen PNG real en GPU antes de exponer el túnel
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\03_probar_extraccion_local.ps1
```

### Paso 3 — Precargar VRAM, iniciar el túnel HTTPS y registrarse al pool interno
```powershell
# Desktop RTX 5060 (lee .env local si está configurado para auto-registro):
powershell -ExecutionPolicy Bypass -File .\scripts\02_iniciar_servidor_ia.ps1 -Detached

# Arranque directo en 1 clic para laptop RTX 2050 (4 GB VRAM):
powershell -ExecutionPolicy Bypass -File .\scripts\iniciar_laptop_rtx2050.ps1

# O en primer plano para ver la salida en vivo (cerrar con Ctrl+C):
powershell -ExecutionPolicy Bypass -File .\scripts\02_iniciar_servidor_ia.ps1
```

### Paso 4 — Apagar el túnel y dar de baja el nodo al terminar la demostración
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\04_detener_servidor_ia.ps1
# Agrega -StopOllama si deseas cerrar también el servicio Ollama
```

---

## 4. Perfiles de Hardware y Registro al Pool (`config/`)

- **RTX 5060 (8 GB VRAM)** — [`config/rtx5060_8gb.env.example`](./config/rtx5060_8gb.env.example): `OLLAMA_KEEP_ALIVE=15m`, `OLLAMA_NUM_PARALLEL=2`, `OLLAMA_KV_CACHE_TYPE=q8_0`.
- **Laptop RTX 2050 (4 GB VRAM)** — [`config/rtx2050_4gb_laptop.env.example`](./config/rtx2050_4gb_laptop.env.example): `OLLAMA_KEEP_ALIVE=10m`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_KV_CACHE_TYPE=q4_0`.
- **Auto-registro transparente**: Si existe un archivo `.env` local (ignorado por Git) con `EXTRACTAIA_REGISTER_URL` y `GPU_NODE_TOKEN`, el nodo se da de alta automáticamente en `https://extractaia.dburela.com` para atender peticiones **Doc-to-SQL** de imágenes/notas sin exponer URLs ni claves en el portal web.
