# Plan: Port Web del cliente de Veloren

**Fecha:** 2026-10-08 (rev. 3 — tras validación de Oracle + PoC-1 verificado)
**Repo upstream:** `veloren/veloren` @ `81283b7babbadd2b9beb17f6763de2e545fff853` (copia local: `spikes/vendor/veloren`)
**Objetivo:** correr `veloren-voxygen` en wasm32 con render **WebGPU-only** y multijugador **contra servidores públicos** vía un **bridge externo** WebSocket (MVP) → WebTransport.

## Decisiones del usuario (fijan el alcance)
1. **MVP con gráficos degradados** (no paridad visual).
2. **Servidores públicos** (no modificables) → **bridge externo obligatorio**.
3. **Solo Chrome y Firefox** (WebGPU) → **sin fallback WebGL2** en el MVP.

---

## 0. Resumen ejecutivo

**PoC-1 ya verificado:** wgpu 27, backend `BROWSER_WEBGPU`, compila a wasm y **renderiza** en Chromium headless (`ADAPTER_OK::BrowserWebGpu` → `INIT_OK` → `RENDER_OK`). Ver `spikes/poc1-wgpu-triangle/`.

Hallazgos que definen el plan (grounded en el commit, y corregidos tras Oracle):

| # | Hallazgo | Impacto |
|---|---|---|
| 1 | wgpu 27 con `BROWSER_WEBGPU` funciona en wasm (PoC-1 verificado). | Render base resuelto. |
| 2 | **El geometry shader es código muerto.** `"light-shadows-geom"` está comentado en `render/renderer/shaders.rs:94`; las sombras usan vertex shaders (`light-shadows-{directed,figure}-vert`, `point-light-shadows-vert`). wgpu 27 no tiene stage de geometry. | **Riesgo #1 eliminado.** Se cae la reescritura de sombras. |
| 3 | **voxygen ya tiene un compilador naga en runtime**: `pipeline_modes.enable_naga` → `WgpuCompiler` (`renderer/compiler.rs:116-181`), que resuelve `#include` y usa `ShaderSource::Glsl`; wgpu ya viene con `features=["spirv","glsl"]` (`voxygen/Cargo.toml:68`). | **Posible evitar todo el pipeline build-time WGSL**: usar `WgpuCompiler` en wasm. |
| 4 | `PUSH_CONSTANTS` solo lo usa `PointShadowPipeline` (`pipelines/shadow.rs:240`), pero los shadow pipelines se crean **incondicionalmente** (`renderer/pipeline_creation.rs:866-880`, con TODO "skip if shadows disabled"). | Implementar ese TODO ⇒ **sin necesidad de reescribir push constants** en MVP. |
| 5 | "67 shaders" NO son unidades de traducción: se compilan por variantes con `#define` inyectado según settings (`pipeline_creation.rs:183-260`: FLUID_MODE×3, CLOUD_MODE×6, etc.). | Fijar **una** variante para web; el conteo real baja. |
| 6 | Red: `veloren-network` ya tiene TCP + QUIC y protocolo agnóstico de transporte. **Servidor default escucha TCP** (`server/src/settings/mod.rs:214-218`). Sin keepalive de protocolo; el cliente manda `PingMsg` cada 1s (`client/src/lib.rs:671`). `ENCRYPTED` no se usa en producción. | **Relay byte-transparente WS↔TCP es viable.** |
| 7 | **Riesgo #1 real = seam tokio/`Instant`.** `participant.rs` (`tokio::time::interval` 5ms, `tokio::time::sleep`, `tokio::spawn`), `scheduler.rs`, `api.rs` (`runtime.spawn`, `Handle::try_current`, `std::thread::sleep`) y `std::time::Instant` (paniquea en wasm, `tcp.rs:68`, `client/src/lib.rs`) están hard-wired. **Confirmado a nivel compilación:** `cargo check --target wasm32-unknown-unknown` sobre el grafo de `veloren-network` falla con 48 errores en **`mio`** (`tokio/net` + `socket2` son host-only). | **Mayor refactor oculto; puede romper la estimación.** |
| 8 | **Falta el flujo de auth en wasm**: `client/src/lib.rs:1136-1190` hace HTTPS al auth server; en browser muere por cliente HTTP bloqueante + **CORS**. | Requiere proxy de auth en el bridge (no estaba en el plan). |
| 9 | Assets voxygen: **372.7 MB**, de los cuales **285 MB son OGG** (audio muerto en wasm igual). Set MVP ≈ **87 MB** (fonts 37.7, vox 22.8, jpg 17). | Fetch HTTP + Cache Storage; **nunca** embed en el wasm. |

