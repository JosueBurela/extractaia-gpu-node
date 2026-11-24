# AGENTS.md — Instrucciones Automáticas para Antigravity (`ExtractaIA GPU Node`)

Este archivo rige automáticamente cualquier sesión de **Antigravity** abierta dentro de este repositorio. Si el usuario te pidió instalar, habilitar, levantar o probar su PC como nodo de IA local para **ExtractaIA API** (`https://extractaia.dburela.com`), ejecuta el protocolo completo sin pedir confirmaciones innecesarias ni improvisar herramientas externas.

---

## 1. Objetivo y Perfil de Hardware

Configurar de forma autónoma esta estación **Windows 11** equipada con:
- **GPU**: **NVIDIA GeForce RTX 5060 (8 GB VRAM, arquitectura Blackwell `sm_120`)**
- **RAM**: **32 GB DDR4**
- **CPU**: **AMD Ryzen 5 5500X3D**

El nodo ejecutará **Ollama** localmente con el modelo multimodal **`qwen2.5vl:3b`** (~3.2 GB en disco, ~4.0–4.6 GB VRAM en ejecución) y lo expondrá mediante un **túnel inverso efímero de Cloudflare (`cloudflared`)** para conectar con el portal productivo **[https://extractaia.dburela.com](https://extractaia.dburela.com)** (`IA Local` → `LLM Local (Ollama)`).

---

## 2. Reglas Duras de Seguridad y Aislamiento

1. **Solo Loopback Local (`127.0.0.1`)**: `OLLAMA_HOST` debe mantenerse estrictamente en `127.0.0.1:11434`. **PROHIBIDO** configurarlo como `0.0.0.0`.
2. **Cero Puertos Abiertos**: **PROHIBIDO** crear reglas entrantes en Windows Firewall, abrir puertos en el router o modificar configuración NAT. La exposición externa se realiza únicamente mediante el túnel saliente de `cloudflared`.
3. **Cero Dependencias Pesadas**: **PROHIBIDO** instalar Python, Conda, PyTorch, CUDA Toolkit manual o HuggingFace CLI. Todo corre sobre los dos binarios oficiales (`Ollama.Ollama` y `Cloudflare.cloudflared`).
4. **Protocolo Compatible con Wi-Fi Escolar**: `02_iniciar_servidor_ia.ps1` usa `--protocol http2` (TCP 443) por defecto para evitar bloqueos de UDP/QUIC (puerto 7844) frecuentes en redes universitarias. No lo cambies a `quic` salvo diagnóstico explícito.
5. **Integridad del Sistema**: **PROHIBIDO** desactivar Windows Defender, modificar `ExecutionPolicy` permanente del sistema o guardar documentos de prueba en disco (el script `03_probar_extraccion_local.ps1` genera la imagen de prueba directamente en memoria RAM).

---

## 3. Procedimiento Obligatorio (Runbook Determinista)

Sigue **`ANTIGRAVITY_SETUP.md`** en orden estricto: **Fase 0 → Fase 1 → Fase 2 → Fase 3 → Fase 4**.

1. **Fase 0 — Pre-flight**: Ejecuta el diagnóstico inicial de solo lectura (Windows, espacio libre $\ge 10$ GB, `nvidia-smi`, versión de driver NVIDIA $\ge 572$, disponibilidad de `winget` y puerto `11434`).
2. **Fase 1 — Instalación y Variables VRAM**: Corre `powershell -ExecutionPolicy Bypass -File .\scripts\01_instalar_nodo_gpu.ps1` y verifica que `http://127.0.0.1:11434/api/tags` responda HTTP 200 e incluya `qwen2.5vl:3b`.
3. **Fase 2 — Validación Multimodal Real en GPU**: Corre `powershell -ExecutionPolicy Bypass -File .\scripts\03_probar_extraccion_local.ps1`. Debes verificar explícitamente:
   - Test 1 (texto → JSON) y Test 2 (imagen PNG generada en RAM → Visión → JSON) exitosos.
   - Salida de `ollama ps` mostrando ejecución en **`GPU`** (si aparece **`100% CPU`**, detente y aplica la matriz de troubleshooting en `ANTIGRAVITY_SETUP.md` Sección 7 antes de continuar).
4. **Fase 3 — Túnel HTTPS Desacoplado (`-Detached`)**: Corre `powershell -ExecutionPolicy Bypass -File .\scripts\02_iniciar_servidor_ia.ps1 -Detached`, lee `.runtime\tunnel_url.txt` y comprueba conectividad real desde fuera haciendo `GET <TUNNEL_URL>/api/tags` y `GET <TUNNEL_URL>/v1/models` con HTTP 200.
5. **Fase 4 — Entrega al Usuario**: Responde usando la plantilla exacta de la **Sección 6 de `ANTIGRAVITY_SETUP.md`**, entregando la URL activa `https://<slug>.trycloudflare.com`, los pasos en `https://extractaia.dburela.com` y el comando de apagado `.\scripts\04_detener_servidor_ia.ps1`.
