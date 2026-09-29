import 'dart:io';

import 'package:path/path.dart' as p;

import '../launcher/runtime_paths.dart';

/// Parsed `mimeapps.list` associations in freedesktop lookup order.
///
/// `mimeapps.list` files are supplied to [parseMacosMimeappsLists] in
/// precedence order (see [macosMimeappsListFiles]); the first file which
/// declares a `[Default Applications]` entry for a MIME type wins, while
/// `[Added Associations]` accumulate and `[Removed Associations]` exclude
/// previously added handlers.
class MacosMimeAssociations {
  const MacosMimeAssociations._({
    required this.defaults,
    required this.added,
    required this.removed,
  });

  /// No associations; every lookup resolves to no candidate.
  static const MacosMimeAssociations empty = MacosMimeAssociations._(
    defaults: <String, List<String>>{},
    added: <String, List<String>>{},
    removed: <String, Set<String>>{},
  );

  /// MIME type to its ordered `[Default Applications]` desktop IDs. Only the
  /// highest-precedence file which declares the type contributes the list.
  final Map<String, List<String>> defaults;

  /// MIME type to the accumulated ordered `[Added Associations]` IDs.
  final Map<String, List<String>> added;

  /// MIME type to the `[Removed Associations]` desktop IDs.
  final Map<String, Set<String>> removed;

  /// Ordered handler candidates for [mimeType]: the default list first, then
  /// added associations which were not removed. Candidates may reference
  /// desktop entries which are not installed; callers decide which one is
  /// usable.
  List<String> candidatesFor(String mimeType) {
    final excluded = removed[mimeType] ?? const <String>{};
    final candidates = <String>[
      ...?defaults[mimeType],
      for (final id in added[mimeType] ?? const <String>[])
        if (!excluded.contains(id)) id,
    ];
    return List<String>.unmodifiable(candidates.toSet());
  }
}

/// Merges `mimeapps.list` file [contents] supplied in precedence order.
MacosMimeAssociations parseMacosMimeappsLists(Iterable<String> contents) {
  final defaults = <String, List<String>>{};
  final added = <String, List<String>>{};
  final removed = <String, Set<String>>{};
  for (final content in contents) {
    var section = '';
    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      if (line.startsWith('[') && line.endsWith(']')) {
        section = line.substring(1, line.length - 1).trim();
        continue;
      }
      final equals = line.indexOf('=');
      if (equals <= 0) {
        continue;
      }
      final mimeType = line.substring(0, equals).trim().toLowerCase();
      final ids = line
          .substring(equals + 1)
          .split(';')
          .map((id) => id.trim())
          .where((id) => id.isNotEmpty)
          .toList(growable: false);
      if (mimeType.isEmpty || ids.isEmpty) {
        continue;
      }
      switch (section) {
        case 'Default Applications':
          defaults.putIfAbsent(mimeType, () => List<String>.unmodifiable(ids));
        case 'Added Associations':
          final list = added.putIfAbsent(mimeType, () => <String>[]);
          for (final id in ids) {
            if (!list.contains(id)) {
              list.add(id);
            }
          }
        case 'Removed Associations':
          removed.putIfAbsent(mimeType, () => <String>{}).addAll(ids);
      }
    }
  }
  return MacosMimeAssociations._(
    defaults: Map<String, List<String>>.unmodifiable(defaults),
    added: Map<String, List<String>>.unmodifiable(
      added.map(
        (mimeType, ids) => MapEntry(mimeType, List<String>.unmodifiable(ids)),
      ),
    ),
    removed: Map<String, Set<String>>.unmodifiable(
      removed.map(
        (mimeType, ids) => MapEntry(mimeType, Set<String>.unmodifiable(ids)),
      ),
    ),
  );
}

/// `mimeapps.list` locations in freedesktop precedence order.
///
/// The desktop-prefixed files take the lowercased entries of
/// `XDG_CURRENT_DESKTOP` (defaulting to `Denial`, matching the desktop-entry
/// catalogue's `OnlyShowIn` handling), followed by the generic file at each
/// location tier.
List<File> macosMimeappsListFiles(RuntimePaths paths) {
  final desktops = (paths.environment['XDG_CURRENT_DESKTOP'] ?? 'Denial')
      .split(':')
      .map((desktop) => desktop.trim().toLowerCase())
      .where((desktop) => desktop.isNotEmpty)
      .toList(growable: false);
  List<String> tier(String directory) {
    return <String>[
      for (final desktop in desktops)
        p.join(directory, '$desktop-mimeapps.list'),
      p.join(directory, 'mimeapps.list'),
    ];
  }

  final files = <String>[
    ...tier(paths.configHome),
    ...tier(p.join(paths.dataHome, 'applications')),
    for (final dir in paths.dataDirs) ...tier(p.join(dir, 'applications')),
  ];
  return RuntimePaths.uniquePaths(files).map(File.new).toList(growable: false);
}

/// Directories worth watching for `mimeapps.list` changes.
List<Directory> macosMimeappsWatchDirectories(RuntimePaths paths) {
  final directories = <String>{
    for (final file in macosMimeappsListFiles(paths)) file.parent.path,
  };
  return directories.map(Directory.new).toList(growable: false);
}

/// Loads every readable `mimeapps.list` below the XDG locations.
Future<MacosMimeAssociations> loadMacosMimeAssociations(
  RuntimePaths paths,
) async {
  final contents = <String>[];
  for (final file in macosMimeappsListFiles(paths)) {
    try {
      if (await file.exists()) {
        contents.add(await file.readAsString());
      }
    } on FileSystemException {
      // Unreadable files are skipped; remaining locations still apply.
    }
  }
  return parseMacosMimeappsLists(contents);
}
