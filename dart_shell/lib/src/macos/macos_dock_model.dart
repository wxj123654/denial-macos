import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../desktop/desktop_workspace.dart';
import '../launcher/launcher_providers.dart';
import '../launcher/runtime_paths.dart';
import '../launcher/services/app_launcher.dart';

/// Normalizes an application identity the same way [AppLauncher] does when
/// matching open windows for focus-instead-of-relaunch.
String macosDockNormalizeAppId(String value) => value.trim().toLowerCase();

/// One application-area Dock entry: a pinned launcher, a running application
/// group, or both. Multiple windows with the same canonical application
/// identity collapse into a single entry, so one Dock item represents one
/// application regardless of window count.
@immutable
class MacosDockEntry {
  const MacosDockEntry({
    required this.id,
    this.app,
    this.windows = const <DenialWindow>[],
    this.minimizedObjectIds = const <int>{},
    this.pinned = false,
    this.active = false,
    String? pinId,
  }) : _pinId = pinId;

  /// Canonical application identity. This is the owning [DesktopApp.id] when
  /// the entry resolved to an installed desktop entry, the persisted pin id
  /// for pins that no longer resolve to the catalogue, or the normalized
  /// window appId for running applications without a desktop entry.
  final String id;

  /// The catalogue application backing this entry, when resolved.
  final DesktopApp? app;

  /// Live windows grouped under this identity, ordered back-to-front so the
  /// last window is the group's topmost.
  final List<DenialWindow> windows;

  /// Object ids of [windows] whose workspace placement is minimized.
  final Set<int> minimizedObjectIds;

  /// Whether the user pinned this application to the Dock. Pinned entries
  /// survive after their last window closes; unpinned running entries do not.
  final bool pinned;

  /// Whether this entry owns the frontmost window.
  final bool active;

  /// Whether the application currently has at least one window.
  bool get running => windows.isNotEmpty;

  /// Whether every window of a running entry is minimized.
  bool get allWindowsMinimized =>
      running && minimizedObjectIds.length >= windows.length;

  /// The identity recorded by pin/unpin operations. Catalogue-resolved
  /// entries pin by [DesktopApp.id] so they can relaunch after reboot;
  /// unresolved entries pin by their window-derived canonical id. When the
  /// entry was created from a stored pin, this is exactly the stored id so
  /// unpin removes the persisted record.
  String get pinId => _pinId ?? app?.id ?? id;

  final String? _pinId;

  /// Human-readable label: the application name, else the first window's
  /// title, else the raw identity.
  String get label {
    final app = this.app;
    if (app != null) {
      return app.name;
    }
    for (final window in windows) {
      final title = window.displayTitle;
      if (title.isNotEmpty) {
        return title;
      }
    }
    return id;
  }
}