**Estrategia (revisada):**
1. **Render WebGPU-only** (PoC-1 OK).
2. **Shaders: probar primero el camino naga runtime existente** (`WgpuCompiler`); build-time GLSL→SPIR-V→WGSL queda como fallback. Reescribir `WgpuCompiler` para wasm (hoy usa un `tokio::runtime::Runtime` por shader, `compiler.rs:174-176`).
3. **Push constants: no se tocan**; se evitan gateando la creación de shadow pipelines (TODO existente) y `required_features` condicional.
4. **Red: bridge dumb-pipe** (NO reusar `veloren-network` en el bridge). Auth vía proxy en el bridge.
5. **#1 prioridad de trabajo: el seam tokio/`Instant`** (fork/patch del orquestador de `veloren-network`).
6. **MVP degradado**: sin sombras, sin nubes volumétricas, sin SSR, sin MSAA, FXAA; una sola variante de shaders.

> **Estimación:** MVP jugable ≈ **4–6 dev-meses**, con el seam tokio y el auth como principales riesgos de schedule. Spikes §11 pueden reducirlo.

---

## 1. Alcance

**Dentro:** `veloren-voxygen` en wasm en Chrome/Firefox (WebGPU); render degradado; UI usable; conexión a **servidores públicos** vía bridge WS (y WT después); assets por HTTP+IndexedDB/Cache; settings en localStorage.

**Fuera:** fallback WebGL2; paridad visual; tocar/deployar el server; port de `server/`, `world/`, `rtsim/`; cuentas propias; touch como requisito; browser→server directo.

---

## 2. Arquitectura objetivo

```
Browser wasm ── wss:// ──► Bridge (nuestro, Rust nativo) ── TCP ──► Server público Veloren
  veloren-voxygen            - dumb pipe: WS<->TCP (tokio+tokio-tungstenite)
  wgpu BROWSER_WEBGPU        - proxy /auth (CORS) hacia el auth server
  WgpuCompiler(enable_naga)  - auth de conexión en la capa WS (URL token / Origin)
```

**Bridge = relay de bytes puro.** NO usa `veloren-network` (eso terminaría el protocolo y contradice el relay). 1 conexión WS = 1 conexión Veloren: el protocolo ya multiplexa sus `Stream` con framing propio; los frames son autodelimitados (`network/protocol/src/frame.rs`; Data ≤64 KB por prefijo `u16`). Nada de bytes extra antes del handshake (el server los lee como `InitFrame::Raw` y corta: `handshake.rs:125-131`).

---

## 3. Fase 0 — Fundaciones (HECHO parcialmente)

- Toolchain wasm: **usar `1.88.0`** (tiene `wasm32-unknown-unknown`; el download de rust-lang está a ~2.5 KB/s). `rustup run 1.88.0 cargo build --target wasm32-unknown-unknown`.
- `wasm-bindgen` CLI 0.2.128, `wasm-pack`, node. Faltan `trunk`, `wasm-opt`, `cmake` (instalar si se usa `shaderc`).
- PoC-1 y su `build.sh` como plantilla. Serve con `python3 -m http.server`.
- CI: job wasm.

---

## 4. Fase 1 — Abstracción de plataforma

