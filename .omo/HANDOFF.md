# Handoff — Port web de Veloren (cliente en el browser)

> Sesión previa enorme: se armó el plan, se de-riskeó todo, y se llegó a **loguear en el server real desde wasm**. Este MD tiene el estado y los pendientes exactos para seguir en una sesión nueva.

---

## TL;DR — dónde estamos

El cliente wasm **completa `Client::new` (login + sync inicial) contra el server real**:
```
wasm (veloren-client) → WS → bridge (axum) → server Veloren real
  ✅ connect → ✅ handshake → ✅ auth → ✅ register
  → ✅ ServerInit::GameSync → stage:StartingClient
  → ✅ State::client (ECS serial, sin Rayon/pools)          ← PENDIENTE #1 RESUELTO
  → ✅ web-time (Instant/SystemTime)                        ← PENDIENTE #2 RESUELTO
  → ✅ Client::new → CLIENT_OK   (harness: title `CLIENT_OK`, `__status='done'`)
```

**Pendientes #1 y #2 COMPLETADOS.** `Client::new` retorna OK en el browser. Falta el **loop de
juego/tick + render/UI** (Pendiente #3) y limpiar un `400 Bad Request` que aparece durante init.

---

## PENDIENTES (en orden)

### 1. ECS single-thread fallback ✅ HECHO

`veloren-client` compila a wasm (0 errores) y `State::client` se construye sin panic
(`State::pools` ya no existe en wasm). Nativo sigue compilando
(`cargo check -p veloren-{common,common-state,common-systems,rtsim,client}` OK).

Cambios (todo `cfg wasm`, nativo intacto):
- `common/state/src/state.rs`: `Pools = ()` en wasm; `pools()` stub; `with_pool` sólo nativo;
  campo `thread_pool: Pools`; `setup_ecs_world(thread_pool: &Pools)`.
- `common/src/slowjob.rs`: `SlowJobPool` serial en wasm (jobs inline); internals rayon sólo nativo.
- `common/src/store.rs`: `par_iter_mut` serial en wasm.
- `common/systems/src/serial_join.rs` (NUEVO, cfg wasm): shim `ParJoinSerial`/`SerialJoin` que emula
  `.par_join()` + `filter`/`map`/`map_init`/`for_each_init`/`fold`/`reduce` sobre `JoinIter`.
  → los 4 sitios de `common/systems` (phys 389/724/861, buff 100, beam 139, interpolation 48/60/72)
  usan el mismo `.par_join()` sin tocar el body.
- `rtsim/src/rule/npc_ai/mod.rs`: trait `SliceParIterMut` (Vec) en wasm.

### 2. wasm: `std::time::Instant`/`SystemTime` → `web-time` ✅ HECHO
- `std::time::Instant::now()` paniqueaba en wasm (abort). Barrido completo en el grafo wasm:
  `client/src/lib.rs`, `common/ecs/src/system.rs`, `common/state/src/state.rs`,
  `common/src/{clock.rs, slowjob.rs, comp/{chat,loot_owner,presence,invite}.rs}`.
- Patrón aplicado: `use web_time::Instant;` (sin cfg; en nativo web-time re-exporta std).
  `Duration` sigue de std. Dep `web-time = "1"` agregada a `common`, `common/ecs`, `common/state`, `client`.
- Resultado: **`Client::new` → CLIENT_OK** en el browser.

### 3. Port de `voxygen` a wasm (render + UI + assets + input/audio) — GRANDE (M1/M2/M4 del plan)
`voxygen` NO tiene ningún `cfg(wasm32)` hoy. Mapa del seam (explore 2026-10-09):
- **wgpu init**: `render/renderer/mod.rs:198` `Renderer::new(window: Arc<winit::Window>, mode, runtime: &tokio::Runtime)`. Backends `PRIMARY|SECONDARY` (hay que `BROWSER_WEBGPU`), `create_surface(window)` (en web: canvas), `request_adapter/request_device` con `runtime.block_on` (en wasm: `.await`). `required_features` incluye `PUSH_CONSTANTS` (gatear con el TODO de shadow pipelines).
- **Compilador de shaders**: `render/renderer/compiler.rs` — `WgpuCompiler` (naga, GLSL directo) vs `ShaderCCompiler` (shaderc, host-only). `enable_naga=true` por defecto. **Bloqueante**: `WgpuCompiler::create_shader_module` hace `tokio::runtime::Runtime::new().unwrap()` por shader (`compiler.rs:174`) → reescribir a `.await`/callback.
- **Assets**: global `AssetCache` = `FileSystem` (FS bloqueante, canary) en `common/assets/src/fs.rs:19` + `ASSETS_PATH` (`lib.rs:340`). En wasm: `Source` por `fetch`+Cache Storage (o embed). Set MVP ~87MB (sin OGG).
- **Loop/window**: `main.rs` (tokio multi-thread, `num_cpus`, `userdata_dir`, audio, clipboard, gilrs), `run.rs:35` (winit `event_loop.run` closure, `ControlFlow::Poll`), `window.rs:260` (`Window::new`: winit + `Renderer::new` + `Gilrs::new`).
- **UI**: `conrod_core` (propio backend wgpu en `ui/mod.rs:399`) + `iced_native` (`ui/ice/`) + `egui` (feature). `window_clipboard` en `ui/ice/winit.rs:17`. Compilan a wasm (verificado en el plan), pero el input viene de winit.
- **Host-only a gatear**: `shaderc`, `wgpu-profiler`, `gilrs`, `kira`/`cpal`, `window_clipboard`, `directories-next`, `native-dialog`, `open`, `mumble-link`, `discord-sdk`, `tokio rt-multi-thread`, `num_cpus`, `singleplayer`.

**Cortes propuestos (orden):**
- **3.0 (de-risk) ✅ HECHO:** `spikes/poc2-veloren-glsl-wasm/` — compila **16/16 shaders GLSL reales de Veloren** con el naga de wgpu *dentro del wasm* (`ShaderSource::Glsl` + `create_shader_module_trusted` + error scope) y renderiza (`GLSL_OK:16/16 RENDER_OK` en Chromium/WebGPU vía CDP). **Hallazgo real:** el `#define isinf(x) (abs(x) > <umbral>)` debe usar un umbral **≤ `f32::MAX`** (`3.4e38`); con `3.402823466e38` naga emite un literal `34028235e33f` que **excede f32** y el parser WGSL del browser lo rechaza. El test host (naga GLSL→WGSL) NO lo detectaba porque no re-parseaba el WGSL. Fix aplicado en `examples/translate.rs`.
- **3.1 Assets wasm ✅ HECHO:** `common/assets/src/web.rs` — `WebSource` (in-memory, modelo `(id,ext)`) + `preload(base_url, manifest, on_progress)` async con **Cache Storage** (`caches.open("veloren-assets")` + `match`/`add`) + `load_manifest(url)` + `ASSETS` global usa `WebSource` en wasm. Validado con `spikes/poc3-assets-wasm/` (manifest de 75 archivos + barra de progreso): `ASSETS_OK:320:334:9366:16341`; 2ª corrida = **0 requests al server** (todo desde Cache Storage). Nativo y wasm-client 0 warnings.
  - **Assets reales ✅ (paso 3):** el clone era **sparse** (`core.sparseCheckout`, solo `assets/voxygen/shaders`) + `blob:none`. Se instaló **git-lfs 3.8.0** en `~/.local/bin` (sin sudo) + `git sparse-checkout add assets` → **450MB de assets reales** (4752 vox, 2855 ron, 1342 ftl, 898 png, 639 ogg, 42 jpg, 13 ttf). `git status` sin modificaciones masivas; los cambios de código intactos. Para el MVP web excluir OGG (~285MB) del manifest.
- **3.2 Render core wasm ✅ COMPILA:** `veloren-voxygen` (lib: render+UI+audio+menu) **compila a wasm32 con 0 errores y 0 warnings** (probe `/tmp/opencode/voxprobe`), y nativo `--no-default-features` 0 warnings.
  - Gating hecho: `shaderc` opcional (+feature; `render/error.rs`, `compiler.rs`, selector), `tokio` per-target, `tracing-appender`→nativo, `mumble-link`→nativo, `open`→nativo, `window.rs` wayland, `hud`/`session`/`audio` `Instant`→`web_time` (+dep), audio `soundcache.rs` streaming→nativo + `pop_cpu_usage`→nativo. **iced vendeado** en `spikes/vendor/iced` + `[patch]` (3 fixes wasm). **`Renderer::new`**→`async new_inner` + wrappers (nativo `block_on` / wasm `.await`), `BROWSER_WEBGPU`, `enumerate_adapters` solo nativo. **`Window::new`**→`create_window`+`assemble` + wrappers sync/async. **`client_init`**→`run_init` async + `spawn_local` en wasm. **`pipeline_creation`**→`ParallelTasks::run` con pool opcional (serial en wasm) + `recreate_pipelines` inline.
  - **Entry wasm + runtime ✅ (parcial):** `voxygen/src/web.rs` (`start()` → `preload` → `Window::new` → `GlobalState` → `run::run`) + harness `spikes/voxharness/` (cdylib `voxclient`). En el browser: **preload 10015 assets** (fetch+Cache Storage, best-effort), i18n, window+renderer OK, **entra al event loop** (winit-web/rAF; "exceptions for control flow" es normal). Se gatearon además: `Settings::default` (sin `directories-next`), `SpriteRenderContext` (thread→inline), `initial_create_pipelines`/`recreate_pipelines` (rayon→inline), `ClampToBorder`→`ClampToEdge`, `instant` feature `wasm-bindgen` (link), `WgpuCompiler` inyecta `#define isinf` (naga WGSL no soporta isinf).
  - **Progreso runtime:** ✅ rain off, ✅ `ClampToBorder`, ✅ canvas, ✅ push-constant gateado (dummy shader + pipelines `Option`), ✅ dummy shadow clear, ✅ `iced_native` `Instant`→`web_time` (click/debug), ✅ **`spin_sleep::sleep` gateado** (`clock.rs:152` — era el panic `std::time::Instant` en wasm). **El loop de juego CORRE frames continuamente sin panic** (log `frame Some`).
  - **✅ HITO VISUAL: el login/menú RENDERIZA en el browser.** Causa del "negro" era el flag del browser: `--use-angle=swiftshader` forzaba **software rendering** (ignoraba la iGPU). Con la **GPU real** (Ryzen integrada, Vulkan) renderiza. **Lanzar Chromium SIN `--use-angle=swiftshader`** + `--enable-unsafe-webgpu --enable-features=Vulkan --ignore-gpu-blocklist`.
  - **Auth proxy:** `voxygen/src/web.rs` llama `client::set_auth_proxy("http://127.0.0.1:9100/auth")` (el bridge). Para loguear en el menú: Server = `ws://127.0.0.1:9100/ws`.
  - **Falta:** (a) probar login real desde el menú → selección de personaje → mundo. (b) performance (single-thread).
  - **Nota:** el `[patch]` de iced y los gates de Cargo deben replicarse en el workspace root al integrar (no solo en el probe).
- **3.3 Window/loop:** winit-web o loop propio con rAF; sin gilrs/audio/discord/singleplayer; settings en localStorage (M1/M4).
- **3.4 UI:** conrod/iced en wasm; menú → mundo (M1/M4).
- **3.5 MVP degradado:** recortes de settings (sin sombras/nubes/SSR/MSAA) + implementar TODO de `pipeline_creation.rs` (no crear shadow pipelines) (M2).

**Hecho ya:** `wasm-opt` no está instalado; pero el perfil release (`opt-level="z"` + `lto="thin"` + `codegen-units=1` + `strip` + `panic="abort"`) bajó el wasm del harness **11.15 MB → 5.40 MB** (verificado CLIENT_OK). **3.0 (spike shaders 16/16) y 3.1 core (assets WebSource+fetch) HECHOS.**

### 4. Mejoras del bridge
- TLS (`wss://`), auth de conexión en WS, rate-limit, `Origin`.

---

## ENTORNO Y BUILD (crítico — leer)

- **Toolchain:** `nightly-2026-06-13` (el pinneado por el workspace), con target `wasm32-unknown-unknown`. Instalado con:
  `rustup toolchain install nightly-2026-06-13 --profile minimal --target wasm32-unknown-unknown`
- **RUSTFLAGS obligatorio:** `--cfg getrandom_backend="wasm_js"` (getrandom 0.3/0.4).
- **`CARGO_WORKSPACE_DIR`:** `common-base` hace `env!("CARGO_WORKSPACE_DIR")`; exportarlo al compilar crates aislados:
  `CARGO_WORKSPACE_DIR=/home/dyallo/orca/projects/veloren/spikes/vendor/veloren`
- **Patch specs:** los crates aislados necesitan
  `[patch.crates-io] specs = { git = "https://github.com/amethyst/specs.git", rev = "4e2da1df29ee840baa9b936593c45592b7c9ae27" }`
  (si no, resuelve shred 0.15 → `core::ptr::invalid_mut` no existe → falla).
- **getrandom:** agregar `getrandom` **0.3 y 0.4** con feature `wasm_js` en el crate aislado (dos versiones en el grafo).
- **`uuid`:** feature `js` en wasm.
- **Comando de check/build típico (crate aislado):**
  ```
  RUSTFLAGS='--cfg getrandom_backend="wasm_js"' \
  CARGO_WORKSPACE_DIR=/home/dyallo/orca/projects/veloren/spikes/vendor/veloren \
  rustup run nightly-2026-06-13 cargo build --target wasm32-unknown-unknown --release
  # luego:
  wasm-bindgen --target web --no-typescript --out-dir pkg target/wasm32-unknown-unknown/release/<crate>.wasm
  ```
- **wasm-bindgen CLI:** 0.2.128 (el harness usa `wasm-bindgen = "=0.2.128"`).
- **Red:** crates.io / static.rust-lang.org son **intermitentes** (503 / lento) → reintentar. El workspace completo rompe por el índice de `wasmtime-wasi` (503) → usar **crates aislados por path**.

---

## ARTEFACTOS

- **Plan:** `.omo/plans/veloren-web-port.md` (rev.3, con hallazgos de Oracle).
- **Clone Veloren:** `spikes/vendor/veloren` (SHA `81283b7b…`, master 2026-10-07). **Con modificaciones wasm sin commitear** (`git diff`).
- **PoC-1 (wgpu WebGPU en wasm):** `spikes/poc1-wgpu-triangle/` (+ `examples/translate.rs` → naga GLSL→WGSL 16/16).
- **Harness wasm del cliente:** `/tmp/opencode/wasmclient` (`start(ws_url, auth_proxy, username, password)`; wasm ~11.9 MB).
- **Bridge v2 (axum: `/ws` + `/auth` proxy CORS):** `/tmp/opencode/bridge2` (binario en `target/debug/bridge2`).
- **Probe de compilación del cliente:** `/tmp/opencode/clienttest`.
- **Probe network/wstest/matrix:** `/tmp/opencode/{nettest,wstest,matrix}`.
- **Driver CDP:** `/tmp/opencode/cdp_eval.mjs` (`node cdp_eval.mjs <url> "<js>" <wait_ms>`).
- **Server de archivos con MIME wasm correcto:** `/tmp/opencode/serve.py <port> <dir>`.
- **Echo server WS:** `/tmp/opencode/echo_server.py`.

---

## CÓMO CORRER / TESTEAR

**1. Server de juego real (del usuario):** `192.168.88.153:14004` (Veloren weekly). Manda handshake `VELOREN` + versión `[0,6,0]` (coincide con el cliente).

**2. Levantar bridge + serve:**
```
setsid /tmp/opencode/bridge2/target/debug/bridge2 192.168.88.153:14004 127.0.0.1:9100 https://auth.veloren.net &
setsid python3 /tmp/opencode/serve.py 8300 /tmp/opencode/wasmclient &
```
- Bridge: `/ws` (relay al server), `/auth/*` (proxy con CORS a auth.veloren.net).

**3. Chromium con CDP** (el usuario lo levanta):
```
chromium --remote-debugging-port=9222 --user-data-dir=/tmp/opencode/chrome-webgpu \
  --enable-unsafe-webgpu --use-angle=swiftshader --enable-features=Vulkan \
  --no-first-run --no-default-browser-check
```

**4. Correr el cliente (login + arranque):**
```
node /tmp/opencode/cdp_eval.mjs "http://127.0.0.1:8300/?u=<user>&p=<pass>" "window.__status + ' :: ' + document.title" 35000
```
**Cuenta de prueba del server:** `piolaso_local` / `PiolasoLocal123` (la creó el usuario para testing).

**Resultado esperado hoy:** `window.__status='done'` + title `CLIENT_OK` (login + sync inicial + `State::client` OK). Antes de §1 paniqueaba en `State::pools`; tras §1 en `WeatherLerp::default`; tras §2 completa.

> **OJO (cache):** el `.wasm` se cachea en Chromium aunque `serve.py` mande `no-store`. Hay que cache-bustear el wasm: `init('./pkg/wasmclient_bg.wasm?v=N')` (bump en `index.html`).

---

## GOTCHAS / LECCIONES CLAVE

- **`pkill -f <patron>` se suicida** si el patrón está en la propia línea de comandos del shell. Usar `pkill -x` o `fuser -k <port>/tcp`.
- **`python3 -m http.server` sirve `.wasm` con MIME incorrecto** → usar `serve.py` (agrega `application/wasm` + no-store). Si no, el cliente falla al cargar.
- **El WS transport NO necesita GPU** → validable sin WebGPU.
- **`gloo-net`** para fetch en wasm; **`web-time`** para `Instant` (std paniquea); **`gloo-timers`** para timers.
- **El `WebSocket` de web-sys NO es `Send`** → patrón Send-safe: un `spawn_local` lo posee; drain/sink por canales. (Implementado en `network/src/channel.rs`.)
- **`connect()` del WS debe esperar el evento `open`** antes del primer send (bug real cazado en browser).
- **async block es `!Unpin`** → para `&mut task` en `select!`, `Box::pin(...)`.
- **`workspace = true` + `default-features = false` no se puede** → declarar la dep explícita (version + patch) en la entrada wasm.
- **`foldhash` y `specs` requieren nightly** (feature `hashtag`/`nightly`); por eso nightly-2026-06-13.
- **`arg("--cfg")` etc.** — no relevante.

## HALLAZGOS QUE CAMBIARON EL PLAN (para contexto)
- **El geometry shader de Veloren es código MUERTO** (`render/renderer/shaders.rs:94` comentado).
- **voxygen ya tiene compilador naga runtime** (`pipeline_modes.enable_naga` → `WgpuCompiler`) → posible evitar pipeline WGSL build-time.
- **wgpu 27 `BROWSER_WEBGPU` funciona en wasm** (PoC-1 verificado, `RENDER_OK`).
- **El bridge debe ser dumb-pipe** (no reusar veloren-network) + proxy `/auth`.

## MEMORIA ENGRAM (proyecto `veloren`)
Observaciones: 1034–1053. Últimas: 1052 (ECS single-thread done), 1053 (Instant→web-time).

## DEFINICIÓN DE "HECHO" DEL PENDIENTE §1 — ✅ CUMPLIDA (y §2 también)
`veloren-client` **compila a wasm** (0 errores) ✅ · **nativo compila** ✅ ·
el harness corre `Client::new` y **retorna `CLIENT_OK`** en el browser ✅
(`__status='done'`). Falta el loop de juego/render (Pendiente §3).
