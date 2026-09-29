import 'dart:async';
import 'dart:io';

import 'package:denial_dart_shell/src/launcher/controllers/application_recents_controller.dart';
import 'package:denial_dart_shell/src/launcher/controllers/home_grid_controller.dart';
import 'package:denial_dart_shell/src/launcher/models/desktop_app.dart';
import 'package:denial_dart_shell/src/launcher/models/home_grid_item.dart';
import 'package:denial_dart_shell/src/launcher/runtime_paths.dart';
import 'package:denial_dart_shell/src/macos/macos_applications_surface.dart';
import 'package:denial_dart_shell/src/macos/macos_spotlight_sources.dart';
import 'package:denial_dart_shell/src/models/clipboard_history.dart';
import 'package:denial_dart_shell/src/state/clipboard_tray.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/state/shell_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import '../support/mobile_motion_harness.dart';

DesktopApp _testApp(
  String id,
  String name, {
  List<String> categories = const <String>[],
  List<String> keywords = const <String>[],
}) => DesktopApp(
  id: id,
  name: name,
  exec: 'unused',
  desktopPath: 'unused',
  categories: categories,
  keywords: keywords,
);

Widget _surfaceHarness(Widget child) => mobileMotionHarness(
  MacosTheme(data: MacosThemeData.light(), child: child),
  size: const Size(1000, 700),
);

