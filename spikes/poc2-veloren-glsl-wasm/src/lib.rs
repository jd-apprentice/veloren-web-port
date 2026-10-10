//! PoC-2: compile Veloren's real GLSL shaders through wgpu's in-wasm naga
//! frontend (`ShaderSource::Glsl`) and render a frame.
//!
//! PoC-1 proved wgpu/WebGPU renders in wasm. This proves the shader strategy
//! for the web port: voxygen's `WgpuCompiler` feeds GLSL straight to wgpu, so
//! the naga GLSL frontend must run *inside* the wasm module. Here we run the
//! same 16 shaders already validated host-side (naga GLSL->WGSL 16/16) through
//! `create_shader_module(ShaderSource::Glsl)` on the browser's WebGPU backend.
#![cfg(target_arch = "wasm32")]

use std::borrow::Cow;
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use wasm_bindgen_futures::{spawn_local, JsFuture};
use wgpu::naga::ShaderStage;

const TRIANGLE_WGSL: &str = r#"
struct VertexOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) color: vec3<f32>,
};

@vertex
fn vs(@builtin(vertex_index) i: u32) -> VertexOut {
    var p = array<vec2<f32>, 3>(
        vec2<f32>( 0.0,  0.6),
        vec2<f32>(-0.6, -0.6),
        vec2<f32>( 0.6, -0.6),
    );
    var c = array<vec3<f32>, 3>(
        vec3<f32>(1.0, 0.2, 0.2),
        vec3<f32>(0.2, 1.0, 0.2),
        vec3<f32>(0.2, 0.4, 1.0),
    );
    var out: VertexOut;
    out.pos = vec4<f32>(p[i], 0.0, 1.0);
    out.color = c[i];
    return out;
}

@fragment
fn fs(in: VertexOut) -> @location(0) vec4<f32> {
    return vec4<f32>(in.color, 1.0);
}
"#;

macro_rules! veloren_shader {
    ($name:literal, $stage:ident) => {
        (
            $name,
            ShaderStage::$stage,
            include_str!(concat!("../shaders/", $name, ".glsl")),
        )
    };
}

#[wasm_bindgen(start)]
pub fn start() {
    std::panic::set_hook(Box::new(console_error_panic_hook::hook));
    spawn_local(async move {
        if let Err(e) = run().await {
            web_sys::console::error_1(&e);
            panic!("{e:?}");
        }
    });
}

async fn next_frame() {
    let promise = js_sys::Promise::new(&mut |resolve, _reject| {
        web_sys::window()
            .unwrap()
            .request_animation_frame(&resolve)
            .unwrap();
    });
    JsFuture::from(promise).await.unwrap();
}

