import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../launcher/launcher_providers.dart';
import '../launcher/models/desktop_app.dart';
import '../launcher/runtime_paths.dart';
import '../models/clipboard_history.dart';
import '../models/shortcut_configuration.dart';

/// Spotlight modes offered by the macOS applications/Spotlight surface.
///
/// Applications keeps the Phase 1 catalogue semantics; files, actions, and
/// clipboard history are bounded, cancellable data sources added in Phase 4.
enum MacosSpotlightMode { applications, files, actions, clipboard }

/// Result presentation for the Spotlight surface.
enum MacosSpotlightViewMode {
  grid,
  list;

  static MacosSpotlightViewMode? tryParse(String? value) => switch (value) {
    'grid' => MacosSpotlightViewMode.grid,
    'list' => MacosSpotlightViewMode.list,
    _ => null,
  };
}

/// Shell-level commands offered by Spotlight's Actions mode.
///
/// Each action carries the equivalent [DenialShortcutAction] when one exists
/// so labels and icons stay aligned with the shortcut editor catalogue.
/// [logOut] has no shortcut-action counterpart and supplies its own label.
enum MacosSpotlightAction {
  openSettings(DenialShortcutAction.openSettings),
  openClipboard(DenialShortcutAction.openClipboard),
  captureRegion(DenialShortcutAction.captureRegion),
  windowSwitcher(DenialShortcutAction.windowSwitcher),
  lockScreen(DenialShortcutAction.lockScreen),
  logOut(null);

  const MacosSpotlightAction(this.shortcutAction);

  /// The shared shortcut model this action mirrors, when one exists.
  final DenialShortcutAction? shortcutAction;
}

/// Actions shown in Actions mode, in deterministic display order.
const List<MacosSpotlightAction> macosSpotlightActions =
    MacosSpotlightAction.values;

/// One selectable Spotlight result.
sealed class MacosSpotlightResult {
  const MacosSpotlightResult();

  /// Stable identity used for selection and widget keys within one mode.
  String get resultId;
}

/// An installed desktop application; [suggested] marks the recents row copy
/// so its identity never collides with the catalogue entry for the same app.
class MacosSpotlightApplicationResult extends MacosSpotlightResult {
  const MacosSpotlightApplicationResult(this.app, {this.suggested = false});

  final DesktopApp app;
  final bool suggested;

  @override
  String get resultId => '${suggested ? 'suggested' : 'catalog'}:${app.id}';
}

/// A file or directory found by the bounded filesystem search.
class MacosSpotlightFileResult extends MacosSpotlightResult {
  const MacosSpotlightFileResult(this.path, {required this.isDirectory});

  final String path;
  final bool isDirectory;

  @override
  String get resultId => 'file:$path';
}

/// A shell action from [macosSpotlightActions].
class MacosSpotlightActionResult extends MacosSpotlightResult {
  const MacosSpotlightActionResult(this.action);

  final MacosSpotlightAction action;

  @override
  String get resultId => 'action:${action.name}';
}

/// A clipboard history entry. Sensitive content is never decoded here: the
/// entry model only carries the compositor-redacted preview metadata.
class MacosSpotlightClipboardResult extends MacosSpotlightResult {
  const MacosSpotlightClipboardResult(this.entry);

  final ClipboardHistoryEntry entry;

  @override
  String get resultId => 'clipboard:${entry.id}';
}

/// Broad file-type buckets used as the Files mode category filter.
enum MacosSpotlightFileCategory {
  documents(<String>{
    '.txt',
    '.md',
    '.pdf',
    '.doc',
    '.docx',
    '.odt',
    '.rtf',
    '.csv',
    '.xls',
    '.xlsx',
    '.ods',
    '.ppt',
    '.pptx',
    '.odp',
    '.epub',
    '.pages',
    '.numbers',
    '.key',
  }),
  images(<String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
    '.svg',
    '.heic',
    '.tiff',
    '.avif',
  }),
  audio(<String>{'.mp3', '.flac', '.ogg', '.wav', '.m4a', '.opus', '.aac'}),
  video(<String>{'.mp4', '.mkv', '.webm', '.mov', '.avi', '.m4v'}),
  other(<String>{});

  const MacosSpotlightFileCategory(this.extensions);

  /// Lowercase extensions (with leading dot) belonging to this bucket.
  final Set<String> extensions;
}