| Área | Nativo | wasm |
|---|---|---|
| Tiempo | `std::time::Instant` | `web-time` (Instant paniquea en wasm; swap codebase-wide) |
| FS/settings | `directories` | `localStorage` / IndexedDB |
| Executor | `tokio` multi-thread | `wasm-bindgen-futures` + timers (`gloo-timers`) |
| Hilos/paralelo | `rayon`, `std::thread` | single-thread (luego `wasm-bindgen-rayon` + COOP/COEP) |
| Loop | `winit` Poll | winit web + rAF |
| Panic | `tracing` stdout | `console_error_panic_hook` |

---

## 5. Fase 2 — Assets

- `Source` alternativa con `fetch` async + **Cache Storage/IndexedDB**.
- Set MVP sin OGG (≈87 MB). Pantalla de carga con progreso.
- Deshabilitar `ReloadWatcher`. Formatos OK en wasm: `image`, `dot_vox`, RON, `flate2`, `lz-fear`.

---

## 6. Fase 3 — Render

### 6.1 Backend/features
- `Backends::BROWSER_WEBGPU` (PoC-1 OK).
- `required_features` **condicional** (`renderer/mod.rs:330-340`): sin `PUSH_CONSTANTS`/`DEPTH_CLIP_CONTROL` si no hay point-shadows/shadow pipelines; sin timers si el profiler está gateado; `POLYGON_MODE_LINE` ya es condicional.
- `max_texture_dimension_2d = min(adapter, 8192)`; verificar `maxUniformBufferBindingSize` vs el UBO más grande (Globals es chico).
- Gaps WebGPU ya cubiertos sin trabajo: bind groups ≤4 en todos los pipelines (fits default 4); depth sampling ya non-filtering/comparison (`clouds.rs:58-73`, `shadows.glsl`); sin R32Float sampleado; storage solo read-only (`sprite.rs:201`); sin indirect draws.

### 6.2 Shaders — **probar naga runtime primero**
- `pipeline_modes.enable_naga` (`pipeline_creation.rs:316`) ya existe; en web wgpu traduce IR→WGSL internamente. Resuelve también los `#define` de variantes.
- **Bloqueante del camino naga:** `WgpuCompiler::create_shader_module` crea un `tokio::runtime::Runtime` por shader para `block_on(pop_error_scope)` (`compiler.rs:174-176`) → reescribir a async/callback para wasm.
- **Fallback** si naga glsl-in falla: build-time GLSL→SPIR-V (shaderc host, replicando la inyección de defines) → embeber SPIR-V → `ShaderSource::SpirV` en web (naga spv-in es el front maduro; el feature ya está habilitado).
- Constructos más riesgosos: `textureProj`/`textureGrad` sobre `sampler2DShadow/CubeShadow` (`include/shadows.glsl:47,58`) — fuera de alcance al cortar sombras en MVP.
- **Fijar una variante** (`PipelineModes`) para web y bloquear la UI de settings (evita recompilación combinatoria en runtime).
- **Spike VERIFICADO (offline, host):** traduje 16 shaders reales con `naga` (glsl-in→wgsl-out): **16/16 OK** (mapeando el include `anti-aliasing.glsl` al variant `antialias/fxaa.glsl` = "pin de variante"). Único ajuste de código: `isinf()` → `abs(x) > 3.4e38` (WGSL no tiene `isInf`); está en `include/srgb.glsl:89` (1 línea, afecta a casi todos). Ver `spikes/poc1-wgpu-triangle/examples/translate.rs`.

### 6.3 MVP degradado — recortes
- Settings-level: `ShadowMode::None/Cheap`, `CloudMode::Flat/Minimal`, `ReflectionMode::Low`, `FluidMode::Low`, `AaMode::Fxaa`, `BloomMode::Off`, view distance baja (`settings/graphics.rs:98-212`).
- **Refactor chico obligatorio para que el corte sea real:** implementar el TODO de `pipeline_creation.rs:866-880` (no crear shadow pipelines si sombras off) y lo mismo para rain-occlusion (`:881-885`); gatear `wgpu_profiler`.
- Efectos de `ClampToBorder→ClampToEdge`: smear en borde del mapa LOD (`lod_terrain.rs:160-162`); aceptable degradado.