async fn run() -> Result<(), JsValue> {
    let window = web_sys::window().ok_or("no window")?;
    let document = window.document().ok_or("no document")?;
    let canvas = document
        .get_element_by_id("canvas")
        .ok_or("no #canvas")?
        .dyn_into::<web_sys::HtmlCanvasElement>()?;
    let width = canvas.width();
    let height = canvas.height();

    let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
        backends: wgpu::Backends::BROWSER_WEBGPU,
        ..Default::default()
    });
    let surface = instance
        .create_surface(wgpu::SurfaceTarget::Canvas(canvas))
        .map_err(|e| format!("create_surface: {e:?}"))?;
    let adapter = instance
        .request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(&surface),
            force_fallback_adapter: false,
        })
        .await
        .map_err(|e| format!("request_adapter: {e:?}"))?;
    let (device, queue) = adapter
        .request_device(&wgpu::DeviceDescriptor {
            label: Some("poc2 device"),
            required_features: wgpu::Features::empty(),
            required_limits: adapter.limits(),
            ..Default::default()
        })
        .await
        .map_err(|e| format!("request_device: {e:?}"))?;
    document.set_title("DEVICE_OK");

    let caps = surface.get_capabilities(&adapter);
    let format = caps
        .formats
        .iter()
        .copied()
        .find(|f| f.is_srgb())
        .unwrap_or(caps.formats[0]);
    surface.configure(
        &device,
        &wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width,
            height,
            present_mode: wgpu::PresentMode::Fifo,
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        },
    );

    // --- The actual de-risking: compile Veloren's real GLSL via wgpu's naga. ---
    let shaders = [
        veloren_shader!("blit-vert", Vertex),
        veloren_shader!("blit-frag", Fragment),
        veloren_shader!("postprocess-vert", Vertex),
        veloren_shader!("postprocess-frag", Fragment),
        veloren_shader!("terrain-vert", Vertex),
        veloren_shader!("terrain-frag", Fragment),
        veloren_shader!("figure-vert", Vertex),
        veloren_shader!("figure-frag", Fragment),
        veloren_shader!("sprite-vert", Vertex),
        veloren_shader!("sprite-frag", Fragment),
        veloren_shader!("ui-vert", Vertex),
        veloren_shader!("ui-frag", Fragment),
        veloren_shader!("skybox-vert", Vertex),
        veloren_shader!("skybox-frag", Fragment),
        veloren_shader!("particle-vert", Vertex),
        veloren_shader!("particle-frag", Fragment),
    ];
    let total = shaders.len();
    let mut ok = 0usize;
    let mut fails: Vec<String> = Vec::new();
    for (name, stage, src) in shaders {
        device.push_error_scope(wgpu::ErrorFilter::Validation);
        let _module = unsafe {
            device.create_shader_module_trusted(
                wgpu::ShaderModuleDescriptor {
                    label: Some(name),
                    source: wgpu::ShaderSource::Glsl {
                        shader: Cow::Borrowed(src),
                        stage,
                        defines: &[],
                    },
                },
                wgpu::ShaderRuntimeChecks::unchecked(),
            )
        };
        if let Some(err) = device.pop_error_scope().await {
            let msg = format!("{name}: {err:?}");
            web_sys::console::error_1(&msg.clone().into());
            fails.push(msg);
        } else {
            ok += 1;
        }
    }
    let glsl_status = format!("GLSL {ok}/{total}");
    web_sys::console::log_1(&glsl_status.clone().into());
    document.set_title(&format!("GLSL_OK:{ok}/{total}"));

    // --- Render a triangle (WGSL) so we also observe a presented frame. ---
    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("triangle shader"),
        source: wgpu::ShaderSource::Wgsl(TRIANGLE_WGSL.into()),
    });
    let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("triangle pipeline"),
        layout: None,
        vertex: wgpu::VertexState {
            module: &shader,
            entry_point: Some("vs"),
            buffers: &[],
            compilation_options: Default::default(),
        },
        fragment: Some(wgpu::FragmentState {
            module: &shader,
            entry_point: Some("fs"),
            targets: &[Some(wgpu::ColorTargetState {
                format,
                blend: Some(wgpu::BlendState::REPLACE),
                write_mask: wgpu::ColorWrites::ALL,
            })],
            compilation_options: Default::default(),
        }),
        primitive: wgpu::PrimitiveState::default(),
        depth_stencil: None,
        multisample: wgpu::MultisampleState::default(),
        multiview: None,
        cache: None,
    });

    let mut first_frame = true;
    loop {
        if !first_frame {
            next_frame().await;
        }
        let frame = match surface.get_current_texture() {
            Ok(f) => f,
            Err(wgpu::SurfaceError::Outdated) => {
                surface.configure(
                    &device,
                    &wgpu::SurfaceConfiguration {
                        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                        format,
                        width,
                        height,
                        present_mode: wgpu::PresentMode::Fifo,
                        alpha_mode: caps.alpha_modes[0],
                        view_formats: vec![],
                        desired_maximum_frame_latency: 2,
                    },
                );
                continue;
            },
            Err(e) => {
                web_sys::console::error_1(&format!("get_current_texture: {e:?}").into());
                break;
            },
        };
        let view = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("frame encoder"),
        });
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("main pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: 0.05,
                            g: 0.06,
                            b: 0.10,
                            a: 1.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
            pass.set_pipeline(&pipeline);
            pass.draw(0..3, 0..1);
        }
        queue.submit(Some(encoder.finish()));
        frame.present();
        if first_frame {
            document.set_title(&format!("GLSL_OK:{ok}/{total} RENDER_OK"));
            first_frame = false;
        }
    }

    Ok(())
}