/// Buckets [path] by its lowercase extension; unknown extensions and
/// directories land in [MacosSpotlightFileCategory.other].
MacosSpotlightFileCategory macosSpotlightFileCategoryFor(String path) {
  final extension = p.extension(path).toLowerCase();
  for (final category in MacosSpotlightFileCategory.values) {
    if (category.extensions.contains(extension)) {
      return category;
    }
  }
  return MacosSpotlightFileCategory.other;
}

/// Clipboard buckets used as the Clipboard mode category filter.
enum MacosSpotlightClipboardCategory { text, image, files }

MacosSpotlightClipboardCategory macosSpotlightClipboardCategoryFor(
  ClipboardHistoryEntry entry,
) {
  if (entry.isImage) {
    return MacosSpotlightClipboardCategory.image;
  }
  for (final mimeType in entry.mimeTypes) {
    if (mimeType.toLowerCase() == 'text/uri-list') {
      return MacosSpotlightClipboardCategory.files;
    }
  }
  return MacosSpotlightClipboardCategory.text;
}

/// Bounded, cancellable file search behind the Spotlight Files mode.
abstract interface class MacosSpotlightFileSearcher {
  /// Returns matching paths, most relevant first. Implementations must honor
  /// [isCancelled] between filesystem steps and must never throw on
  /// filesystem errors; failures yield partial or empty results.
  Future<List<MacosSpotlightFileResult>> search(
    String query, {
    MacosSpotlightFileCategory? category,
    bool Function()? isCancelled,
  });
}

/// Deliberately bounded filesystem search for the Files mode.
///
/// Denial does not keep a full-disk file index. This source performs a
/// breadth-first scan of the user document roots returned by
/// [macosSpotlightFileRoots] with hard limits: at most [maxDepth] levels
/// below each root, at most [maxDirectories] directories visited in total,
/// and at most [maxResults] matches. A blank query returns no results so the
/// surface never enumerates the tree unprompted.
///
/// Traversal uses `Directory.list` streams, so directory enumeration stays
/// asynchronous and never blocks the Flutter UI isolate on synchronous I/O.
/// [isCancelled] is consulted between entries and directories; stale queries
/// abort early instead of continuing to walk the tree.
class MacosSpotlightFileSearch implements MacosSpotlightFileSearcher {
  MacosSpotlightFileSearch({
    required List<String> roots,
    this.maxDepth = 3,
    this.maxResults = 40,
    this.maxDirectories = 256,
  }) : roots = List<String>.unmodifiable(roots);

  /// Absolute directory paths scanned at depth zero, in order.
  final List<String> roots;

  /// Maximum directory depth below a root.
  final int maxDepth;

  /// Maximum matches returned by one query.
  final int maxResults;

  /// Maximum directories visited by one query.
  final int maxDirectories;

