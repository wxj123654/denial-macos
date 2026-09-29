# macOS application experience

## Purpose

The macOS shell currently provides window chrome, a menu bar, and a Dock
skeleton, but no application discovery or launch surface. This document defines
how Denial should add that experience without turning the project into a
replacement application suite.

The target is the current macOS model, not the retired Launchpad model. macOS
26 replaced Launchpad with an Apps browser integrated into Spotlight, and
macOS 27 retains that design. Denial should therefore provide an Apps/Spotlight
surface with search, suggestions, categories, and grid/list browsing rather
than a full-screen, manually arranged Launchpad.

Apple references:

- <https://support.apple.com/guide/mac-help/open-apps-in-spotlight-mh35840/mac>
- <https://support.apple.com/guide/mac-help/search-with-spotlight-mchlp1008/mac>
- <https://www.apple.com/os/macos/>

## Current state

- `MacosShellApp` supplies a macOS-styled scene to the shared `DenialShell`
  host.
- `MacosDesktopScene` paints wallpaper, managed windows, the menu bar, and the
  Dock.
- `MacosDock` only displays currently visible running windows and cannot launch
  an application.
- The Finder label in the menu bar is a fallback string, not a file manager.
- No `LocalFlutterApplication` is registered by the macOS entry point.
- `denial-settings` is the only Denial-owned standalone application, but the
  macOS scene does not expose a route to it.
- The stock shell already discovers freedesktop desktop entries, resolves
  icons, tracks recent applications, focuses existing windows, and launches
  applications. The macOS shell should reuse those services rather than create
  a second application database.

## Product boundaries

Denial's roadmap explicitly excludes building a browser, terminal, file
manager, or complete application suite merely for completeness. The macOS shell
must preserve that boundary:

- Apps, Spotlight, Dock, Finder roles, and Trash are shell integration.
- Settings remains the existing standalone Denial application.
- Browser, file manager, terminal, mail, calendar, media, and document roles
  resolve to installed Linux applications.
- Apple cloud services and proprietary applications are not compatibility
  targets.
- Small first-party utilities are optional and require a concrete system
  integration benefit, not visual catalogue parity.

## Experience model

### Apps and Spotlight

Apps is a shell surface backed by the existing XDG application catalogue.

- The Dock Apps item and the `applications` shell action toggle the surface.
- Search matches desktop-entry name, ID, categories, and keywords.
- Recent launches form a suggested section.
- The catalogue is sorted deterministically and may be filtered by broad
  freedesktop categories.
- Keyboard input supports Escape, arrows, Tab, and Enter.
- Launching dismisses the surface. An already-open application is focused
  instead of duplicated when its desktop identity can be matched.
- Grid is the initial view. A later phase may add list view and persist the
  choice.

Spotlight will eventually expand beyond applications to files, actions, and
clipboard history. Phase 1 deliberately names and structures the application
surface so those modes can be added without reviving Launchpad semantics.

### Dock

The Dock contains two kinds of item:

- persistent shell/application items, which can launch even when no window is
  open;
- running application groups, which focus or restore their windows.

The initial persistent items are Apps and System Settings. Files, the default
browser, user pinning, minimized windows, and Trash follow in later phases.

### Application roles

Finder, Safari, Terminal, and similar names are visual references, not bundled
applications. Denial should model semantic roles such as `fileManager`,
`webBrowser`, and `terminal`, then resolve each role through XDG defaults or an
explicit user choice. The UI may present a macOS-style role icon and label while
the launched implementation remains a normal Linux application.

## Delivery phases

### Phase 0 - Contract and baseline

Status: documented here.

- Record the current macOS application gaps and current-macOS reference model.
- Preserve the roadmap boundary against building an application suite.
- Establish `tools/denial-pc flutter-test test/macos` as the fast regression
  loop for this work.

Acceptance:

- The plan identifies ownership, scope, phases, and verification.
- Existing macOS tests pass before feature work.

### Phase 1 - Launchable desktop

Status: implemented.

Delivered surfaces and files:

- `dart_shell/lib/src/macos/macos_applications_surface.dart` —
  `MacosApplicationsSurface` plus the catalogue, filter, and suggestion
  helpers and the `macos-applications-*` keys.
- `dart_shell/lib/src/macos/macos_dock.dart` — persistent Apps and Settings
  Dock items with `macos-dock-applications` / `macos-dock-settings` keys.
- `dart_shell/lib/src/macos/macos_desktop_scene.dart` — scene-owned Apps
  visibility, `DenialShellAction` handling, and launch/Settings flows.
- `dart_shell/test/macos/macos_applications_surface_test.dart` and
  `dart_shell/test/macos/macos_dock_test.dart` — helper, widget, and Dock
  regressions.

- Add a macOS Apps surface backed by `homeGridControllerProvider`.
- Include deterministic search and recent suggestions.
- Launch desktop applications through `appLauncherProvider`.
- Focus a matching existing window instead of relaunching it.
- Toggle Apps from the persistent Dock item and
  `DenialShellAction.applications`.
- Add a persistent Settings Dock item.
- Focus an existing Settings window or launch `denial-settings`.
- Handle `DenialShellAction.openSettings`.
- Add focused model/widget regression tests.

Acceptance:

