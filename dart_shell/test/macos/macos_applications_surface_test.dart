import 'dart:async';

import 'package:denial_dart_shell/src/launcher/controllers/application_recents_controller.dart';
import 'package:denial_dart_shell/src/launcher/controllers/home_grid_controller.dart';
import 'package:denial_dart_shell/src/launcher/models/desktop_app.dart';
import 'package:denial_dart_shell/src/launcher/models/home_grid_item.dart';
import 'package:denial_dart_shell/src/macos/macos_applications_surface.dart';
import 'package:denial_dart_shell/src/macos/macos_desktop_scene.dart'
    show MacosShellSceneAction, macosShellSceneActionFor;
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import '../support/mobile_motion_harness.dart';

DesktopApp testApp(
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

Widget surfaceHarness(Widget child) => mobileMotionHarness(
  MacosTheme(data: MacosThemeData.light(), child: child),
  size: const Size(1000, 700),
);

void main() {
  group('macosInstalledApplications', () {
    test('deduplicates by app id and sorts by name then id', () {
      final slots = <HomeGridItem?>[
        HomeGridItem.clock(),
        null,
        HomeGridItem.app(testApp('org.beta', 'Beta')),
        HomeGridItem.app(testApp('org.alpha', 'alpha')),
        HomeGridItem.app(testApp('org.dup', 'Zed')),
        HomeGridItem.app(testApp('org.dup', 'Zed Duplicate')),
      ];

      final apps = macosInstalledApplications(slots);

      expect(apps.map((app) => app.id), <String>[
        'org.alpha',
        'org.beta',
        'org.dup',
      ]);
      expect(() => apps.add(testApp('x', 'X')), throwsUnsupportedError);
    });

    test('breaks name ties by id and tolerates null slots', () {
      expect(macosInstalledApplications(null), isEmpty);
      final apps = macosInstalledApplications(<HomeGridItem?>[
        HomeGridItem.app(testApp('org.b', 'Same')),
        HomeGridItem.app(testApp('org.a', 'Same')),
      ]);
      expect(apps.map((app) => app.id), <String>['org.a', 'org.b']);
    });
  });

  group('filterMacosApplications', () {
    final apps = <DesktopApp>[
      testApp(
        'org.alpha',
        'Alpha Editor',
        categories: const <String>['Utility'],
        keywords: const <String>['notepad'],
      ),
      testApp('org.beta', 'Beta Player', categories: const <String>['Audio']),
    ];

    test('returns the input for blank queries', () {
      expect(identical(filterMacosApplications(apps, '   '), apps), isTrue);
      expect(identical(filterMacosApplications(apps, ''), apps), isTrue);
    });

    test('matches name, id, category, and keyword case-insensitively', () {
      expect(filterMacosApplications(apps, ' ALPHA ').single.id, 'org.alpha');
      expect(filterMacosApplications(apps, 'beta').single.id, 'org.beta');
      expect(filterMacosApplications(apps, 'utility').single.id, 'org.alpha');
      expect(filterMacosApplications(apps, 'notepad').single.id, 'org.alpha');
      expect(filterMacosApplications(apps, 'zzzz'), isEmpty);
    });
  });

  group('suggestMacosApplications', () {
    final apps = <DesktopApp>[
      testApp('org.a', 'A'),
      testApp('org.b', 'B'),
      testApp('org.c', 'C'),
    ];

    test('preserves recents order and skips stale and duplicate ids', () {
      final suggested = suggestMacosApplications(apps, <String>[
        'desktop:org.c',
        'local:widget',
        'desktop:org.missing',
        'desktop:org.c',
        'desktop:org.a',
        'desktop:org.b',
      ]);
      expect(suggested.map((app) => app.id), <String>[
        'org.c',
        'org.a',
        'org.b',
      ]);
    });

    test('caps at a non-negative limit', () {
      final recents = <String>['desktop:org.b', 'desktop:org.a'];
      expect(
        suggestMacosApplications(apps, recents, limit: 1).single.id,
        'org.b',
      );
      expect(suggestMacosApplications(apps, recents, limit: 0), isEmpty);
      expect(suggestMacosApplications(apps, recents, limit: -2), isEmpty);
    });
  });

  test('shell action mapping only handles applications and settings', () {
    expect(
      macosShellSceneActionFor(DenialShellAction.applications),
      MacosShellSceneAction.toggleApplications,
    );
    expect(
      macosShellSceneActionFor(DenialShellAction.openSettings),
      MacosShellSceneAction.openSettings,
    );
    for (final action in DenialShellAction.values) {
      if (action == DenialShellAction.applications ||
          action == DenialShellAction.openSettings) {
        continue;
      }
      expect(macosShellSceneActionFor(action), isNull);
    }
  });

  testWidgets('search then Enter launches the first filtered app once', (
    tester,
  ) async {
    final launched = <DesktopApp>[];
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeGridControllerProvider.overrideWith(
            () => _SurfaceGrid(<HomeGridItem?>[
              HomeGridItem.app(testApp('org.alpha', 'Alpha Editor')),
              HomeGridItem.app(testApp('org.beta', 'Beta Player')),
            ]),
          ),
          applicationRecentsProvider.overrideWith(
            () => _SurfaceRecents(const <String>[]),
          ),
        ],
        child: surfaceHarness(
          MacosApplicationsSurface(
            key: macosApplicationsSurfaceKey,
            searchFocusNode: focusNode,
            onDismiss: () {},
            onLaunch: launched.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Alpha Editor'), findsOneWidget);
    expect(find.text('Beta Player'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'beta');
    await tester.pump();
    expect(find.text('Beta Player'), findsOneWidget);
    expect(find.text('Alpha Editor'), findsNothing);

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(launched.map((app) => app.id), <String>['org.beta']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('arrow keys move the selection before Enter launches', (
    tester,
  ) async {
    final launched = <DesktopApp>[];
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeGridControllerProvider.overrideWith(
            () => _SurfaceGrid(<HomeGridItem?>[
              HomeGridItem.app(testApp('org.alpha', 'Alpha Editor')),
              HomeGridItem.app(testApp('org.beta', 'Beta Player')),
            ]),
          ),
          applicationRecentsProvider.overrideWith(
            () => _SurfaceRecents(const <String>[]),
          ),
        ],
        child: surfaceHarness(
          MacosApplicationsSurface(
            searchFocusNode: focusNode,
            onDismiss: () {},
            onLaunch: launched.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(launched.map((app) => app.id), <String>['org.beta']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Escape dismisses the surface', (tester) async {
    var dismissed = 0;
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeGridControllerProvider.overrideWith(
            () => _SurfaceGrid(<HomeGridItem?>[
              HomeGridItem.app(testApp('org.alpha', 'Alpha Editor')),
            ]),
          ),
          applicationRecentsProvider.overrideWith(
            () => _SurfaceRecents(const <String>[]),
          ),
        ],
        child: surfaceHarness(
          MacosApplicationsSurface(
            searchFocusNode: focusNode,
            onDismiss: () => dismissed += 1,
            onLaunch: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(dismissed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('suggested apps launch through onLaunch once', (tester) async {
    final launched = <DesktopApp>[];
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeGridControllerProvider.overrideWith(
            () => _SurfaceGrid(<HomeGridItem?>[
              HomeGridItem.app(testApp('org.alpha', 'Alpha Editor')),
              HomeGridItem.app(testApp('org.beta', 'Beta Player')),
            ]),
          ),
          applicationRecentsProvider.overrideWith(
            () => _SurfaceRecents(const <String>['desktop:org.beta']),
          ),
        ],
        child: surfaceHarness(
          MacosApplicationsSurface(
            searchFocusNode: focusNode,
            onDismiss: () {},
            onLaunch: launched.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Beta appears in the suggested row and the catalogue grid.
    expect(find.text('Beta Player'), findsNWidgets(2));
    await tester.tap(find.text('Beta Player').first);
    await tester.pump();
    expect(launched.map((app) => app.id), <String>['org.beta']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a resolving catalogue shows the loading state', (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeGridControllerProvider.overrideWith(_LoadingGrid.new),
          applicationRecentsProvider.overrideWith(
            () => _SurfaceRecents(const <String>[]),
          ),
        ],
        child: surfaceHarness(
          MacosApplicationsSurface(
            searchFocusNode: focusNode,
            onDismiss: () {},
            onLaunch: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Loading applications…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty catalogue shows the no-results state', (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeGridControllerProvider.overrideWith(
            () => _SurfaceGrid(const <HomeGridItem?>[]),
          ),
          applicationRecentsProvider.overrideWith(
            () => _SurfaceRecents(const <String>[]),
          ),
        ],
        child: surfaceHarness(
          MacosApplicationsSurface(
            searchFocusNode: focusNode,
            onDismiss: () {},
            onLaunch: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No applications found'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _SurfaceGrid extends HomeGridController {
  _SurfaceGrid(this.slots);

  final List<HomeGridItem?> slots;

  @override
  Future<HomeGridState> build() async => HomeGridState(slots: slots);

  @override
  void setLauncherActive(bool active) {}

  @override
  Future<void> refreshDesktopApps({String reason = 'manual'}) async {}
}

class _LoadingGrid extends HomeGridController {
  @override
  Future<HomeGridState> build() => Completer<HomeGridState>().future;
}

class _SurfaceRecents extends ApplicationRecentsController {
  _SurfaceRecents(this.entries);

  final List<String> entries;

  @override
  List<String> build() => entries;
}