void main() {
  group('macosSpotlightFileRoots', () {
    test('uses the conventional user directories under HOME', () {
      final roots = macosSpotlightFileRoots(const <String, String>{
        'HOME': '/home/test',
      });
      expect(roots, contains('/home/test/Documents'));
      expect(roots, contains('/home/test/Downloads'));
      expect(roots, hasLength(6));
    });

    test('honors the DENIAL_SPOTLIGHT_FILE_ROOTS override', () {
      final roots = macosSpotlightFileRoots(const <String, String>{
        'HOME': '/home/test',
        'DENIAL_SPOTLIGHT_FILE_ROOTS': '/a/b:/c/d',
      });
      expect(roots, <String>['/a/b', '/c/d']);
    });
  });

  group('MacosSpotlightFileSearch', () {
    late Directory root;
    late List<String> created;

    setUp(() {
      root = Directory.systemTemp.createTempSync('spotlight-files');
      created = <String>[root.path];
    });

    tearDown(() {
      for (final path in created) {
        final directory = Directory(path);
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      }
    });

    File makeFile(String relative) {
      final file = File('${root.path}/$relative');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('x');
      return file;
    }

    test('blank queries never touch the filesystem', () async {
      final search = MacosSpotlightFileSearch(roots: <String>[root.path]);
      expect(await search.search('   '), isEmpty);
    });

    test(
      'matches basenames, bounds depth, and sorts deterministically',
      () async {
        makeFile('notes.md');
        makeFile('deep/notes.md');
        makeFile('deep/deeper/deepest/notes.md');
        makeFile('deep/deeper/deepest/buried/notes.md');
        makeFile('unrelated.txt');

        final search = MacosSpotlightFileSearch(roots: <String>[root.path]);
        final results = await search.search('notes');
        final names = results.map((result) => result.path).toList();
        // maxDepth 3 reaches root/deep/deeper/deepest but not buried/.
        expect(names.where((path) => path.contains('buried')), isEmpty);
        expect(names.length, 3);
      },
    );

    test('applies the file-category filter and result cap', () async {
      for (var index = 0; index < 5; index += 1) {
        makeFile('song$index.mp3');
      }
      makeFile('song.txt');
      final search = MacosSpotlightFileSearch(
        roots: <String>[root.path],
        maxResults: 3,
      );
      final results = await search.search(
        'song',
        category: MacosSpotlightFileCategory.audio,
      );
      expect(results, hasLength(3));
      expect(results.every((result) => result.path.endsWith('.mp3')), isTrue);
    });

    test('honors cancellation mid-traversal', () async {
      for (var index = 0; index < 8; index += 1) {
        makeFile('dir$index/needle.txt');
      }
      var calls = 0;
      final search = MacosSpotlightFileSearch(roots: <String>[root.path]);
      final results = await search.search(
        'needle',
        isCancelled: () => ++calls > 1,
      );
      expect(results, isEmpty);
    });
  });

  group('filterMacosSpotlightClipboardEntries', () {
    ClipboardHistoryEntry entry(
      int id,
      String preview, {
      ClipboardHistoryContentKind kind = ClipboardHistoryContentKind.text,
      List<String> mimeTypes = const <String>['text/plain'],
      String sourceTitle = '',
    }) => ClipboardHistoryEntry(
      id: id,
      capturedAt: DateTime.utc(2026),
      byteLength: preview.length,
      width: 0,
      height: 0,
      origin: ClipboardHistoryOrigin.wayland,
      kind: kind,
      pinned: false,
      active: false,
      preview: preview,
      sourceAppId: 'app',
      sourceTitle: sourceTitle,
      mimeTypes: mimeTypes,
    );

    test('matches preview text and applies the content-kind filter', () {
      final entries = <ClipboardHistoryEntry>[
        entry(1, 'hello world'),
        entry(
          2,
          'pixels',
          kind: ClipboardHistoryContentKind.image,
          mimeTypes: const <String>['image/png'],
        ),
        entry(3, 'files', mimeTypes: const <String>['text/uri-list']),
      ];
      expect(
        filterMacosSpotlightClipboardEntries(entries, 'HELLO').single.id,
        1,
      );
      expect(
        filterMacosSpotlightClipboardEntries(
          entries,
          '',
          category: MacosSpotlightClipboardCategory.image,
        ).single.id,
        2,
      );
      expect(
        filterMacosSpotlightClipboardEntries(
          entries,
          '',
          category: MacosSpotlightClipboardCategory.files,
        ).single.id,
        3,
      );
    });
  });

  group('filterMacosSpotlightActions', () {
    test('matches localized labels and stable identifiers', () {
      expect(
        filterMacosSpotlightActions(
          macosSpotlightActions,
          'lock',
          labelFor: (action) => switch (action) {
            MacosSpotlightAction.lockScreen => 'Lock screen',
            _ => 'Other',
          },
        ),
        <MacosSpotlightAction>[MacosSpotlightAction.lockScreen],
      );
      expect(
        filterMacosSpotlightActions(
          macosSpotlightActions,
          'zzzz',
          labelFor: (action) => action.name,
        ),
        isEmpty,
      );
    });
  });

  group('MacosSpotlightViewModeController', () {
    test('restores the saved mode and persists changes', () async {
      final store = _RecordingStore(saved: MacosSpotlightViewMode.list);
      final container = ProviderContainer(
        overrides: [macosSpotlightStateStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      expect(
        container.read(macosSpotlightViewModeProvider),
        MacosSpotlightViewMode.grid,
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(macosSpotlightViewModeProvider),
        MacosSpotlightViewMode.list,
      );
      container
          .read(macosSpotlightViewModeProvider.notifier)
          .setMode(MacosSpotlightViewMode.grid);
      expect(store.writes, <MacosSpotlightViewMode>[
        MacosSpotlightViewMode.grid,
      ]);
    });
  });

  testWidgets('mode switching swaps the result source', (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final search = _FakeFileSearch();
    await tester.pumpWidget(
      _surfaceScope(
        search: search,
        child: _surfaceHarness(
          MacosApplicationsSurface(
            searchFocusNode: focusNode,
            onDismiss: () {},
            onLaunch: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Alpha Editor'), findsOneWidget);
    expect(search.queries, isEmpty);

    await tester.tap(
      find.byKey(macosSpotlightModeKey(MacosSpotlightMode.files)),
    );
    await tester.pumpAndSettle();
    // Selecting Files triggers the bounded query immediately.
    expect(search.queries, <String>['']);
    expect(find.text('Alpha Editor'), findsNothing);

    await tester.tap(
      find.byKey(macosSpotlightModeKey(MacosSpotlightMode.actions)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Lock screen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale file queries are cancelled and discarded', (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final search = _FakeFileSearch();
    await tester.pumpWidget(
      _surfaceScope(
        search: search,
        child: _surfaceHarness(
          MacosApplicationsSurface(
            searchFocusNode: focusNode,
            onDismiss: () {},
            onLaunch: (_) {},
            initialMode: MacosSpotlightMode.files,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(EditableText), 'aa');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(search.queries.last, 'aa');
    final firstCompleter = search.completers.last!;

    await tester.enterText(find.byType(EditableText), 'bb');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(search.queries.last, 'bb');
    // The earlier traversal was told to cancel before the newer query ran.
    expect(search.wasCancelled(1), isTrue);

    firstCompleter.complete(const <MacosSpotlightFileResult>[
      MacosSpotlightFileResult('/stale/aaa.txt', isDirectory: false),
    ]);
    await tester.pump();
    expect(find.text('aaa.txt'), findsNothing);

    search.completers.last!.complete(const <MacosSpotlightFileResult>[
      MacosSpotlightFileResult('/fresh/bbb.txt', isDirectory: false),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('bbb.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a locked clipboard snapshot renders the sealed state', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      _surfaceScope(
        clipboard: _FakeClipboard(
          const ClipboardHistoryViewState(
            loading: false,
            snapshot: ClipboardHistorySnapshot(
              revision: 1,
              totalBytes: 0,
              activeId: null,
              paused: false,
              locked: true,
              entries: <ClipboardHistoryEntry>[],
            ),
          ),
        ),
        child: _surfaceHarness(
          MacosApplicationsSurface(
            searchFocusNode: focusNode,
            onDismiss: () {},
            onLaunch: (_) {},
            initialMode: MacosSpotlightMode.clipboard,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(macosSpotlightClipboardLockedKey), findsOneWidget);
    expect(find.text('History is sealed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clipboard entries activate once through the controller', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    var dismissed = 0;
    final clipboard = _FakeClipboard(
      ClipboardHistoryViewState(
        loading: false,
        snapshot: ClipboardHistorySnapshot(
          revision: 1,
          totalBytes: 5,
          activeId: null,
          paused: false,
          locked: false,
          entries: <ClipboardHistoryEntry>[
            ClipboardHistoryEntry(
              id: 7,
              capturedAt: DateTime.utc(2026),
              byteLength: 5,
              width: 0,
              height: 0,
              origin: ClipboardHistoryOrigin.wayland,
              kind: ClipboardHistoryContentKind.text,
              pinned: false,
              active: false,
              preview: 'hello spotlight',
              sourceAppId: 'org.test',
              sourceTitle: 'Editor',
              mimeTypes: const <String>['text/plain'],
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(
      _surfaceScope(
        clipboard: clipboard,
        child: _surfaceHarness(
          MacosApplicationsSurface(
            searchFocusNode: focusNode,
            onDismiss: () => dismissed += 1,
            onLaunch: (_) {},
            initialMode: MacosSpotlightMode.clipboard,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('hello spotlight'), findsOneWidget);
    await tester.tap(find.text('hello spotlight'));
    await tester.pumpAndSettle();
    expect(clipboard.activated, <int>[7]);
    expect(dismissed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('application category chips filter the catalogue', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      _surfaceScope(
        slots: <HomeGridItem?>[
          HomeGridItem.app(
            _testApp(
              'org.alpha',
              'Alpha Editor',
              categories: const <String>['Utility'],
            ),
          ),
          HomeGridItem.app(
            _testApp(
              'org.beta',
              'Beta Player',
              categories: const <String>['Audio'],
            ),
          ),
        ],
        child: _surfaceHarness(
          MacosApplicationsSurface(
            searchFocusNode: focusNode,
            onDismiss: () {},
            onLaunch: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(macosSpotlightFilterKey('Audio')));
    await tester.pump();
    expect(find.text('Beta Player'), findsOneWidget);
    expect(find.text('Alpha Editor'), findsNothing);
    await tester.tap(find.byKey(macosSpotlightFilterKey('all')));
    await tester.pump();
    expect(find.text('Alpha Editor'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the view toggle persists the list choice', (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final store = _RecordingStore();
    await tester.pumpWidget(
      _surfaceScope(
        store: store,
        child: _surfaceHarness(
          MacosApplicationsSurface(
            searchFocusNode: focusNode,
            onDismiss: () {},
            onLaunch: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey<String>(
          'macos-spotlight-result-applications-catalog:org.alpha',
        ),
      ),
      findsNothing,
    );
    await tester.tap(find.byKey(macosSpotlightViewToggleKey));
    await tester.pump();
    expect(store.writes, <MacosSpotlightViewMode>[MacosSpotlightViewMode.list]);
    await tester.pump();
    expect(
      find.byKey(
        const ValueKey<String>(
          'macos-spotlight-result-applications-catalog:org.alpha',
        ),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

/// Wraps [child] in a [ProviderScope] seeded with the deterministic fakes the
/// Spotlight surface resolves its modes from.
Widget _surfaceScope({
  required Widget child,
  _FakeFileSearch? search,
  _FakeClipboard? clipboard,
  List<HomeGridItem?>? slots,
  MacosSpotlightStateStore? store,
}) {
  return ProviderScope(
    overrides: [
      homeGridControllerProvider.overrideWith(
        () => _SpotlightGrid(
          slots ??
              <HomeGridItem?>[
                HomeGridItem.app(_testApp('org.alpha', 'Alpha Editor')),
                HomeGridItem.app(_testApp('org.beta', 'Beta Player')),
              ],
        ),
      ),
      applicationRecentsProvider.overrideWith(
        () => _SpotlightRecents(const <String>[]),
      ),
      macosSpotlightFileSearchProvider.overrideWithValue(
        search ?? _FakeFileSearch(),
      ),
      clipboardHistoryProvider.overrideWith(
        () => clipboard ?? _FakeClipboard(const ClipboardHistoryViewState()),
      ),
      shellControllerProvider.overrideWith(() => _SpotlightShell()),
      if (store != null)
        macosSpotlightStateStoreProvider.overrideWithValue(store),
    ],
    child: child,
  );
}

class _SpotlightGrid extends HomeGridController {
  _SpotlightGrid(this.slots);

  final List<HomeGridItem?> slots;

  @override
  Future<HomeGridState> build() async => HomeGridState(slots: slots);

  @override
  void setLauncherActive(bool active) {}

  @override
  Future<void> refreshDesktopApps({String reason = 'manual'}) async {}
}

class _SpotlightRecents extends ApplicationRecentsController {
  _SpotlightRecents(this.entries);

  final List<String> entries;

  @override
  List<String> build() => entries;
}

class _SpotlightShell extends ShellController {
  @override
  ShellState build() => ShellState.initial();
}

class _FakeClipboard extends ClipboardHistoryController {
  _FakeClipboard(this.viewState);

  final ClipboardHistoryViewState viewState;
  final List<int> activated = <int>[];

  @override
  ClipboardHistoryViewState build() => viewState;

  @override
  Future<bool> activate(int itemId) async {
    activated.add(itemId);
    return true;
  }
}

/// Deterministic Files-mode source: records queries, exposes cancellation
/// state per request, and lets tests complete searches manually.
class _FakeFileSearch implements MacosSpotlightFileSearcher {
  final List<String> queries = <String>[];
  final List<Completer<List<MacosSpotlightFileResult>>?> completers =
      <Completer<List<MacosSpotlightFileResult>>?>[];
  final List<bool Function()?> _cancellations = <bool Function()?>[];

  bool wasCancelled(int index) => _cancellations[index]?.call() ?? false;

  @override
  Future<List<MacosSpotlightFileResult>> search(
    String query, {
    MacosSpotlightFileCategory? category,
    bool Function()? isCancelled,
  }) {
    queries.add(query);
    _cancellations.add(isCancelled);
    // Mode switches with a blank query resolve immediately, keeping the
    // surface responsive; typed queries stay in-flight for the test.
    if (query.trim().isEmpty) {
      completers.add(null);
      return Future<List<MacosSpotlightFileResult>>.value(
        const <MacosSpotlightFileResult>[],
      );
    }
    final completer = Completer<List<MacosSpotlightFileResult>>();
    completers.add(completer);
    return completer.future;
  }
}

class _RecordingStore extends MacosSpotlightStateStore {
  _RecordingStore({this.saved}) : super(paths: _dummyPaths);

  static final _dummyPaths = RuntimePaths(
    environment: const <String, String>{'HOME': '/nonexistent'},
  );

  final MacosSpotlightViewMode? saved;
  final List<MacosSpotlightViewMode> writes = <MacosSpotlightViewMode>[];

  @override
  Future<MacosSpotlightViewMode?> readViewMode() async => saved;

  @override
  Future<void> writeViewMode(MacosSpotlightViewMode mode) async {
    writes.add(mode);
  }
}
