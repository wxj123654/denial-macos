# Persistent GLES output geometry antialiasing experiment

## Finding

The locked Flutter fork at `d0817320163b3fb5a284e63cc21f2d6b9138442b`
wraps Denial's negative render views as single-sample compositor-owned FBOs.
`Canvas::SetupRenderPass` skips its MSAA intermediate when that root color
texture is shader-readable. Ordinary round-rect geometry consequently uses
single-sample pipelines, even when the scene contains a backdrop filter.
Text atlas coverage and shader-provided glass coverage do not establish that
ordinary geometry is antialiased.

A surfaceless EGL capability query on this workstation reported RX 7900 XT,
OpenGL ES 3.2, and `GL_MAX_SAMPLES=8`. Neither multisampled-render-to-texture
extension was advertised. GLES 3 explicit resolve is supported by the fork.
The probe queried capabilities only; it did not draw or read pixels.

## Experiment

Flutter commit: `cae32eb6` on local branch `codex/gles-root-msaa`.
Skia remains at locked commit `0ee042f542b3e79f5ac49115387718c6bb3d7d34`.

The compositor's attachment descriptors continue to describe the real
single-sample storage. Its negative render views request an intermediate
4x MSAA scene pass. Partial repaints first draw the entire previous borrowed
color texture into that intermediate with source replacement, before any
scene damage clipping. This retains unchanged pixels and backdrop input.
The final resolved scene is drawn back into the borrowed output FBO through
the existing root-blit path. Framebuffer-fetch transitions cannot switch the
remaining scene back to single-sample rendering.

This first experiment adds full-output MSAA color/depth resources and resolve
and copy work. It does not establish an acceptable memory or frame-time cost.
Visual correctness and interactive performance remain user validation gates.

## Headless validation

A dedicated `denial_root_msaa_unittests` target uses mocked GL entry points.
It creates no window, real graphics context, screenshot, or pixel readback.

- Before the Canvas fix: 3 failed, 1 passed.
- After the fix: 4 passed.
- Assertions cover actual round-rect pipeline sample count, initialization of
  partial repaints without a damage scissor, MSAA with backdrop input, and the
  unchanged unmarked single-sample path.

The prior shell layout changes remain in the Denial checkout. Their reported
28 Impeller Flutter tests were not rerun because this experiment changes only
the engine and retains the existing AOT bundle.

## Source roots and isolated build

The documented `/mnt/exty` canonical source roots are absent on this machine.
Editable copies were created outside the cache at:

- Flutter: `/home/wxj/document/denial-engine-sources/flutter`
- Skia: `/home/wxj/document/denial-engine-sources/skia`

The nested Skia directory is a symlink to the separate Skia root. Both source
root overrides must be supplied together. The original managed, lock-pinned
source projection was not edited. The new roots use the required local Git
identity, `Doctor Logix <doctor.logix@gmail.com>`.

```sh
DENIAL_FLUTTER_SOURCE_ROOT=/home/wxj/document/denial-engine-sources/flutter \
DENIAL_SKIA_SOURCE_ROOT=/home/wxj/document/denial-engine-sources/skia \
DENIAL_PC_ENGINE_TEST_NINJA_OUT=/home/wxj/.cache/denial/flutter-engine/build/out/denial_host_release \
tools/denial-pc engine-test-build

tools/denial-pc engine-test-check
tools/denial-pc engine-test-arm
```

The release Ninja graph was regenerated against the editable Flutter source.
The existing source lock and tracked engine checksums are unchanged. The
experimental engine must be activated only through the isolated one-shot
engine-test bundle. Never replace a mapped library or the normal bundle's
engine. The user owns the local logout/login and visual checks; the agent
must wait for confirmation of the new login before inspecting runtime health.


## Staged result

- Full Flutter revision: `cae32eb60bb4571f32fb6139f2fb92c648d3f80d`.
- Experimental engine SHA-256:
  `fede49133ab55aee3a150dbdd621075a2d7969692ed6f61be9a43a944ff29744`.
- Immutable test bundle:
  `/home/wxj/.cache/denial/engine-test/cae32eb60bb4571f32fb6139f2fb92c648d3f80d-fede49133ab55aee/bundle`.
- `tools/denial-pc engine-test-check`: bundle ABI/AOT test passed (1 test).
- `tools/denial-pc engine-test-arm`: next development login armed; subsequent
  logins return to the known-good engine automatically.
- Normal bundle engine SHA-256 still equals the tracked expected checksum:
  `c7920dfc17fe0ce0f5406883f17183cd4e75596a192592ea45ebc204c2214515`.
- Existing `deniald` PID 1663 remained running. No session restart occurred.

The initial release compilation had a Clang frontend heap crash in unchanged
`reactor_gles.cc`; an incremental retry with eight build jobs completed.
No workaround or unrelated source modification was made for that crash.

After the user confirms a new development login, verify that a new `deniald`
PID maps the immutable test bundle, its engine hash matches the value above,
and the session logs show normal startup and presentation without GL/FBO
validation errors. The user should evaluate ordinary Continue-pill, switch,
and inset geometry edges, banner/dock corners, window-bottom alignment, and
interaction latency. Do not advance the source lock until the experiment is
accepted.
