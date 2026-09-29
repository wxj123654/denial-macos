import 'dart:convert';
import 'dart:io';

import 'package:denial_dart_shell/src/desktop/desktop_workspace.dart';
import 'package:denial_dart_shell/src/launcher/models/desktop_app.dart';
import 'package:denial_dart_shell/src/launcher/runtime_paths.dart';
import 'package:denial_dart_shell/src/macos/macos_dock_model.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:flutter/widgets.dart' show Rect;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/mobile_motion_harness.dart';

DesktopApp _testApp(String id, String name, {String? startupWmClass}) {
  return DesktopApp(
    id: id,
    name: name,
    exec: 'unused',
    desktopPath: 'unused',
    categories: const <String>[],
    startupWmClass: startupWmClass,
  );
}

List<String> _expectedIds(DesktopApp app) => <String>[
  app.id,
  if (app.id.endsWith('.desktop'))
    app.id.substring(0, app.id.length - '.desktop'.length),
  if (app.startupWmClass != null) app.startupWmClass!,
];

DesktopWindowPlacement _placement(
  int objectId, {
  int z = 0,
  bool minimized = false,
}) {
  return DesktopWindowPlacement(
    objectId: objectId,
    frame: const Rect.fromLTWH(0, 0, 100, 100),
    z: z,
    monitorId: 1,
    minimized: minimized,
  );
}

List<MacosDockEntry> _entries({
  List<DenialWindow> windows = const <DenialWindow>[],
  Map<int, DesktopWindowPlacement> placements =
      const <int, DesktopWindowPlacement>{},
  List<DesktopApp> installedApps = const <DesktopApp>[],
  List<String> pinnedIds = const <String>[],
  int? foregroundObjectId,
}) {
  return macosDockEntries(
    windows: windows,
    placements: placements,
    installedApps: installedApps,
    expectedWindowAppIds: _expectedIds,
    pinnedIds: pinnedIds,
    foregroundObjectId: foregroundObjectId,
  );
}

