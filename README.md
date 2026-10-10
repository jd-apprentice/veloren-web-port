# Veloren Web Port

Port del cliente de Veloren (`veloren-voxygen`) a **WebAssembly** (browser, WebGPU).

## Estado

- ✅ **Red + login desde wasm** (cliente `veloren-client` → WS → bridge → server real)
- ✅ **`veloren-voxygen` compila a wasm32** (0 errores)
- ✅ **El cliente arranca, corre el loop de juego, y el menú/login RENDERIZA en el browser**
- ⏳ En curso: la carga del mundo (`Preparing client`) puede congelar el main thread (wasm single-thread)

## Layout

- `.omo/HANDOFF.md` — estado completo + pendientes (leer primero).
- `.omo/plans/veloren-web-port.md` — plan del port (rev.3).
- `patches/veloren-wasm-port.patch` — **todos los cambios al clone de Veloren** (aplicar sobre `veloren/veloren`).
- `spikes/poc1-wgpu-triangle/` — wgpu WebGPU triangle (wasm).
- `spikes/poc2-veloren-glsl-wasm/` — compila los shaders GLSL reales de Veloren con naga (in-wasm) + render.
- `spikes/poc3-assets-wasm/` — assets por HTTP + Cache Storage.
- `spikes/voxharness/` — harness del cliente real (cdylib).
- `spikes/vendor/iced/` — iced vendeado con fixes de wasm.

## Cómo correr

Ver `.omo/HANDOFF.md` §"CÓMO CORRER". Resumen:
1. `rustup toolchain install nightly-2026-06-13 --target wasm32-unknown-unknown`
2. Build del harness: `RUSTFLAGS='--cfg getrandom_backend="wasm_js"' CARGO_WORKSPACE_DIR=<vendor/veloren> cargo build --target wasm32-unknown-unknown --release`
3. `wasm-bindgen --target web --no-typescript --out-dir pkg <crate>.wasm`
4. Servir con MIME wasm correcto + bridge WS↔TCP + proxy `/auth`.

## Chromium (CRÍTICO)

```
chromium --remote-debugging-port=9222 --user-data-dir=<dir> \
  --enable-unsafe-webgpu --ignore-gpu-blocklist \
  --no-first-run --no-default-browser-check
```

> **NO usar `--use-angle=swiftshader`** → fuerza software rendering y el canvas queda negro.
> Necesitás una GPU real (soporta WebGPU).