---

## 7. Fase 4 — Red

### 7.1 Bridge (dumb pipe)
- `tokio` + `tokio-tungstenite` + TLS (`tokio-rustls`), frames binarios; `tokio::net::TcpStream` hacia el server público (default TCP).
- `TCP_NODELAY` ambos lados; buffering acotado (await del send WS antes de leer más TCP); mapear WS Close ↔ TCP shutdown; WS-ping cada 20-30s.
- Auth de conexión en la capa WS (token en URL / `Origin`), **nunca** prefijo de bytes.
- **Proxy `/auth`** hacia el auth server con headers CORS (el cliente wasm rutea authc por ahí, manteniendo la authority lógica para `auth_trusted`).
- Riesgo operativo: todos los usuarios salen con la IP del bridge → bans/fail2ban/abuso la afectan a todos.

### 7.2 Cliente wasm
- Transporte WS sobre `web_sys::WebSocket` implementando `UnreliableDrain`/`UnreliableSink` del protocolo (`network/protocol/src/tcp.rs:24-53,98-226`).
- **Reemplazo del executor/time en `veloren-network`** (ver §0 #7): `participant.rs:88-89,257,282,461,674,708`, `scheduler.rs:157,403`, `api.rs:317-318,1174-1178,1201`; `Instant` en `tcp.rs:68` y `client/src/lib.rs:215-355`.
- **Compilación wasm confirmada imposible tal cual:** `mio` falla (48 errores) por `tokio/net` + `socket2`. Fix: quitar la feature `net` de tokio en el target wasm, gatear `socket2`/`quinn`, y aportar el transporte WS (`web_sys::WebSocket`) implementando `UnreliableDrain`/`UnreliableSink`. Verificado con crate aislado (`/tmp/opencode/nettest`) que depende solo de `veloren-network` por path (evita el 503 del índice de `wasmtime` de `common/state`).
- `binaryType=ArrayBuffer`; backpressure con `bufferedAmount`.
- COMPRESSED (lz4, `network/src/message.rs:40-54`) y CONSISTENCY: in-band, compatibles con WS (confiable/ordenado).
- **Diseño concreto de M3 (transporte WS):** agregar variante `Protocols::Ws((TcpSendProtocol<WsDrain>, TcpRecvProtocol<WsSink>))` en `network/src/channel.rs`; las traits ya existen (`SendProtocol`/`RecvProtocol`/`UnreliableDrain`/`UnreliableSink`, `network/protocol/src/lib.rs:110-167`). `WsDrain`/`WsSink` envuelven `web_sys::WebSocket` (`binaryType=ArrayBuffer`) y **reusan el framing** de `TcpSendProtocol`/`TcpRecvProtocol`. Gatear el transporte host con `#[cfg(not(target_arch="wasm32"))]`: `socket2` (12 refs, `channel.rs`), `tokio::net` (1 ref, `channel.rs:91`), `quinn` (24 refs, `channel.rs`/`api.rs`). Sin `net` en tokio para wasm.
- **M3 slice VERIFICADO (compile-proof):** `veloren-network-protocol` compila para wasm32 con `nightly` + `getrandom/wasm_js` (`RUSTFLAGS='--cfg getrandom_backend="wasm_js"'`), y un `WsDrain`/`WsSink` sobre `web_sys::WebSocket` que implementa `UnreliableDrain`/`UnreliableSink` compila para wasm32. Los `ProtocolError` posibles son `Custom(E)` y `Violated` (`protocol/src/error.rs:17`). Diseño Send-safe: el `WebSocket` (no-`Send`) lo posee un `spawn_local` task; el drain/sink solo usan canales. Código: `/tmp/opencode/wstest/src/lib.rs`.

### 7.3 WebTransport (post-MVP)
- `wtransport` en el bridge, `web_sys::WebTransport` en el cliente; streams QUIC por `Sid` + datagrams (requiere implementar el camino unreliable hoy `unimplemented!()`).

---

## 8. Fase 5 — Audio, Input, UI

- **Audio:** kira+cpal **SÍ compilan** para wasm32 (verificado: `cpal` 0.15.3/0.17.1, `kira` 0.12). El runtime (backend de audio del browser) sigue sin verificar → MVP puede ir sin audio o validar Web Audio.
- Input: winit web OK; `gilrs` 0.11.2 **compila** para wasm (verificado); runtime Gamepad API a validar.
- UI: `egui`+`egui-wgpu` soporta web; **`conrod_core` (fork Veloren) COMPILA para wasm32** (verificado: `conrod_derive` desde gitlab fork). El renderer de conrod es código wgpu propio → port con el mismo camino de shaders.
- Build detail: `--no-default-features` para wasm (fuera `discord-sdk`, `hot-reloading`, `shaderc-from-source`).
- **Build matrix VERIFICADA (compile-proof wasm32):** `gilrs`, `cpal`, `kira`, `conrod_core` compilan (`/tmp/opencode/matrix`, nightly). Sin bloqueantes de compilación en deps de UI/input/audio.

---

## 9. Hitos y estimación

| Hito | Contenido | Salida | Est. |
|---|---|---|---|
| **M0** | Fundaciones + PoC-1 | ✅ HECHO (RENDER_OK) | — |
| **M1** | Plataforma (time/executor/fs) + assets + menú | Menú renderiza en web | 4–6 sem |
| **M2** | Shaders (naga runtime) + recortes MVP + features condicionales | Mundo renderiza degradado | 5–8 sem |
| **M3** | Bridge dumb-pipe + proxy auth + cliente WS + **seam tokio/Instant** | **MVP jugable en server público** | 6–9 sem |
| **M4** | Audio/input/UI | Experiencia básica completa | 3–5 sem |
| **M5** | WebTransport + datagrams | Netcode de baja latencia | 3–5 sem |

**MVP jugable = M3 ≈ 15–23 sem ≈ 4–6 dev-meses.** El seam tokio (M3) es el mayor riesgo de schedule.

---

## 10. Riesgos y mitigaciones

| Riesgo | Prob. | Imp. | Mitigación |
|---|---|---|---|
| **Seam tokio/`Instant` en `veloren-network`** | Alta | Alto | Fork/patch del orquestador; executor wasm-native; swap de `Instant`; spike #2 |
| **Auth/CORS en browser** | Alta | Alto | Proxy `/auth` en el bridge |
| naga runtime no renderiza en web | Media | Alto | Fallback build-time SPIR-V; feature `spirv` ya activo |
| `WgpuCompiler` usa runtime tokio por shader | Alta | Medio | Reescribir a async/callback |
| Relay (framing/backpressure/keepalive) | Baja-Media | Alto | Dumb pipe + bounded buffers; spike #2 |
| IP compartida del bridge (bans/abuso) | Media | Medio | Auth en WS, rate-limit, revisar ToS de servers target |
| `conrod` no porta | Media | Medio | Migrar UI a egui por pantallas |
| `gilrs` wasm | Baja | Bajo | Gate |
| Tamaño wasm / load | Media | Medio | `wasm-opt`, fetch assets, Cache Storage |
| Firefox WebGPU por OS | Media | Medio | Verificar OS objetivo (Firefox shipped Windows primero) |
| Single-thread performance | Media | Medio | Medir; luego `wasm-bindgen-rayon` + COOP/COEP |

---

## 11. Spikes (orden de Oracle)

1. **Test nativo `enable_naga` (1 día):** activar `pipeline_modes.enable_naga`, cargar mundo, comparar con shaderc. **Decide toda la estrategia de shaders**; si pasa, se cae casi toda §6.2.
2. **Spike protocolo headless wasm (3-5 días) — el más importante:** swap `Instant`, transporte WS, loop de participant wasm-native, bridge dumb-pipe, conectar a un server público, handshake + auth vía proxy + lista de personajes. Sin render. De-riska executor + relay + CORS de una.
3. **WebGPU smoke en Firefox (1 día):** PoC-1 ya OK en Chromium; repetir en Firefox/OS objetivo. Confirmar que el backend web acepta `ShaderSource::Glsl`/`SpirV`.
4. **Auditoría de assets (½ día):** medir set sin audio, layout fetch/Cache Storage, chequear UBO vs `maxUniformBufferBindingSize`.
5. **Diseño anti-abuso del bridge (½ día):** token en WS, rate-limit, `Origin`, ToS de los servers target.

---

## 12. Estado actual / próximos pasos

**Hecho:**
- Entorno wasm resuelto (nightly 1.98 + wasm32; `getrandom/wasm_js`).
- **PoC-1 verificado**: `spikes/poc1-wgpu-triangle/` → `RENDER_OK` (wgpu WebGPU renderiza en wasm).
- **Shaders**: naga GLSL→WGSL **16/16** (fix `isinf` en `srgb.glsl` + pin del variant antialias).
- **M3 refactor + compile-proof**: `veloren-network` **compila para wasm32** (+209/−29 en 5 archivos) con transporte WS.
- **Executor seam implementado** (módulo `rt`: spawn/task/timers; tokio en nativo, `spawn_local`+`gloo-timers` en wasm); compila nativo Y wasm; `Network::new` sin `&Runtime` en wasm.
- **Build matrix**: `gilrs`/`cpal`/`kira`/`conrod_core` compilan para wasm.
- **✅ STACK COMPLETO VALIDADO A RUNTIME**: cliente nativo → server real `192.168.88.153:14004` = `CONNECTED`; **cliente wasm → bridge WS↔TCP → server real = `CONNECTED:WJiwP3`** (Chromium vía CDP). Artefactos: `/tmp/opencode/{bridge,wasmnet,nativeclient,wstest}`.
- Fixes de runtime cazados por la validación en browser: (a) `connect()` WS debe esperar el evento `open` (si no, el primer `send` se pierde); (b) `b2a_stream_opened_s.send().unwrap()` paniqueaba en teardown → `let _ =`.
- **✅ Runtime estabilizado**: el panic intermitente era `b2a_stream_opened_s.send().unwrap()` en teardown (`participant.rs:550`) → `let _ =`. Verificado: **5/5 corridas limpias** + conexión sostenida 25s sin excepción.

**Nota de entorno:** el build nativo/wasm completo de Veloren requiere `cmake` (para `shaderc`) y el workspace completo (afectado por 503 de `wasmtime-wasi`); se evitó con crates aislados por path y el toolchain nightly.

**Siguiente:** (1) estabilizar el runtime (re-entrancia `spawn_local`/teardown); (2) auth/CORS (proxy `/auth` en el bridge); (3) assets; (4) resto del cliente (UI/render con el `WgpuCompiler`/naga).

---

### Apéndice A — Datos duros verificados
- Versiones: `wgpu 27.0.1`, `winit 0.30.13`, `specs 0.20.0`, `shaderc 0.10`, `kira 0.12`, `egui 0.33`, `gilrs 0.11`, `dot_vox 5.1`.
- Render: forward multi-pasada; `required_features = DEPTH_CLIP_CONTROL | ADDRESS_MODE_CLAMP_TO_BORDER | PUSH_CONSTANTS | POLYGON_MODE_LINE(opt) | timers`; `max_texture_dimension_2d = min(adapter,8192)`; sin compute; atlás 2D; instancing.
- Shaders: 67 GLSL; set activo vertex/fragment; **sin geometry** (`shaders.rs:94` comentado); `push_constant` solo en `point-light-shadows-vert` y `premultiply-alpha-vert` (este último no usado por el pipeline de sombras).
- Red: `network/protocol/src/{tcp,quic,frame,types,handshake}.rs`, `network/src/{api,scheduler,participant,message}.rs`, `common/net/src/msg/*`; handshake `InitFrame` magic `VELOREN` v `[0,6,0]`; server default TCP.
- wgpu web: `BROWSER_WEBGPU` verificado en Chromium headless (PoC-1). WebTransport Baseline 2026-03 (~91%); `quinn`/`wtransport` solo nativos.