void main() {
  group('macosDockEntries', () {
    test('groups multiple windows of one application into a single entry', () {
      final app = _testApp('firefox.desktop', 'Firefox');
      final entries = _entries(
        windows: <DenialWindow>[
          motionWindow(1, appId: 'firefox'),
          motionWindow(2, appId: 'Firefox'),
        ],
        installedApps: <DesktopApp>[app],
      );

      expect(entries, hasLength(1));
      expect(entries.single.id, 'firefox.desktop');
      expect(entries.single.app, same(app));
      expect(entries.single.windows, hasLength(2));
      expect(entries.single.pinId, 'firefox.desktop');
      expect(entries.single.label, 'Firefox');
    });

    test('matches a window through the launcher identity candidates', () {
      final app = _testApp(
        'org.code.desktop',
        'Code',
        startupWmClass: 'CodeStable',
      );
      final entries = _entries(
        windows: <DenialWindow>[motionWindow(1, appId: 'codestable')],
        installedApps: <DesktopApp>[app],
      );

      expect(entries, hasLength(1));
      expect(entries.single.id, 'org.code.desktop');
      expect(entries.single.app, same(app));
    });

    test('keeps unresolvable applications as identity groups', () {
      final entries = _entries(
        windows: <DenialWindow>[
          motionWindow(1, appId: 'alpha'),
          motionWindow(2, appId: 'beta'),
          motionWindow(3, appId: 'alpha'),
        ],
      );

      expect(entries, hasLength(2));
      expect(entries[0].id, 'alpha');
      expect(entries[0].windows, hasLength(2));
      expect(entries[1].id, 'beta');
      expect(entries[1].windows, hasLength(1));
      expect(entries[0].app, isNull);
      expect(entries[0].pinned, isFalse);
    });

    test('orders pinned entries first in pin order, then running groups', () {
      final entries = _entries(
        windows: <DenialWindow>[
          motionWindow(1, appId: 'running-a'),
          motionWindow(2, appId: 'running-b'),
        ],
        pinnedIds: const <String>['z.desktop', 'a.desktop'],
      );

      expect(entries.map((entry) => entry.id), <String>[
        'z.desktop',
        'a.desktop',
        'running-a',
        'running-b',
      ]);
      expect(entries[0].pinned, isTrue);
      expect(entries[0].running, isFalse);
      expect(entries[1].running, isFalse);
      expect(entries[2].running, isTrue);
    });

    test('merges a running group into its pinned entry', () {
      final app = _testApp('firefox.desktop', 'Firefox');
      final entries = _entries(
        windows: <DenialWindow>[motionWindow(1, appId: 'firefox')],
        installedApps: <DesktopApp>[app],
        pinnedIds: const <String>['firefox.desktop'],
      );

      expect(entries, hasLength(1));
      expect(entries.single.pinned, isTrue);
      expect(entries.single.running, isTrue);
      expect(entries.single.pinId, 'firefox.desktop');
    });

    test('merges a running group into a pin recorded by raw app identity', () {
      final app = _testApp('firefox.desktop', 'Firefox');
      final entries = _entries(
        windows: <DenialWindow>[motionWindow(1, appId: 'firefox')],
        installedApps: <DesktopApp>[app],
        pinnedIds: const <String>['firefox'],
      );

      expect(entries, hasLength(1));
      expect(entries.single.pinned, isTrue);
      expect(entries.single.app, same(app));
      expect(entries.single.pinId, 'firefox');
    });

    test('tracks minimized windows on the entry', () {
      final entries = _entries(
        windows: <DenialWindow>[
          motionWindow(1, appId: 'alpha'),
          motionWindow(2, appId: 'alpha'),
        ],
        placements: <int, DesktopWindowPlacement>{
          1: _placement(1, minimized: true),
          2: _placement(2),
        },
      );

      expect(entries.single.running, isTrue);
      expect(entries.single.minimizedObjectIds, <int>{1});
      expect(entries.single.allWindowsMinimized, isFalse);
    });

    test('marks the entry owning the foreground window active', () {
      final entries = _entries(
        windows: <DenialWindow>[
          motionWindow(1, appId: 'alpha'),
          motionWindow(2, appId: 'beta'),
        ],
        foregroundObjectId: 2,
      );

      expect(entries[0].active, isFalse);
      expect(entries[1].active, isTrue);
    });

    test('orders a group back-to-front by placement z', () {
      final entries = _entries(
        windows: <DenialWindow>[
          motionWindow(1, appId: 'alpha'),
          motionWindow(2, appId: 'alpha'),
        ],
        placements: <int, DesktopWindowPlacement>{
          1: _placement(1, z: 9),
          2: _placement(2, z: 1),
        },
      );

      expect(entries.single.windows.map((window) => window.objectId), <int>[
        2,
        1,
      ]);
    });

    test('closing the final window removes only unpinned entries', () {
      final app = _testApp('keep.desktop', 'Keep');
      final opened = _entries(
        windows: <DenialWindow>[
          motionWindow(1, appId: 'keep'),
          motionWindow(2, appId: 'transient'),
        ],
        installedApps: <DesktopApp>[app],
        pinnedIds: const <String>['keep.desktop'],
      );
      expect(opened, hasLength(2));

      final closed = _entries(
        windows: const <DenialWindow>[],
        installedApps: <DesktopApp>[app],
        pinnedIds: const <String>['keep.desktop'],
      );
      expect(closed, hasLength(1));
      expect(closed.single.id, 'keep.desktop');
      expect(closed.single.running, isFalse);
      expect(closed.single.pinned, isTrue);
    });
  });

  group('MacosDockPinsController', () {
    test('pins, unpins, and reorders deterministically', () async {
      final store = _MemoryDockPinsStore();
      final container = ProviderContainer(
        overrides: [macosDockPinsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      final controller = container.read(macosDockPinsProvider.notifier);

      controller.pin('a.desktop');
      controller.pin('b.desktop');
      controller.pin('a.desktop');
      controller.pin('  ');
      expect(container.read(macosDockPinsProvider), <String>[
        'a.desktop',
        'b.desktop',
      ]);
      expect(controller.isPinned('a.desktop'), isTrue);

      controller.reorder(0, 2);
      expect(container.read(macosDockPinsProvider), <String>[
        'b.desktop',
        'a.desktop',
      ]);

      controller.unpin('b.desktop');
      expect(container.read(macosDockPinsProvider), <String>['a.desktop']);

      await Future<void>.delayed(Duration.zero);
      expect(store.writes, isNotEmpty);
      expect(store.writes.last, <String>['a.desktop']);
    });

    test('restores the persisted pin order on a new session', () async {
      final store = _MemoryDockPinsStore()
        ..saved = <String>['one.desktop', 'two.desktop'];
      final container = ProviderContainer(
        overrides: [macosDockPinsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      expect(container.read(macosDockPinsProvider), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(macosDockPinsProvider), <String>[
        'one.desktop',
        'two.desktop',
      ]);
    });

    test('keeps local mutations over a racing store read', () async {
      final store = _MemoryDockPinsStore()..saved = <String>['stale.desktop'];
      final container = ProviderContainer(
        overrides: [macosDockPinsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      final controller = container.read(macosDockPinsProvider.notifier);
      controller.pin('fresh.desktop');

      await Future<void>.delayed(Duration.zero);
      expect(container.read(macosDockPinsProvider), <String>['fresh.desktop']);
      expect(store.writes.last, <String>['fresh.desktop']);
    });
  });

  group('MacosDockPinsRepository', () {
    test('round-trips pins through the state file', () async {
      final temp = await Directory.systemTemp.createTemp('macos-dock-pins');
      addTearDown(() => temp.delete(recursive: true));
      final repository = MacosDockPinsRepository(
        paths: RuntimePaths(
          environment: <String, String>{
            'HOME': temp.path,
            'XDG_STATE_HOME': '${temp.path}/state',
          },
        ),
      );

      await repository.writePins(<String>['b.desktop', 'a.desktop']);
      expect(await repository.readPins(), <String>['b.desktop', 'a.desktop']);

      final file = File('${temp.path}/state/denial/macos-dock-pins.json');
      expect(await file.exists(), isTrue);
      final decoded = jsonDecode(await file.readAsString());
      expect(decoded, isA<Map<String, dynamic>>());
      expect(decoded['version'], 1);
    });

    test('normalizes persisted pin lists', () async {
      final temp = await Directory.systemTemp.createTemp('macos-dock-pins');
      addTearDown(() => temp.delete(recursive: true));
      final repository = MacosDockPinsRepository(
        paths: RuntimePaths(
          environment: <String, String>{'XDG_STATE_HOME': temp.path},
        ),
      );
      final file = File('${temp.path}/denial/macos-dock-pins.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(<String, Object>{
          'version': 1,
          'pins': <Object?>[' a.desktop ', '', 'a.desktop', 42, 'b.desktop'],
        }),
      );

      expect(await repository.readPins(), <String>['a.desktop', 'b.desktop']);
    });

    test('fails closed on malformed documents', () async {
      final temp = await Directory.systemTemp.createTemp('macos-dock-pins');
      addTearDown(() => temp.delete(recursive: true));
      final repository = MacosDockPinsRepository(
        paths: RuntimePaths(
          environment: <String, String>{'XDG_STATE_HOME': temp.path},
        ),
      );
      final file = File('${temp.path}/denial/macos-dock-pins.json');
      await file.parent.create(recursive: true);
      await file.writeAsString('not json');

      expect(await repository.readPins(), isEmpty);
    });
  });
}

class _MemoryDockPinsStore implements MacosDockPinsStore {
  List<String> saved = const <String>[];
  final List<List<String>> writes = <List<String>>[];

  @override
  Future<List<String>> readPins() async => saved;

  @override
  Future<void> writePins(List<String> pins) async {
    writes.add(pins);
    saved = pins;
  }
}
