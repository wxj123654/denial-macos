// Synthetic, surfaceless borrowed-FBO probe. Never connects to the desktop.
// Numeric assertions by default; optional gallery capture stays surfaceless.
use denial_flutter_engine::*;
use std::ffi::{CStr, c_char, c_void};
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

#[link(name = "EGL")]
unsafe extern "C" {
    fn eglGetPlatformDisplay(
        platform: u32,
        native: *mut c_void,
        attrs: *const isize,
    ) -> *mut c_void;
    fn eglInitialize(d: *mut c_void, major: *mut i32, minor: *mut i32) -> u32;
    fn eglBindAPI(api: u32) -> u32;
    fn eglChooseConfig(
        d: *mut c_void,
        attrs: *const i32,
        configs: *mut *mut c_void,
        size: i32,
        count: *mut i32,
    ) -> u32;
    fn eglCreateContext(
        d: *mut c_void,
        config: *mut c_void,
        share: *mut c_void,
        attrs: *const i32,
    ) -> *mut c_void;
    fn eglMakeCurrent(
        d: *mut c_void,
        draw: *mut c_void,
        read: *mut c_void,
        ctx: *mut c_void,
    ) -> u32;
    fn eglGetProcAddress(name: *const c_char) -> *mut c_void;
    fn eglGetError() -> i32;
}
#[link(name = "GLESv2")]
unsafe extern "C" {
    fn glGenTextures(n: i32, ids: *mut u32);
    fn glBindTexture(target: u32, id: u32);
    fn glTexParameteri(target: u32, pname: u32, value: i32);
    fn glTexImage2D(
        target: u32,
        level: i32,
        internal: i32,
        w: i32,
        h: i32,
        border: i32,
        format: u32,
        kind: u32,
        pixels: *const c_void,
    );
    fn glGenFramebuffers(n: i32, ids: *mut u32);
    fn glBindFramebuffer(target: u32, id: u32);
    fn glFramebufferTexture2D(
        target: u32,
        attachment: u32,
        texture_target: u32,
        texture: u32,
        level: i32,
    );
    fn glGenRenderbuffers(n: i32, ids: *mut u32);
    fn glBindRenderbuffer(target: u32, id: u32);
    fn glRenderbufferStorage(target: u32, format: u32, width: i32, height: i32);
    fn glFramebufferRenderbuffer(
        target: u32,
        attachment: u32,
        renderbuffer_target: u32,
        renderbuffer: u32,
    );
    fn glCheckFramebufferStatus(target: u32) -> u32;
    fn glReadPixels(x: i32, y: i32, w: i32, h: i32, format: u32, kind: u32, pixels: *mut c_void);
    fn glFinish();
    fn glGetError() -> u32;
}
const W: usize = 2100;
const H: usize = 1488;
const DPR: f64 = 1.75;
const VIEW: i64 = -1;
// Probe timeline origin shared with present callbacks for scripted-input logs.
static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
// Probe-timeline milliseconds of the latest present, for scripted-input pacing.
static LAST_PRESENT_MS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
// PPM rows deliberately follow glReadPixels order: the calibrated negative
// view reflection maps GL bottom-up rows to logical top-down rows.
fn write_ppm(path: &Path, width: usize, height: usize, rgba: &[u8]) -> std::io::Result<()> {
    let mut out = BufWriter::new(std::fs::File::create(path)?);
    write!(out, "P6\n{width} {height}\n255\n")?;
    let mut row = Vec::with_capacity(width * 3);
    for pixels in rgba.chunks_exact(width * 4) {
        row.clear();
        for pixel in pixels.as_chunks::<4>().0 {
            row.extend_from_slice(&pixel[..3]);
        }
        out.write_all(&row)?;
    }
    out.flush()
}
fn checksum(data: &[u8]) -> u64 {
    data.iter().fold(0xcbf29ce484222325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3)
    })
}
fn env_value<T: std::str::FromStr>(
    name: &str,
    default: T,
) -> Result<T, Box<dyn std::error::Error>> {
    match std::env::var(name) {
        Ok(value) => value
            .parse()
            .map_err(|_| format!("invalid {name}: {value}").into()),
        Err(std::env::VarError::NotPresent) => Ok(default),
        Err(error) => Err(error.into()),
    }
}
#[derive(Default)]
struct CaptureStats {
    saved: usize,
    changed_frames: usize,
    changed_pixels: u128,
    absolute_delta: u128,
    max_channel_delta: u8,
    last_checksum: u64,
    sequence_checksum: u64,
    gl_errors: usize,
    io_error: Option<String>,
}
struct Capture {
    dir: PathBuf,
    limit: usize,
    stats: Mutex<CaptureStats>,
}
struct Handler {
    display: usize,
    raster: usize,
    resource: usize,
    fbo: u32,
    events: mpsc::Sender<EngineEvent>,
    pixels: Mutex<(usize, Vec<u8>)>,
    width: usize,
    height: usize,
    capture: Option<Capture>,
    shots: Mutex<ShotState>,
}
#[derive(Default)]
struct ShotState {
    pending: Vec<u64>,
    // First present index allowed to satisfy `pending`: skips any frame that was
    // already in flight when the shot time arrived.
    min_present: usize,
    previous: Vec<u8>,
}
struct PointerStep {
    at_ms: u64,
    phase: sys::FlutterPointerPhase,
    kind: &'static str,
    x: f64,
    y: f64,
}
fn parse_pointer_script(script: &str) -> Result<Vec<PointerStep>, Box<dyn std::error::Error>> {
    let mut steps = Vec::new();
    for step in script.split(';').map(str::trim).filter(|s| !s.is_empty()) {
        let parts: Vec<&str> = step.split(':').map(str::trim).collect();
        let [at_ms, kind, x, y] = parts[..] else {
            return Err(format!("invalid PROBE_POINTER_SCRIPT step: {step}").into());
        };
        let (phase, kind) = match kind {
            "add" => (sys::FlutterPointerPhase_kAdd, "add"),
            "hover" => (sys::FlutterPointerPhase_kHover, "hover"),
            "down" => (sys::FlutterPointerPhase_kDown, "down"),
            "move" => (sys::FlutterPointerPhase_kMove, "move"),
            "up" => (sys::FlutterPointerPhase_kUp, "up"),
            "remove" => (sys::FlutterPointerPhase_kRemove, "remove"),
            _ => return Err(format!("invalid pointer kind in step: {step}").into()),
        };
        let parse = |v: &str| -> Result<f64, Box<dyn std::error::Error>> {
            v.parse::<f64>()
                .ok()
                .filter(|v| v.is_finite())
                .ok_or_else(|| format!("invalid coordinate in step: {step}").into())
        };
        steps.push(PointerStep {
            at_ms: at_ms
                .parse()
                .map_err(|_| format!("invalid at_ms in step: {step}"))?,
            phase,
            kind,
            x: parse(x)?,
            y: parse(y)?,
        });
    }
    // Stable: equal timestamps keep script order.
    steps.sort_by_key(|s| s.at_ms);
    Ok(steps)
}
impl Handler {
    fn current(&self, ctx: usize) -> bool {
        unsafe {
            let ok = eglMakeCurrent(
                self.display as _,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                ctx as _,
            ) != 0;
            if !ok {
                eprintln!(
                    "make current failed ctx={ctx} thread={:?} EGL=0x{:x}",
                    thread::current().id(),
                    eglGetError()
                );
            }
            ok
        }
    }
    fn sample(&self) -> bool {
        let mut data = vec![0u8; self.width * self.height * 4];
        unsafe {
            glBindFramebuffer(0x8D40, self.fbo);
            glFinish();
            glReadPixels(
                0,
                0,
                self.width as _,
                self.height as _,
                0x1908,
                0x1401,
                data.as_mut_ptr().cast(),
            );
            glFinish();
        }
        let error = unsafe { glGetError() };
        if error != 0 {
            if let Some(capture) = &self.capture {
                capture.stats.lock().unwrap().gl_errors += 1;
                eprintln!("capture readback GL error=0x{error:x}");
            }
            return false;
        }
        let mut latest = self.pixels.lock().unwrap();
        latest.0 += 1;
        LAST_PRESENT_MS.store(
            START.get().map_or(0, |s| s.elapsed().as_millis() as u64),
            std::sync::atomic::Ordering::Relaxed,
        );
        let mut ok = true;
        if let Some(capture) = &self.capture {
            let mut shots = self.shots.lock().unwrap();
            if !shots.pending.is_empty() && latest.0 >= shots.min_present {
                let hash = checksum(&data);
                let changed = if shots.previous.len() == data.len() {
                    shots
                        .previous
                        .as_chunks::<4>()
                        .0
                        .iter()
                        .zip(data.as_chunks::<4>().0)
                        .filter(|(a, b)| a != b)
                        .count()
                } else {
                    data.len() / 4
                };
                for ms in std::mem::take(&mut shots.pending) {
                    let path = capture.dir.join(format!("shot-{ms}.ppm"));
                    match write_ppm(&path, self.width, self.height, &data) {
                        Ok(()) => eprintln!(
                            "shot at_ms={ms} present={} t_ms={} checksum={hash:016x} changed_pixels_vs_prev_shot={changed} path={}",
                            latest.0,
                            START.get().map_or(0, |s| s.elapsed().as_millis()),
                            path.display()
                        ),
                        Err(error) => {
                            capture.stats.lock().unwrap().io_error =
                                Some(format!("{}: {error}", path.display()));
                            ok = false;
                        }
                    }
                }
                shots.previous = data.clone();
            }
        }
        if let Some(capture) = &self.capture {
            let mut stats = capture.stats.lock().unwrap();
            let hash = checksum(&data);
            stats.last_checksum = hash;
            stats.sequence_checksum = stats.sequence_checksum.rotate_left(1) ^ hash;
            let mut changed = 0;
            for (previous, current) in latest
                .1
                .as_chunks::<4>()
                .0
                .iter()
                .zip(data.as_chunks::<4>().0)
            {
                if previous != current {
                    changed += 1;
                }
                for (a, b) in previous.iter().zip(current) {
                    let delta = a.abs_diff(*b);
                    stats.absolute_delta += u128::from(delta);
                    stats.max_channel_delta = stats.max_channel_delta.max(delta);
                }
            }
            if changed != 0 && latest.0 > capture.limit {
                eprintln!(
                    "capture changed present={} t_ms={} checksum={hash:016x} changed_pixels={changed}",
                    latest.0,
                    START.get().map_or(0, |s| s.elapsed().as_millis())
                );
            }
            stats.changed_frames += usize::from(changed != 0);
            stats.changed_pixels += changed as u128;
            if latest.0 <= capture.limit && stats.io_error.is_none() {
                let path = capture.dir.join(format!("frame-{:04}.ppm", latest.0));
                match write_ppm(&path, self.width, self.height, &data) {
                    Ok(()) => {
                        stats.saved += 1;
                        eprintln!(
                            "capture frame={} t_ms={} checksum={hash:016x} changed_pixels={changed}",
                            latest.0,
                            START.get().map_or(0, |s| s.elapsed().as_millis())
                        );
                    }
                    Err(error) => {
                        stats.io_error = Some(format!("{}: {error}", path.display()));
                        ok = false;
                    }
                }
            }
        }
        latest.1 = data;
        ok
    }
}
impl OpenGlHandler for Handler {
    fn make_current(&self) -> bool {
        self.current(self.raster)
    }
    fn clear_current(&self) -> bool {
        unsafe {
            eglMakeCurrent(
                self.display as _,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            ) != 0
        }
    }
    fn make_resource_current(&self) -> bool {
        self.current(self.resource)
    }
    fn framebuffer(&self, _: u32, _: u32) -> u32 {
        self.fbo
    }
    fn present(&self, _: PresentFrame<'_>) -> bool {
        self.sample()
    }
    fn create_backing_store(&self, r: BackingStoreRequest) -> Option<CompositorBackingStore> {
        if r.width != self.width || r.height != self.height {
            eprintln!(
                "unexpected backing store {} {} view={}",
                r.width, r.height, r.view_id
            );
            return None;
        }
        Some(CompositorBackingStore {
            framebuffer: self.fbo,
            format: 0x8058,
            user_data: 1,
        })
    }
    fn present_view(&self, p: PresentView<'_>) -> bool {
        assert_eq!(p.backing_store.framebuffer, self.fbo);
        self.sample()
    }
    fn populate_existing_damage(&self, _: isize, _: &mut Vec<sys::FlutterRect>) {}
    fn resolve_proc(&self, name: &CStr) -> *mut c_void {
        unsafe { eglGetProcAddress(name.as_ptr()) }
    }
    fn event(&self, e: EngineEvent) {
        self.events.send(e).unwrap();
    }
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    for name in ["DISPLAY", "WAYLAND_DISPLAY"] {
        assert!(
            std::env::var_os(name).is_none(),
            "{name} must be unset for the surfaceless probe"
        );
    }
    assert_eq!(
        std::env::var("LIBGL_ALWAYS_SOFTWARE").as_deref(),
        Ok("1"),
        "probe must select software rendering explicitly"
    );
    let base = PathBuf::from(std::env::args_os().nth(1).expect("probe AOT assembly path"));
    let engine = PathBuf::from(
        std::env::args_os()
            .nth(2)
            .expect("matching release engine output path"),
    );
    let capture = match std::env::var_os("PROBE_CAPTURE_DIR") {
        Some(dir) => {
            if dir.is_empty() {
                return Err("PROBE_CAPTURE_DIR must not be empty".into());
            }
            let dir = PathBuf::from(dir);
            std::fs::create_dir_all(&dir)?;
            Some(Capture {
                dir,
                limit: env_value("PROBE_CAPTURE_FRAMES", 12usize)?,
                stats: Mutex::new(CaptureStats::default()),
            })
        }
        None => None,
    };
    // Capture-only geometry: numeric mode ignores these overrides so its
    // calibrated five-point oracle retains exactly the original dimensions.
    let (width, height, dpr) = if capture.is_some() {
        (
            env_value("PROBE_WIDTH", W)?,
            env_value("PROBE_HEIGHT", H)?,
            env_value("PROBE_DPR", DPR)?,
        )
    } else {
        (W, H, DPR)
    };
    if width == 0
        || height == 0
        || width > i32::MAX as usize
        || height > i32::MAX as usize
        || width
            .checked_mul(height)
            .and_then(|n| n.checked_mul(4))
            .filter(|n| *n <= isize::MAX as usize)
            .is_none()
        || !dpr.is_finite()
        || dpr <= 0.
        || dpr * 120. > u32::MAX as f64
    {
        return Err("invalid probe dimensions or DPR".into());
    }
    let seconds = env_value("PROBE_SECONDS", 5.0f64)?;
    let duration = Duration::try_from_secs_f64(seconds)
        .map_err(|_| "PROBE_SECONDS must be finite, positive and representable")?;
    if duration.is_zero() {
        return Err("PROBE_SECONDS must be positive".into());
    }
    let pointer_steps = match std::env::var("PROBE_POINTER_SCRIPT") {
        Ok(script) => parse_pointer_script(&script)?,
        Err(std::env::VarError::NotPresent) => Vec::new(),
        Err(error) => return Err(error.into()),
    };
    let mut shot_times: Vec<u64> = match std::env::var("PROBE_SHOT_AT_MS") {
        Ok(list) => list
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|s| {
                s.parse()
                    .map_err(|_| format!("invalid PROBE_SHOT_AT_MS entry: {s}"))
            })
            .collect::<Result<_, _>>()?,
        Err(std::env::VarError::NotPresent) => Vec::new(),
        Err(error) => return Err(error.into()),
    };
    shot_times.sort_unstable();
    if !shot_times.is_empty() && capture.is_none() {
        return Err("PROBE_SHOT_AT_MS requires PROBE_CAPTURE_DIR".into());
    }
    let (tx, rx) = mpsc::channel();
    let handler = unsafe {
        let d = eglGetPlatformDisplay(0x31DD, std::ptr::null_mut(), std::ptr::null());
        assert!(!d.is_null());
        assert_ne!(
            eglInitialize(d, std::ptr::null_mut(), std::ptr::null_mut()),
            0
        );
        assert_ne!(eglBindAPI(0x30A0), 0);
        let attrs = [
            0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3033, 1, 0x3040, 0x0040, 0x3038,
        ];
        let mut config = std::ptr::null_mut();
        let mut count = 0;
        assert_ne!(
            eglChooseConfig(d, attrs.as_ptr(), &mut config, 1, &mut count),
            0
        );
        assert!(count > 0);
        let context = [0x3098, 3, 0x3038];
        let raster = eglCreateContext(d, config, std::ptr::null_mut(), context.as_ptr());
        assert!(!raster.is_null(), "egl {}", eglGetError());
        let resource = eglCreateContext(d, config, raster, context.as_ptr());
        assert!(!resource.is_null());
        assert_ne!(
            eglMakeCurrent(d, std::ptr::null_mut(), std::ptr::null_mut(), raster),
            0
        );
        let mut texture = 0;
        glGenTextures(1, &mut texture);
        glBindTexture(0x0DE1, texture);
        glTexParameteri(0x0DE1, 0x2801, 0x2601);
        glTexParameteri(0x0DE1, 0x2800, 0x2601);
        glTexParameteri(0x0DE1, 0x2802, 0x812F);
        glTexParameteri(0x0DE1, 0x2803, 0x812F);
        glTexImage2D(
            0x0DE1,
            0,
            0x8058,
            width as _,
            height as _,
            0,
            0x1908,
            0x1401,
            std::ptr::null(),
        );
        let mut fbo = 0;
        glGenFramebuffers(1, &mut fbo);
        glBindFramebuffer(0x8D40, fbo);
        glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, texture, 0);
        // Packed depth/stencil lets Impeller clip (e.g. ClipRRect) with the stencil
        // buffer instead of degrading to square clips on a color-only borrowed FBO.
        let mut depth_stencil = 0;
        glGenRenderbuffers(1, &mut depth_stencil);
        glBindRenderbuffer(0x8D41, depth_stencil); // GL_RENDERBUFFER
        glRenderbufferStorage(0x8D41, 0x88F0, width as _, height as _); // GL_DEPTH24_STENCIL8
        glFramebufferRenderbuffer(0x8D40, 0x821A, 0x8D41, depth_stencil); // GL_DEPTH_STENCIL_ATTACHMENT
        assert_eq!(glCheckFramebufferStatus(0x8D40), 0x8CD5);
        assert_eq!(glGetError(), 0);
        eglMakeCurrent(
            d,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        );
        Arc::new(Handler {
            display: d as _,
            raster: raster as _,
            resource: resource as _,
            fbo,
            events: tx,
            pixels: Mutex::new((0, Vec::new())),
            width,
            height,
            capture,
            shots: Mutex::new(ShotState::default()),
        })
    };
    let project = EngineProject {
        engine_library: engine.join("libflutter_engine.so"),
        assets: base.join("flutter_assets"),
        icu_data: engine.join("icudtl.dat"),
        runtime: DartRuntimeMode::Aot,
        aot_library: Some(base.join("lib/libapp.so")),
        renderer_backend: RendererBackend::ImpellerGles,
        resource_cache_max_bytes_threshold: 256 * 1024 * 1024,
    };
    let host = EngineHost::start(&project, handler.clone())?;
    host.engine()
        .send_window_metrics(&sys::FlutterWindowMetricsEvent {
            struct_size: std::mem::size_of::<sys::FlutterWindowMetricsEvent>(),
            width,
            height,
            pixel_ratio: dpr,
            display_id: 0,
            view_id: 0,
            ..Default::default()
        })?;
    host.engine().set_render_outputs(&[RenderOutput {
        render_view_id: VIEW,
        configuration_generation: 1,
        source_physical_x: 0.,
        source_physical_y: 0.,
        source_physical_width: width as _,
        source_physical_height: height as _,
        target_width: width,
        target_height: height,
        scale_120: (dpr * 120.).round() as _,
        source_to_target_transform: RenderOutputTransform {
            scale_x: 1.,
            skew_x: 0.,
            translate_x: 0.,
            skew_y: 0.,
            scale_y: 1.,
            translate_y: 0.,
        },
    }])?;
    let start = Instant::now();
    let _ = START.set(start);
    let mut tasks: Vec<ScheduledTask> = Vec::new();
    let mut last_render = Instant::now();
    let mut next_pointer = 0;
    let mut next_shot = 0;
    let mut last_pointer_micros = 0usize;
    // Scripted interaction: softpipe raster (~270ms for a reused scene, ~13s for a
    // rebuilt glass scene) is far slower than the 1ms vsync loop, so unthrottled
    // render requests queue and input effects surface long after the script ends.
    // Keep at most one frame in flight, and run the script clock (PROBE_SECONDS,
    // at_ms, shot times) on virtual time that pauses until the first present, for a
    // 3s grace after each pointer event (Dart rebuild latency), and while no present
    // has landed for 0.8s (a heavy raster is underway). Each step then observes the
    // previous step's settled frame.
    let paced = !pointer_steps.is_empty();
    let mut pending_baton: Option<isize> = None;
    let mut submitted = 0usize;
    let mut last_submit = Instant::now();
    let mut script_clock = Duration::ZERO;
    let mut last_tick = Instant::now();
    let mut grace_until = Instant::now();
    let wall_cap = Duration::from_secs(1800);
    loop {
        let tick = last_tick.elapsed();
        last_tick = Instant::now();
        let presented = handler.pixels.lock().unwrap().0;
        if paced {
            let since_present = start.elapsed().as_millis().saturating_sub(u128::from(
                LAST_PRESENT_MS.load(std::sync::atomic::Ordering::Relaxed),
            ));
            if presented > 0 && since_present < 800 && Instant::now() >= grace_until {
                script_clock += tick;
            }
        }
        let script_now = if paced { script_clock } else { start.elapsed() };
        if script_now >= duration || start.elapsed() > wall_cap {
            break;
        }
        while let Ok(event) = rx.try_recv() {
            match event {
                EngineEvent::PlatformTask(t) => tasks.push(t),
                EngineEvent::Vsync(b) if paced => pending_baton = Some(b),
                EngineEvent::Vsync(b) => {
                    let now = host.engine().current_time_nanos();
                    host.engine()
                        .render_outputs(&[VIEW], &[], true, now, now + 16_666_667)?;
                    host.engine().on_vsync(b, now, now + 16_666_667)?;
                }
                EngineEvent::PlatformMessage(mut msg) => {
                    let reply: &[u8] = match msg.channel.as_str() {
                        "flutter/keyboard" => &[0, 13, 0],
                        "flutter/platform" => b"[null]",
                        _ => b"",
                    };
                    host.respond(&mut msg, reply)?;
                }
            }
        }
        let elapsed_ms = script_now.as_millis() as u64;
        while next_pointer < pointer_steps.len() && pointer_steps[next_pointer].at_ms <= elapsed_ms
        {
            let step = &pointer_steps[next_pointer];
            // Engine clock in microseconds, strictly increasing like deniald's input path.
            let engine_micros = (host.engine().current_time_nanos() / 1_000) as usize;
            last_pointer_micros = engine_micros.max(last_pointer_micros + 1);
            let pressed = matches!(
                step.phase,
                sys::FlutterPointerPhase_kDown | sys::FlutterPointerPhase_kMove
            );
            let event = sys::FlutterPointerEvent {
                struct_size: std::mem::size_of::<sys::FlutterPointerEvent>(),
                phase: step.phase,
                timestamp: last_pointer_micros,
                // Script coordinates are logical top-down; Flutter wants physical pixels.
                x: step.x * dpr,
                y: step.y * dpr,
                device: 1,
                signal_kind: sys::FlutterPointerSignalKind_kFlutterPointerSignalKindNone,
                device_kind: sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindMouse,
                buttons: if pressed {
                    i64::from(sys::FlutterPointerMouseButtons_kFlutterPointerButtonMousePrimary)
                } else {
                    0
                },
                // The implicit view that send_window_metrics created; VIEW=-1 is only
                // the compositor render-output id and is not a Flutter view id.
                view_id: 0,
                ..Default::default()
            };
            let result = host.engine().send_pointer_events(&[event]);
            eprintln!(
                "pointer at_ms={} actual_ms={elapsed_ms} wall_ms={} kind={} logical=({},{}) physical=({},{}) result={:?}",
                step.at_ms,
                start.elapsed().as_millis(),
                step.kind,
                step.x,
                step.y,
                event.x,
                event.y,
                result
            );
            result?;
            grace_until = Instant::now() + Duration::from_secs(3);
            next_pointer += 1;
        }
        while next_shot < shot_times.len() && shot_times[next_shot] <= elapsed_ms {
            let mut shots = handler.shots.lock().unwrap();
            if shots.pending.is_empty() {
                shots.min_present = presented.max(submitted) + 1;
            }
            shots.pending.push(shot_times[next_shot]);
            drop(shots);
            next_shot += 1;
        }
        let now = host.engine().current_time_nanos();
        // One frame in flight; a watchdog covers a dropped present.
        let idle =
            !paced || presented >= submitted || last_submit.elapsed() > Duration::from_secs(60);
        if paced
            && idle
            && let Some(b) = pending_baton.take()
        {
            host.engine()
                .render_outputs(&[VIEW], &[], true, now, now + 16_666_667)?;
            host.engine().on_vsync(b, now, now + 16_666_667)?;
            submitted = presented + 1;
            last_submit = Instant::now();
            last_render = Instant::now();
        }
        let mut i = 0;
        while i < tasks.len() {
            if tasks[i].target_time_nanos <= now {
                host.run_scheduled_task(tasks.remove(i))?;
            } else {
                i += 1;
            }
        }
        if last_render.elapsed() > Duration::from_millis(100) && idle {
            host.engine()
                .render_outputs(&[VIEW], &[], false, now, now + 16_666_667)?;
            last_render = Instant::now();
            if paced {
                submitted = presented + 1;
                last_submit = Instant::now();
            }
        }
        thread::sleep(Duration::from_millis(1));
    }
    host.shutdown()?;
    let latest = handler.pixels.lock().unwrap();
    eprintln!(
        "{} frames={}",
        if handler.capture.is_some() {
            "capture"
        } else {
            "numeric"
        },
        latest.0
    );
    assert!(latest.0 > 2);
    if let Some(capture) = &handler.capture {
        let stats = capture.stats.lock().unwrap();
        assert_eq!(stats.gl_errors, 0, "capture GL readback failures");
        if let Some(error) = &stats.io_error {
            return Err(error.clone().into());
        }
        write_ppm(&capture.dir.join("final.ppm"), width, height, &latest.1)?;
        let report = format!(
            "capture {width}x{height} dpr={dpr} frames={} saved={}+final\n\
             checksum_rgba_fnv1a={:016x} sequence_checksum={:016x}\n\
             transitions={} changed_frames={} changed_pixels={} absolute_channel_delta={} max_channel_delta={} gl_errors={}\n",
            latest.0,
            stats.saved,
            stats.last_checksum,
            stats.sequence_checksum,
            latest.0 - 1,
            stats.changed_frames,
            stats.changed_pixels,
            stats.absolute_delta,
            stats.max_channel_delta,
            stats.gl_errors,
        );
        eprint!("{report}");
        std::fs::write(capture.dir.join("report.txt"), report)?;
        // Gallery content is not the synthetic marker scene; only capture mode
        // bypasses its five-point oracle. Frames and GL health remain checked.
        return Ok(());
    }
    let data = &latest.1;
    if std::env::var("PROBE_SMALL_GLASS").as_deref() == Ok("true") {
        let mut errors = 0;
        // Logical top-down positions use the same calibrated negative-view
        // reflection as the original oracle. Capture returned above: report only.
        let sample = |x: f64, y: f64| {
            let col = (x * DPR) as usize;
            let row = (y * DPR) as usize;
            let at = (row * W + col) * 4;
            &data[at..at + 3]
        };
        let background = sample(450., 400.);
        println!("small-background x=450 y=400: {background:?} expected=[240, 240, 240]");
        if background.iter().any(|v| v.abs_diff(240) > 5) {
            errors += 1;
        }
        for (label, left, top, w, h) in [
            ("capsule-36x24", 480., 420., 36., 24.),
            ("slider-26x18", 560., 420., 26., 18.),
            ("tool-36x36", 640., 420., 36., 36.),
            // Fixed probe optics retain depth60 even after business forSize.
            // 36x24 coverage, inset 30x18 SDF.
            ("blend-depth60-30x18", 763., 423., 30., 18.),
        ] {
            // Four logical pixels inside the coverage bounds, on the cardinal
            // axes: inside the inset SDF, away from rim/antialiasing and corners.
            for (point, x, y) in [
                ("center", left + w / 2., top + h / 2.),
                ("left", left + 4., top + h / 2.),
                ("right", left + w - 4., top + h / 2.),
                ("top", left + w / 2., top + 4.),
                ("bottom", left + w / 2., top + h - 4.),
            ] {
                let got = sample(x, y);
                // Rec.709 luminance in readback byte space. A broad floor locks
                // down dark/black sampling, not an exact shader appearance.
                let luminance = (2126 * u32::from(got[0])
                    + 7152 * u32::from(got[1])
                    + 722 * u32::from(got[2])) as f64
                    / 10000.;
                println!(
                    "small-{label}-{point} x={x} y={y}: {got:?} luminance={luminance:.2} minimum=150"
                );
                if luminance < 150. {
                    errors += 1;
                }
            }
        }
        return if errors > 0 {
            Err(format!("{errors} small-glass numerical sample assertions failed").into())
        } else {
            Ok(())
        };
    }
    let mut errors = 0;
    for (label, x, y, expected) in [
        ("background", 100., 700., [24, 72, 120]),
        ("marker", 630., 235., [255, 221, 0]),
        ("button-left", 550., 448., [24, 72, 120]),
        ("button-middle", 630., 468., [24, 72, 120]),
        ("button-right", 700., 490., [24, 72, 120]),
    ] {
        // Calibrated against non-glass marker: negative view reflection makes
        // logical top-down rows coincide with GL framebuffer bottom-up rows.
        let col = (x * DPR) as usize;
        let row = (y * DPR) as usize;
        let at = (row * W + col) * 4;
        let expected = if label == "marker" {
            expected
        } else {
            let r = (((row as f64 + 0.5) / H as f64) * 255.).round() as i32;
            [r, 0, 255 - r]
        };
        let got = &data[at..at + 3];
        println!("{label} x={x} y={y}: {got:?} expected={expected:?}");
        if got
            .iter()
            .zip(expected)
            .any(|(a, b)| (*a as i32 - b).abs() > 5)
        {
            errors += 1;
        }
    }
    // The engine's render thread may still own its EGL context after shutdown
    // returns. This short-lived process lets the OS reclaim probe-owned GL/EGL
    // objects; explicit teardown would only obscure the numeric result.
    if errors > 0 {
        Err(format!("{errors} numerical sample assertions failed").into())
    } else {
        Ok(())
    }
}