- Apps can be opened and dismissed without any running application.
- Installed desktop applications appear, filter, and launch.
- A repeated launch focuses a matching open window.
- Settings is reachable from both Dock and the shell action.
- No retired Launchpad paging, folders, or manual icon arrangement is added.
- Targeted macOS tests pass; touched Dart code compiles through Flutter tests.
- A dedicated analyzer gate remains pending until `tools/denial-pc` exposes one.

### Phase 2 - Dock application model

Status: implemented, except dragging an application from Apps onto the Dock.

Delivered: `macos_dock_model.dart` (grouping by canonical identity, minimized
tracking, persisted pins at `$XDG_STATE_HOME/denial/macos-dock-pins.json`),
`macos_dock.dart` (running indicators, active state, context menus, keyboard
semantics, `DragTarget<DesktopApp>` that calls `onPinApp`).

Open: the Apps surface is a full-screen layer above the Dock and its tiles are
not `Draggable<DesktopApp>`, so the drop target is unreachable. Pinning is
currently available from the Dock context menu only.

- Group multiple windows by canonical application identity.
- Keep persistent items separate from running groups.
- Show minimized applications and restore them from the Dock.
- Add running indicators, active state, context menus, and deterministic
  keyboard semantics.
- Persist user-pinned applications and ordering.
- Support dragging an app from Apps to the Dock.

Acceptance:

- One Dock item represents one application regardless of window count.
- Closing the final window removes only unpinned applications.
- Minimized windows remain discoverable and restorable.
- Pin state survives a new session.

### Phase 3 - Finder roles and desktop integration

Status: role contract and Settings overrides implemented; Dock integration
open.

Delivered: `macos_application_roles.dart` (override, then `mimeapps.list`, then
category, then unresolved), `macos_mime_associations.dart`, persisted
`applicationRoles` settings, and a Default applications Settings page.
`launchMacosApplicationRole` and `openMacosDefaultApplicationsSettings` are the
integration API.

Open: Files and Trash Dock items, opening Home/Applications/Downloads/Trash
through the file manager role, and desktop file/volume integration.

- Introduce semantic default-application roles for Files, browser, terminal,
  mail, calendar, and media.
- Resolve roles using freedesktop defaults and expose explicit overrides in
  Settings.
- Add Files and Trash Dock items.
- Open Home, Applications, Downloads, and Trash through the selected file
  manager.
- Add desktop file/folder and removable-volume integration only after the role
  contract is stable.

Acceptance:

- No role depends on a distribution-specific executable name.
- Missing role handlers fail visibly and offer a Settings route.
- Changing a role takes effect without restarting the session.

### Phase 4 - Broader Spotlight

Status: implemented; global keyboard/gesture entry point open.

Delivered: Applications, Files, Actions and Clipboard modes in
`macos_applications_surface.dart` and `macos_spotlight_sources.dart`, category
filters, persisted grid/list view, a bounded async file search, clipboard
gating on the lock state, and a menu-bar Spotlight button.

Open: a configurable global shortcut or gesture; the file search covers only a
capped set of user directories.

- Add Spotlight modes for applications, files, actions, and clipboard history.
- Reuse existing Denial clipboard and shortcut/action models.
- Add category filters and grid/list view persistence.
- Add menu-bar and configurable keyboard/gesture entry points.

Acceptance:

- Each mode has a bounded, cancellable data source.
- Search never blocks the Flutter UI isolate on filesystem traversal.
- Sensitive clipboard content follows existing lock/privacy policy.

### Phase 5 - Optional utilities

Status: deferred.

Evaluate small first-party utilities such as Calculator or a document preview
surface only when they provide integration unavailable from an installed Linux
application. Browser, terminal, file manager, mail, messages, media stores, and
Apple cloud applications remain out of scope.

## Local development installation

The macOS shell is tested through the separate **Denial (development)** display
manager session. It must not replace or modify the packaged Denial session,
`/usr/bin/deniald`, or `/usr/lib/denial/flutter`.

Build the current checkout and refresh its development-session entry with:

```sh
tools/denial-pc build
tools/denial-pc install-session
tools/denial-pc doctor
```

The development entry is rendered from `dev/denial.desktop.in` and appears in
SDDM as **Denial (development)**. It launches `tools/denial-pc session`, which
uses the checkout's release Flutter bundle and Settings bundle plus the
revision-matched compositor binaries below the Denial PC build cache. The
packaged **Denial** entry remains independently installed and available.

Installing or rebuilding does not activate the new compositor inside the
current graphical session. At an explicit test checkpoint, the user must log
out themselves, select **Denial (development)** in SDDM, and log back in.
Automation must never log out, stop, or restart the user's local graphical
session. Once already running that development session, `tools/denial-pc
refresh` may rebuild and safely request an in-process Flutter bundle refresh;
it must not be aimed at the packaged session.

## Verification and diagnosis

Every phase uses the following loop:

1. Add or select a deterministic test that reproduces the missing or incorrect
   behavior.
2. Run the narrow macOS test target through `tools/denial-pc flutter-test`.
3. Rank falsifiable causes for each failure before changing code.
4. Apply the smallest fix and add a regression assertion at the real seam.
5. Re-run the original loop, then run analyzer checks for touched Dart code.
6. Remove temporary diagnostics and record any missing test seam.

Visual validation remains user-owned. Automated work must not capture or judge
screenshots or trigger unrelated visible events.