  @override
  Future<List<MacosSpotlightFileResult>> search(
    String query, {
    MacosSpotlightFileCategory? category,
    bool Function()? isCancelled,
  }) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return const <MacosSpotlightFileResult>[];
    }
    bool cancelled() => isCancelled?.call() ?? false;
    final results = <String, MacosSpotlightFileResult>{};
    final pending = <({String path, int depth})>[
      for (final root in roots) (path: root, depth: 0),
    ];
    var pendingIndex = 0;
    var visited = 0;
    while (pendingIndex < pending.length &&
        visited < maxDirectories &&
        results.length < maxResults &&
        !cancelled()) {
      final entry = pending[pendingIndex++];
      if (entry.depth > maxDepth) {
        continue;
      }
      visited += 1;
      final directory = Directory(entry.path);
      try {
        if (!await directory.exists()) {
          continue;
        }
        await for (final entity in directory.list(followLinks: false)) {
          if (cancelled() || results.length >= maxResults) {
            break;
          }
          final name = p.basename(entity.path);
          if (name.isEmpty || name.startsWith('.')) {
            continue;
          }
          if (entity is Directory) {
            if (name.toLowerCase().contains(normalized) &&
                (category == null ||
                    category == MacosSpotlightFileCategory.other)) {
              results[entity.path] = MacosSpotlightFileResult(
                entity.path,
                isDirectory: true,
              );
            }
            if (entry.depth < maxDepth && visited < maxDirectories) {
              pending.add((path: entity.path, depth: entry.depth + 1));
            }
          } else if (entity is File) {
            if (!name.toLowerCase().contains(normalized)) {
              continue;
            }
            if (category != null &&
                macosSpotlightFileCategoryFor(entity.path) != category) {
              continue;
            }
            results[entity.path] = MacosSpotlightFileResult(
              entity.path,
              isDirectory: false,
            );
          }
        }
      } on FileSystemException {
        // Permission and race failures must not abort the whole search.
      } on Object {
        // A directory vanishing mid-listing is a best-effort scan failure.
      }
    }
    final sorted = results.values.toList(growable: false)
      ..sort((left, right) {
        final byName = p
            .basename(left.path)
            .toLowerCase()
            .compareTo(p.basename(right.path).toLowerCase());
        return byName != 0 ? byName : left.path.compareTo(right.path);
      });
    return List<MacosSpotlightFileResult>.unmodifiable(sorted);
  }
}

/// Default file-search roots: the conventional XDG user directories under
/// `HOME`. `DENIAL_SPOTLIGHT_FILE_ROOTS` may override the list with a
/// colon-separated set of absolute paths for development and tests.
List<String> macosSpotlightFileRoots(Map<String, String> environment) {
  final override = environment['DENIAL_SPOTLIGHT_FILE_ROOTS']?.trim();
  if (override != null && override.isNotEmpty) {
    return List<String>.unmodifiable(
      override
          .split(':')
          .map((path) => path.trim())
          .where((path) => path.isNotEmpty),
    );
  }
  final home = environment['HOME'] ?? '';
  if (home.isEmpty) {
    return const <String>[];
  }
  return List<String>.unmodifiable(<String>[
    for (final name in const <String>[
      'Desktop',
      'Documents',
      'Downloads',
      'Pictures',
      'Music',
      'Videos',
    ])
      p.join(home, name),
  ]);
}

final macosSpotlightFileSearchProvider = Provider<MacosSpotlightFileSearcher>((
  ref,
) {
  return MacosSpotlightFileSearch(
    roots: macosSpotlightFileRoots(ref.watch(runtimePathsProvider).environment),
  );
});

/// Distinct freedesktop categories present in [apps], sorted
/// case-insensitively for deterministic filter chips.
List<String> macosSpotlightApplicationCategories(List<DesktopApp> apps) {
  final categories = <String>{for (final app in apps) ...app.categories};
  final sorted = categories.toList(growable: false)
    ..sort(
      (left, right) => left.toLowerCase().compareTo(right.toLowerCase()) != 0
          ? left.toLowerCase().compareTo(right.toLowerCase())
          : left.compareTo(right),
    );
  return List<String>.unmodifiable(sorted);
}

/// Filters [apps] to a single freedesktop [category]; `null` keeps all.
List<DesktopApp> filterMacosApplicationsByCategory(
  List<DesktopApp> apps,
  String? category,
) {
  if (category == null) {
    return apps;
  }
  return List<DesktopApp>.unmodifiable(
    apps.where((app) => app.categories.contains(category)),
  );
}

/// Lowercase haystack for an action's localized label and stable identifiers.
String macosSpotlightActionSearchText(
  MacosSpotlightAction action,
  String label,
) {
  return '${action.name} ${action.shortcutAction?.name ?? ''} $label'
      .toLowerCase();
}

