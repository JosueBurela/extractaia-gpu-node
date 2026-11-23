# ExtractaIA GPU Node — Servidor Local RTX 5060 (8 GB VRAM)

Repositorio dedicado para convertir una PC Windows 11 con **NVIDIA GeForce RTX 5060 (8 GB VRAM)**, **32 GB RAM** y **AMD Ryzen 5 5500X3D** en un nodo de inferencia multimodal local para **ExtractaIA API** (`https://extractaia.dburela.com`), sin abrir puertos en el router y con costo de tokens `$0.00`.

---

## 1. Arquitectura de Conexión Segura

```
Navegador / Usuario
        │
        ▼  HTTPS (TLS 1.3)
https://extractaia.dburela.com  (Oracle Cloud · Portal + Backend + Validación JSON)
        │
        ▼  Túnel Inverso Cifrado (Cloudflare Quick Tunnel, solo saliente)
127.0.0.1:11434  (PC Windows con Ollama)
        │
        ▼  CUDA / Flash Attention
NVIDIA GeForce RTX 5060 (8 GB VRAM) · Modelo qwen2.5vl:3b
```

- **Aislamiento de red:** Ollama escucha únicamente en `127.0.0.1:11434`. Ningún puerto del módem/router queda expuesto a Internet.
- **Ciclo efímero del túnel:** Al cerrar la consola o presionar `Ctrl+C`, la URL temporal `https://*.trycloudflare.com` deja de existir al instante.
- **Validación centralizada:** ExtractaIA API sanea y valida el JSON Schema fiscal, el cuadre aritmético y la estructura RFC/CURP antes de entregar la respuesta al cliente.

---

## 2. Presupuesto de VRAM para RTX 5060 (8 GB)

| Modelo en Ollama | Peso en disco | VRAM estimada (Q4 + contexto) | Ejecución en RTX 5060 (8 GB) | Latencia estimada |
|---|---|---|---|---|
| **`qwen2.5vl:3b` (Recomendado)** | ~3.2 GB | ~4.0 – 4.6 GB | **100 % en GPU VRAM** | **1 – 2.5 s / imagen** |
| `qwen2.5vl:7b` (Opcional `-Include7B`) | ~6.0 GB | ~7.6 – 8.8 GB | Parcial en GPU + respaldo en 32 GB RAM | 5 – 12 s / imagen |

---

## 3. Arranque Rápido (3 Comandos en PowerShell)

Abre PowerShell dentro de la carpeta del repositorio:

### Paso 1 — Instalar Ollama, Cloudflared, variables RTX 5060 y descargar `qwen2.5vl:3b`
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\01_instalar_nodo_gpu.ps1
```
*(Opcional: agrega `-Include7B` si deseas descargar también `qwen2.5vl:7b` como alternativa de mayor tamaño).*

### Paso 2 — Verificar inferencia local en GPU antes de exponer el túnel
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\03_probar_extraccion_local.ps1
```

### Paso 3 — Precargar VRAM e iniciar el túnel HTTPS para ExtractaIA
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\02_iniciar_servidor_ia.ps1
```

1. Copia la URL temporal `https://xxxx-xxxx.trycloudflare.com` que imprime `cloudflared`.
2. Entra a **[https://extractaia.dburela.com](https://extractaia.dburela.com)**.
3. Selecciona la tarjeta **IA Local** → **LLM Local (Ollama)**.
4. Pega la URL del túnel y confirma el modelo **`qwen2.5vl:3b`**.
5. Sube una imagen (`JPG`, `PNG` o `WebP`) de factura, ticket o receta y extrae en vivo usando tu RTX 5060.

---

## 4. Variables de Optimización (`config/rtx5060_8gb.env.example`)

- `OLLAMA_HOST=127.0.0.1:11434`: evita exposición en interfaz pública `0.0.0.0`.
- `OLLAMA_KEEP_ALIVE=15m`: mantiene el modelo caliente en VRAM entre peticiones.
- `OLLAMA_MAX_LOADED_MODELS=1`: impide cargar múltiples modelos simultáneos que saturen los 8 GB de VRAM.
- `OLLAMA_FLASH_ATTENTION=1` y `OLLAMA_KV_CACHE_TYPE=q8_0`: reducen consumo de memoria en contexto de imágenes de alta resolución.