/// Resolves the ordered application area of the macOS Dock.
///
/// Pinned identities come first in [pinnedIds] order, each merged with its
/// running windows when the identities match. Unpinned running groups follow
/// in first-window-appearance order. A running window joins the group whose
/// canonical identity it resolves to: the owning [DesktopApp] is found through
/// the same `expectedWindowAppIds` matching the launcher uses for
/// focus-instead-of-relaunch, so a pin and a running group never duplicate.
List<MacosDockEntry> macosDockEntries({
  required Iterable<DenialWindow> windows,
  required Map<int, DesktopWindowPlacement> placements,
  required List<DesktopApp> installedApps,
  required List<String> Function(DesktopApp app) expectedWindowAppIds,
  required List<String> pinnedIds,
  int? foregroundObjectId,
}) {
  final appsById = <String, DesktopApp>{};
  final appsByIdentity = <String, DesktopApp>{};
  for (final app in installedApps) {
    appsById.putIfAbsent(app.id, () => app);
    for (final identity in expectedWindowAppIds(app)) {
      appsByIdentity.putIfAbsent(macosDockNormalizeAppId(identity), () => app);
    }
  }

  final groups = <String, _MacosDockGroup>{};
  final order = <String>[];
  _MacosDockGroup groupFor(
    String key, {
    String? id,
    DesktopApp? app,
    bool pinned = false,
  }) {
    final existing = groups[key];
    if (existing != null) {
      existing.app ??= app;
      existing.pinned = existing.pinned || pinned;
      return existing;
    }
    final created = _MacosDockGroup(id: id ?? key, app: app, pinned: pinned);
    groups[key] = created;
    order.add(key);
    return created;
  }

  // Pinned entries occupy the front of the application area in their
  // persisted order, even while they own no window.
  for (final pinId in pinnedIds) {
    final key = macosDockNormalizeAppId(pinId);
    if (key.isEmpty || groups.containsKey(key)) {
      continue;
    }
    final trimmedPin = pinId.trim();
    final app = appsById[trimmedPin];
    final group = groupFor(
      key,
      id: app?.id ?? trimmedPin,
      app: app,
      pinned: true,
    );
    group.pinId = trimmedPin;
  }

  // Running windows merge into an existing pinned entry or append a new
  // unpinned group at the point their first window appeared.
  for (final window in windows) {
    if (!window.isUserApp) {
      continue;
    }
    final identity = macosDockNormalizeAppId(window.appId);
    final app = appsByIdentity[identity];
    final canonical =
        app?.id ?? (identity.isEmpty ? 'window:${window.objectId}' : identity);
    // A pin recorded from the window's own identity keeps its group even
    // after the catalogue later resolves that identity to a desktop entry.
    final key = groups.containsKey(identity)
        ? identity
        : macosDockNormalizeAppId(canonical);
    groupFor(key, id: canonical, app: app).windows.add(window);
  }

  final foreground = foregroundObjectId;
  return List<MacosDockEntry>.unmodifiable(<MacosDockEntry>[
    for (final key in order)
      _buildDockEntry(groups[key]!, placements, foreground),
  ]);
}

class _MacosDockGroup {
  _MacosDockGroup({required this.id, this.app, this.pinned = false});

  String id;
  DesktopApp? app;
  bool pinned;
  String? pinId;
  final List<DenialWindow> windows = <DenialWindow>[];
}

MacosDockEntry _buildDockEntry(
  _MacosDockGroup group,
  Map<int, DesktopWindowPlacement> placements,
  int? foregroundObjectId,
) {
  // Deterministic back-to-front ordering: workspace z, then objectId for
  // windows without a placement, so the last window is the group's topmost.
  final windows = group.windows.toList(growable: false)
    ..sort((left, right) {
      final leftZ = placements[left.objectId]?.z ?? 0;
      final rightZ = placements[right.objectId]?.z ?? 0;
      return leftZ != rightZ
          ? leftZ.compareTo(rightZ)
          : left.objectId.compareTo(right.objectId);
    });
  final minimizedObjectIds = <int>{
    for (final window in windows)
      if (placements[window.objectId]?.minimized ?? false) window.objectId,
  };
  return MacosDockEntry(
    id: group.id,
    app: group.app,
    windows: List<DenialWindow>.unmodifiable(windows),
    minimizedObjectIds: Set<int>.unmodifiable(minimizedObjectIds),
    pinned: group.pinned,
    pinId: group.pinId ?? group.app?.id ?? group.id,
    active:
        foregroundObjectId != null &&
        windows.any((window) => window.objectId == foregroundObjectId),
  );
}

/// Persistence seam for the ordered pinned-application list.
abstract interface class MacosDockPinsStore {
  /// Reads the persisted pin order, oldest pin first.
  Future<List<String>> readPins();

  /// Atomically persists the complete pin order.
  Future<void> writePins(List<String> pins);
}

const int _maximumPinnedAppIdLength = 4096;
const int _maximumPinnedApps = 64;

/// Normalizes persisted pin ids: trimmed, non-empty, deduplicated, bounded.
List<String> _normalizePins(Object? value) {
  if (value is! List) {
    return const <String>[];
  }
  final seen = <String>{};
  final pins = <String>[];
  for (final candidate in value) {
    if (candidate is! String) {
      continue;
    }
    final id = candidate.trim();
    if (id.isEmpty || id.length > _maximumPinnedAppIdLength || !seen.add(id)) {
      continue;
    }
    pins.add(id);
    if (pins.length == _maximumPinnedApps) {
      break;
    }
  }
  return List<String>.unmodifiable(pins);
}

