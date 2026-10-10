//! Offline spike: translate Veloren's real GLSL shaders to WGSL via naga.
//!
//! Mirrors voxygen's include handling (#include <name.glsl> resolves to
//! include/name.glsl, falling back to name.glsl) and runs naga's GLSL frontend
//! + validator + WGSL backend. Reports per-shader pass/fail.

use std::path::{Path, PathBuf};

use naga::back::wgsl;
use naga::front::glsl;
use naga::valid::{Capabilities, ValidationFlags, Validator};
use naga::ShaderStage;

fn shaders_dir() -> PathBuf {
    let candidates = [
        "../vendor/veloren/assets/voxygen/shaders",
        "spikes/vendor/veloren/assets/voxygen/shaders",
    ];
    for c in candidates {
        let p = PathBuf::from(c);
        if p.is_dir() {
            return p;
        }
    }
    panic!("shaders dir not found");
}

fn resolve_include(name: &str, dir: &Path) -> Option<PathBuf> {
    if name == "anti-aliasing.glsl" {
        return Some(dir.join("antialias/fxaa.glsl"));
    }
    let inc = dir.join("include").join(name);
    if inc.is_file() {
        return Some(inc);
    }
    let root = dir.join(name);
    if root.is_file() {
        return Some(root);
    }
    None
}

fn expand_includes(path: &Path, dir: &Path, depth: usize, out: &mut String) {
    if depth > 16 {
        return;
    }
    let text = std::fs::read_to_string(path).unwrap_or_default();
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("#include") {
            let rest = rest.trim();
            let name = rest
                .trim_start_matches('<')
                .trim_end_matches('>')
                .trim()
                .to_string();
            if let Some(inc) = resolve_include(&name, dir) {
                expand_includes(&inc, dir, depth + 1, out);
                out.push('\n');
                continue;
            } else {
                out.push_str("// UNRESOLVED INCLUDE: ");
                out.push_str(&name);
                out.push('\n');
                continue;
            }
        }
        out.push_str(line);
        out.push('\n');
    }
}

fn stage_of(name: &str) -> Option<ShaderStage> {
    if name.ends_with("-vert") || name.ends_with("-vert.glsl") {
        Some(ShaderStage::Vertex)
    } else if name.ends_with("-frag") || name.contains("-frag.") {
        Some(ShaderStage::Fragment)
    } else {
        None
    }
}

fn translate(name: &str, dir: &Path) -> Result<String, String> {
    let file = dir.join(format!("{name}.glsl"));
    let stage = stage_of(name).ok_or_else(|| "unknown stage".to_string())?;
    let mut src = String::new();
    expand_includes(&file, dir, 0, &mut src);
    // Threshold must stay <= f32::MAX (3.4e38); larger values overflow WGSL f32 literals.
    let define = "#define isinf(x) (abs(x) > 3.4e38)\n";
    let src = match src.find("#version") {
        Some(vpos) => {
            let line_end = src[vpos..]
                .find('\n')
                .map(|i| vpos + i + 1)
                .unwrap_or(src.len());
            format!("{}{}{}", &src[..line_end], define, &src[line_end..])
        }
        None => format!("{define}{src}"),
    };

    let mut frontend = glsl::Frontend::default();
    let options = glsl::Options {
        stage,
        defines: Default::default(),
    };
    let module = frontend
        .parse(&options, &src)
        .map_err(|e| format!("parse: {e:?}"))?;

    let mut validator = Validator::new(ValidationFlags::all(), Capabilities::all());
    let info = validator
        .validate(&module)
        .map_err(|e| format!("validate: {e:?}"))?;

    wgsl::write_string(&module, &info, wgsl::WriterFlags::empty())
        .map_err(|e| format!("wgsl: {e:?}"))
}

fn main() {
    let dir = shaders_dir();
    println!("shaders dir: {}", dir.display());
    let names = [
        "blit-vert",
        "blit-frag",
        "postprocess-vert",
        "postprocess-frag",
        "terrain-vert",
        "terrain-frag",
        "figure-vert",
        "figure-frag",
        "sprite-vert",
        "sprite-frag",
        "ui-vert",
        "ui-frag",
        "skybox-vert",
        "skybox-frag",
        "particle-vert",
        "particle-frag",
    ];
    let (mut ok, mut fail) = (0usize, 0usize);
    for n in names {
        match translate(n, &dir) {
            Ok(wgsl) => {
                ok += 1;
                println!("OK   {n:24} ({} bytes WGSL)", wgsl.len());
            }
            Err(e) => {
                fail += 1;
                let e = e.lines().next().unwrap_or("").to_string();
                println!("FAIL {n:24} {e}");
            }
        }
    }
    println!("\n=== {ok} ok / {fail} fail ===");
}