/// Filters the action catalogue by a case-insensitive substring match over
/// each action's [macosSpotlightActionSearchText].
List<MacosSpotlightAction> filterMacosSpotlightActions(
  Iterable<MacosSpotlightAction> actions,
  String query, {
  required String Function(MacosSpotlightAction action) labelFor,
}) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) {
    return List<MacosSpotlightAction>.unmodifiable(actions);
  }
  return List<MacosSpotlightAction>.unmodifiable(
    actions.where(
      (action) => macosSpotlightActionSearchText(
        action,
        labelFor(action),
      ).contains(normalized),
    ),
  );
}

/// Filters clipboard entries by query over the compositor-provided preview
/// metadata (preview text, source title, and source app id), optionally
/// restricted to [category], capped at [limit] entries.
List<ClipboardHistoryEntry> filterMacosSpotlightClipboardEntries(
  List<ClipboardHistoryEntry> entries,
  String query, {
  MacosSpotlightClipboardCategory? category,
  int limit = 40,
}) {
  final normalized = query.trim().toLowerCase();
  final filtered = <ClipboardHistoryEntry>[];
  for (final entry in entries) {
    if (category != null &&
        macosSpotlightClipboardCategoryFor(entry) != category) {
      continue;
    }
    if (normalized.isNotEmpty &&
        !'${entry.preview} ${entry.sourceTitle} ${entry.sourceAppId}'
            .toLowerCase()
            .contains(normalized)) {
      continue;
    }
    filtered.add(entry);
    if (filtered.length >= limit) {
      break;
    }
  }
  return List<ClipboardHistoryEntry>.unmodifiable(filtered);
}

/// Persists small macOS Spotlight preferences under the shell's state
/// directory (`$XDG_STATE_HOME/denial/macos-spotlight.json`), matching the
/// atomic write pattern used by the application-recents repository.
class MacosSpotlightStateStore {
  const MacosSpotlightStateStore({required this.paths});

  final RuntimePaths paths;

  static const int _version = 1;

  Future<MacosSpotlightViewMode?> readViewMode() async {
    try {
      final file = await _stateFile();
      if (!await file.exists()) {
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['version'] != _version) {
        return null;
      }
      return MacosSpotlightViewMode.tryParse(decoded['viewMode'] as String?);
    } on Object {
      return null;
    }
  }

  Future<void> writeViewMode(MacosSpotlightViewMode mode) async {
    try {
      final file = await _stateFile();
      final temporary = File('${file.path}.tmp');
      final payload = jsonEncode(<String, Object>{
        'version': _version,
        'viewMode': mode.name,
      });
      await temporary.writeAsString('$payload\n', flush: true);
      await temporary.rename(file.path);
    } on Object {
      // The chosen view is a convenience; a failed write keeps the default.
    }
  }

  Future<File> _stateFile() async {
    final directory = Directory(p.join(paths.stateHome, 'denial'));
    await directory.create(recursive: true);
    return File(p.join(directory.path, 'macos-spotlight.json'));
  }
}

final macosSpotlightStateStoreProvider = Provider<MacosSpotlightStateStore>((
  ref,
) {
  return MacosSpotlightStateStore(paths: ref.watch(runtimePathsProvider));
});

/// Persisted grid/list choice for the Spotlight surface.
final macosSpotlightViewModeProvider =
    NotifierProvider<MacosSpotlightViewModeController, MacosSpotlightViewMode>(
      MacosSpotlightViewModeController.new,
    );

class MacosSpotlightViewModeController
    extends Notifier<MacosSpotlightViewMode> {
  int _restoreSerial = 0;

  @override
  MacosSpotlightViewMode build() {
    final store = ref.watch(macosSpotlightStateStoreProvider);
    final serial = ++_restoreSerial;
    unawaited(
      store.readViewMode().then((saved) {
        if (saved != null && ref.mounted && serial == _restoreSerial) {
          state = saved;
        }
      }),
    );
    return MacosSpotlightViewMode.grid;
  }

  void setMode(MacosSpotlightViewMode mode) {
    if (state == mode) {
      return;
    }
    state = mode;
    unawaited(ref.read(macosSpotlightStateStoreProvider).writeViewMode(mode));
  }
}
