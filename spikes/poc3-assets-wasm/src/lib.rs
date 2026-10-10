//! PoC-3: validate the wasm asset pipeline (`WebSource` + HTTP preload + Cache
//! Storage + progress) against real Veloren asset files served over HTTP.
#![cfg(target_arch = "wasm32")]

use std::borrow::Cow;
use veloren_common_assets::{AssetExt, BoxedError, FileAsset, load_manifest, preload};
use wasm_bindgen::prelude::*;
use wasm_bindgen_futures::spawn_local;

const MANIFEST_SUBPATH: &str = "spikes/poc3-assets-wasm/manifest.txt";
const ASSETS_SUBPATH: &str = "spikes/vendor/veloren/assets";

struct Raw(Vec<u8>);

impl FileAsset for Raw {
    const EXTENSION: &'static str = "glsl";

    fn from_bytes(bytes: Cow<[u8]>) -> Result<Self, BoxedError> { Ok(Raw(bytes.into_owned())) }
}

fn element(id: &str) -> Option<web_sys::Element> {
    web_sys::window()?.document()?.get_element_by_id(id)
}

fn title(t: &str) {
    if let Some(d) = web_sys::window().and_then(|w| w.document()) {
        d.set_title(t);
    }
}

fn set_progress(done: usize, total: usize) {
    let pct = if total > 0 { done * 100 / total } else { 0 };
    if let Some(bar) = element("bar") {
        let _ = bar.set_attribute("style", &format!("width:{pct}%"));
    }
    if let Some(txt) = element("txt") {
        txt.set_text_content(Some(&format!("{done}/{total}")));
    }
}

#[wasm_bindgen(start)]
pub fn start() {
    std::panic::set_hook(Box::new(console_error_panic_hook::hook));
    spawn_local(async move {
        let origin = web_sys::window()
            .and_then(|w| w.location().origin().ok())
            .unwrap_or_default();
        let manifest_url = format!("{origin}/{MANIFEST_SUBPATH}");
        let assets_base = format!("{origin}/{ASSETS_SUBPATH}");

        title("manifest");
        let manifest = match load_manifest(&manifest_url).await {
            Ok(m) => m,
            Err(e) => {
                title(&format!("MANIFEST_ERR:{e}"));
                return;
            },
        };
        let paths: Vec<&str> = manifest.iter().map(String::as_str).collect();

        title("preloading");
        match preload(&assets_base, &paths, set_progress).await {
            Ok(n) => web_sys::console::log_1(&format!("preloaded {n} files").into()),
            Err(e) => {
                title(&format!("PRELOAD_ERR:{e}"));
                return;
            },
        }

        let a = Raw::load_expect("voxygen.shaders.blit-vert");
        let b = Raw::load_expect("voxygen.shaders.blit-frag");
        let c = Raw::load_expect("voxygen.shaders.ui-frag");
        let d = Raw::load_expect("voxygen.shaders.include.srgb");
        title(&format!(
            "ASSETS_OK:{}:{}:{}:{}",
            a.read().0.len(),
            b.read().0.len(),
            c.read().0.len(),
            d.read().0.len()
        ));
    });
}
