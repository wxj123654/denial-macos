# macOS 26 (Tahoe) design reference

Single style reference for every Denial macOS-shell surface, whichever model
or person writes it. Only macOS 26 "Liquid Glass" is used as a source; nothing
is assumed about later releases.

Sources: Apple newsroom (June 2025), WWDC25 "Meet Liquid Glass" (session 219),
and Apple's "Adopting Liquid Glass" and HIG Materials pages. Numeric values
below (radii, control heights, tints) are engineering approximations, not
Apple-published constants.

## Principles

1. Glass is the control/navigation layer floating above content. Never use
   glass for content, and never stack glass on glass.
2. Shapes are rounded and concentric: inner radius = outer radius - inset
   (`MacosRadii.concentric`). Controls are capsules.
3. Resting state stays quiet; controls gain energy on hover/press (scale,
   brighter fill), then settle.
4. Elements morph or materialize rather than fade.
5. The menu bar is transparent. Sidebars and toolbars float over the window.
6. Honor reduced transparency and reduced motion.

## Code map

- `dart_shell/lib/src/macos/design/macos_design_tokens.dart`: spacing, radii,
  control heights, motion, type scale, system colors, light/dark palettes.
- `.../macos_glass.dart`: `MacosGlass` (regular and clear variants, optional
  tint, specular rim, contact shadow).
- `.../macos_controls.dart`: button, switch, slider, segmented, search field.
- `.../macos_design_gallery.dart`: review surface.

## Rules for new UI (for humans and models)

- Use tokens and these components; do not hard-code colors, radii, spacing or
  font sizes.
- Need something missing? Add a token or component here first, then use it.
- Every new component must appear in the gallery in light and dark.

## Viewing the gallery

`tools/denial-pc` always builds `dart_shell/lib/main.dart`, so swap the entry
point temporarily. The `Denial (development)` login entry runs the bundle
built from this checkout.

First time only (install needs root, so run it yourself in a terminal):

```sh
tools/denial-pc bootstrap
tools/denial-pc build
tools/denial-pc install-session   # adds "Denial (development)" to SDDM
```

Log out and pick `Denial (development)` at SDDM. Once you are inside it,
iterate from the repository root:

```sh
# 1. Save the real entry point and substitute the gallery.
cp dart_shell/lib/main.dart /tmp/main.dart.orig
cp dart_shell/example/macos_design_gallery.dart dart_shell/lib/main.dart

# 2. Rebuild the Flutter bundle and hot-swap it into the running deniald
#    (no session restart). Needs a bootstrapped toolchain:
#    `tools/denial-pc bootstrap` once.
tools/denial-pc refresh

# 3. Look at it, then restore the real shell and refresh again.
cp /tmp/main.dart.orig dart_shell/lib/main.dart
tools/denial-pc refresh
```

Run every `tools/denial-pc` command outside the sandbox. If `refresh` reports
that the running `deniald` predates in-process refresh, restart the Denial
session once and repeat. Never commit the swapped `main.dart`. The gallery is
a full shell scene, so while it is showing you cannot launch apps; restoring
the entry point returns you to the normal desktop.

## Known gaps versus real Liquid Glass

`MacosGlass` uses backdrop blur, tint and a rim highlight. It has no lensing
(refraction) or dispersion. The engine glass in `ShellGlassConfiguration`
(thickness, refraction, dispersion, rim) supports those, and the existing macOS
Dock and menu bar currently use flat alpha containers rather than either
implementation. Migrating them onto one shared material is the next step.