/// File-backed [MacosDockPinsStore] at `$XDG_STATE_HOME/denial/macos-dock-pins.json`.
///
/// Mirrors [ApplicationRecentsRepository]: JSON with a version field, atomic
/// write through a temporary file, and best-effort failure handling so Dock
/// interaction is never blocked by persistence.
class MacosDockPinsRepository implements MacosDockPinsStore {
  const MacosDockPinsRepository({required this.paths});

  final RuntimePaths paths;

  Future<File> _file() async {
    final dir = Directory(p.join(paths.stateHome, 'denial'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'macos-dock-pins.json'));
  }

  @override
  Future<List<String>> readPins() async {
    try {
      final file = await _file();
      if (!await file.exists()) {
        return const <String>[];
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        return const <String>[];
      }
      return _normalizePins(decoded['pins']);
    } on Object {
      return const <String>[];
    }
  }

  @override
  Future<void> writePins(List<String> pins) async {
    try {
      final file = await _file();
      final temporary = File('${file.path}.tmp');
      final payload = jsonEncode(<String, Object>{
        'version': 1,
        'pins': _normalizePins(pins),
      });
      await temporary.writeAsString('$payload\n', flush: true);
      await temporary.rename(file.path);
    } on Object {
      // Pinning is a convenience; the in-memory order stays authoritative.
    }
  }
}

final macosDockPinsStoreProvider = Provider<MacosDockPinsStore>((ref) {
  return MacosDockPinsRepository(paths: ref.watch(runtimePathsProvider));
});

/// Ordered, persisted user-pinned application ids for the macOS Dock.
///
/// The public mutators [pin], [unpin], and [reorder] are the integration
/// point for other surfaces: dragging a [DesktopApp] onto the Dock calls
/// `pin(app.id)` with the desktop-file id.
final macosDockPinsProvider =
    NotifierProvider<MacosDockPinsController, List<String>>(
      MacosDockPinsController.new,
    );

class MacosDockPinsController extends Notifier<List<String>> {
  Future<void> _writeQueue = Future<void>.value();
  int _mutationRevision = 0;
  bool _disposed = false;

  @override
  List<String> build() {
    _disposed = false;
    final store = ref.watch(macosDockPinsStoreProvider);
    final loadRevision = _mutationRevision;
    ref.onDispose(() => _disposed = true);
    unawaited(_load(store, loadRevision));
    return const <String>[];
  }

  bool isPinned(String pinId) => state.contains(pinId);

  /// Appends [pinId] to the Dock pins unless it is already present.
  void pin(String pinId) {
    final normalized = pinId.trim();
    if (normalized.isEmpty ||
        normalized.length > _maximumPinnedAppIdLength ||
        state.contains(normalized) ||
        state.length >= _maximumPinnedApps) {
      return;
    }
    _replace(List<String>.unmodifiable(<String>[...state, normalized]));
  }

  /// Removes [pinId] from the Dock pins; running windows keep their entry.
  void unpin(String pinId) {
    final normalized = pinId.trim();
    if (!state.contains(normalized)) {
      return;
    }
    _replace(
      List<String>.unmodifiable(state.where((pin) => pin != normalized)),
    );
  }

  /// Moves the pin at [oldIndex] to [newIndex], matching the reorder
  /// semantics of `ReorderableListView`.
  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= state.length ||
        newIndex < 0 ||
        newIndex > state.length) {
      return;
    }
    var target = newIndex;
    if (oldIndex < target) {
      target -= 1;
    }
    final next = List<String>.of(state);
    final moved = next.removeAt(oldIndex);
    next.insert(target, moved);
    _replace(List<String>.unmodifiable(next));
  }

  void _replace(List<String> next) {
    if (listEquals(next, state)) {
      return;
    }
    _mutationRevision += 1;
    state = next;
    _queueSave(ref.read(macosDockPinsStoreProvider), next);
  }

  Future<void> _load(MacosDockPinsStore store, int loadRevision) async {
    final saved = await store.readPins();
    if (_disposed) {
      return;
    }
    if (_mutationRevision == loadRevision) {
      if (!listEquals(saved, state)) {
        state = saved;
      }
      return;
    }
    // Local pins changed while the initial read was in flight; the local
    // order is authoritative and is written back over the stale snapshot.
    _queueSave(store, state);
  }

  void _queueSave(MacosDockPinsStore store, List<String> pins) {
    _writeQueue = _writeQueue.then((_) => store.writePins(pins));
  }
}
