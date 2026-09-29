import 'dart:io';

import 'package:denial_dart_shell/src/config/startup_environment.dart';
import 'package:denial_dart_shell/src/launcher/controllers/application_recents_controller.dart';
import 'package:denial_dart_shell/src/launcher/controllers/home_grid_controller.dart';
import 'package:denial_dart_shell/src/launcher/models/desktop_app.dart';
import 'package:denial_dart_shell/src/launcher/models/home_grid_item.dart';
import 'package:denial_dart_shell/src/launcher/runtime_paths.dart';
import 'package:denial_dart_shell/src/macos/macos_application_roles.dart';
import 'package:denial_dart_shell/src/macos/macos_mime_associations.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/settings/settings_controller.dart';
import 'package:denial_dart_shell/src/settings/settings_store.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/state/shell_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

DesktopApp roleApp(
  String id, {
  String name = 'Role App',
  List<String> categories = const <String>[],
}) => DesktopApp(
  id: id,
  name: name,
  exec: 'role-app',
  desktopPath: '/usr/share/applications/$id',
  categories: categories,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveMacosApplicationRole', () {
    final apps = <DesktopApp>[
      roleApp(
        'files.desktop',
        name: 'Files',
        categories: const <String>['FileManager'],
      ),
      roleApp(
        'alpha-browser.desktop',
        name: 'Alpha Browser',
        categories: const <String>['WebBrowser'],
      ),
      roleApp(
        'beta-browser.desktop',
        name: 'Beta Browser',
        categories: const <String>['WebBrowser'],
      ),
      roleApp(
        'terminal.desktop',
        name: 'Terminal',
        categories: const <String>['TerminalEmulator'],
      ),
    ];

    MacosMimeAssociations associationsWithDefault(
      String mimeType,
      String desktopId,
    ) {
      return parseMacosMimeappsLists(<String>[
        '[Default Applications]\n$mimeType=$desktopId\n',
      ]);
    }

    test('explicit override beats freedesktop default and category', () {
      final resolution = resolveMacosApplicationRole(
        role: MacosApplicationRole.webBrowser,
        apps: apps,
        overrides: const <String, String>{'webBrowser': 'beta-browser.desktop'},
        associations: associationsWithDefault(
          'x-scheme-handler/http',
          'alpha-browser.desktop',
        ),
      );
      expect(resolution.app?.id, 'beta-browser.desktop');
      expect(resolution.source, MacosRoleResolutionSource.override);
      expect(resolution.staleOverrideId, isNull);
      expect(resolution.resolved, isTrue);
    });

    test('freedesktop default beats the category fallback', () {
      final resolution = resolveMacosApplicationRole(
        role: MacosApplicationRole.webBrowser,
        apps: apps,
        associations: associationsWithDefault(
          'text/html',
          'beta-browser.desktop',
        ),
      );
      expect(resolution.app?.id, 'beta-browser.desktop');
      expect(resolution.source, MacosRoleResolutionSource.freedesktopDefault);
    });

    test('category fallback selects the first catalogue match', () {
      final resolution = resolveMacosApplicationRole(
        role: MacosApplicationRole.webBrowser,
        apps: apps,
      );
      expect(resolution.app?.id, 'alpha-browser.desktop');
      expect(resolution.source, MacosRoleResolutionSource.category);
    });

    test('category matching is case-insensitive', () {
      final resolution = resolveMacosApplicationRole(
        role: MacosApplicationRole.terminal,
        apps: <DesktopApp>[
          roleApp(
            'console.desktop',
            categories: const <String>['terminalemulator'],
          ),
        ],
      );
      expect(resolution.app?.id, 'console.desktop');
      expect(resolution.source, MacosRoleResolutionSource.category);
    });

    test('missing handler reports a visible unresolved state', () {
      final resolution = resolveMacosApplicationRole(
        role: MacosApplicationRole.mail,
        apps: apps,
      );
      expect(resolution.resolved, isFalse);
      expect(resolution.app, isNull);
      expect(resolution.source, isNull);
      expect(resolution.staleOverrideId, isNull);
    });

    test('uninstalled override falls through and stays visible', () {
      final resolution = resolveMacosApplicationRole(
        role: MacosApplicationRole.fileManager,
        apps: apps,
        overrides: const <String, String>{'fileManager': 'gone.desktop'},
      );
      expect(resolution.app?.id, 'files.desktop');
      expect(resolution.source, MacosRoleResolutionSource.category);
      expect(resolution.staleOverrideId, 'gone.desktop');
    });

    test('freedesktop candidates are tried until one is installed', () {
      final resolution = resolveMacosApplicationRole(
        role: MacosApplicationRole.webBrowser,
        apps: apps,
        associations: parseMacosMimeappsLists(<String>[
          '[Default Applications]\n'
              'x-scheme-handler/http=absent.desktop;beta-browser.desktop\n',
        ]),
      );
      expect(resolution.app?.id, 'beta-browser.desktop');
      expect(resolution.source, MacosRoleResolutionSource.freedesktopDefault);
    });
  });

  group('parseMacosMimeappsLists', () {
    test('the highest-precedence file wins a default', () {
      final associations = parseMacosMimeappsLists(<String>[
        '[Default Applications]\ntext/html=first.desktop\n',
        '[Default Applications]\ntext/html=second.desktop\n',
      ]);
      expect(associations.candidatesFor('text/html'), <String>[
        'first.desktop',
      ]);
    });

    test('added associations accumulate and removed ones are excluded', () {
      final associations = parseMacosMimeappsLists(<String>[
        '[Added Associations]\nimage/png=one.desktop;two.desktop\n'
            '[Removed Associations]\nimage/png=two.desktop\n',
        '[Added Associations]\nimage/png=three.desktop;one.desktop\n',
      ]);
      expect(associations.candidatesFor('image/png'), <String>[
        'one.desktop',
        'three.desktop',
      ]);
    });

    test('defaults rank ahead of added associations', () {
      final associations = parseMacosMimeappsLists(<String>[
        '[Added Associations]\nimage/png=added.desktop\n'
            '[Default Applications]\nimage/png=default.desktop\n',
      ]);
      expect(associations.candidatesFor('image/png'), <String>[
        'default.desktop',
        'added.desktop',
      ]);
    });

    test('MIME types are normalized and unknown sections are ignored', () {
      final associations = parseMacosMimeappsLists(<String>[
        '# comment\n[Default Applications]\nText/HTML=app.desktop\n'
            '[Other]\nvideo/mp4=ignored.desktop\n',
      ]);
      expect(associations.candidatesFor('text/html'), <String>['app.desktop']);
      expect(associations.candidatesFor('video/mp4'), isEmpty);
    });
  });

  group('macosMimeappsListFiles', () {
    test('follows the freedesktop precedence order', () {
      final paths = RuntimePaths(
        environment: const <String, String>{
          'HOME': '/home/user',
          'XDG_CONFIG_HOME': '/cfg',
          'XDG_DATA_HOME': '/data',
          'XDG_DATA_DIRS': '/sys1:/sys2',
          'XDG_CURRENT_DESKTOP': 'Denial:GNOME',
        },
      );
      expect(
        macosMimeappsListFiles(paths).map((file) => file.path).toList(),
        <String>[
          '/cfg/denial-mimeapps.list',
          '/cfg/gnome-mimeapps.list',
          '/cfg/mimeapps.list',
          '/data/applications/denial-mimeapps.list',
          '/data/applications/gnome-mimeapps.list',
          '/data/applications/mimeapps.list',
          '/sys1/applications/denial-mimeapps.list',
          '/sys1/applications/gnome-mimeapps.list',
          '/sys1/applications/mimeapps.list',
          '/sys2/applications/denial-mimeapps.list',
          '/sys2/applications/gnome-mimeapps.list',
          '/sys2/applications/mimeapps.list',
        ],
      );
    });

    test('defaults the desktop prefix to Denial', () {
      final paths = RuntimePaths(
        environment: const <String, String>{'HOME': '/home/user'},
      );
      expect(
        macosMimeappsListFiles(paths).first.path,
        '/home/user/.config/denial-mimeapps.list',
      );
    });
  });

  group('loadMacosMimeAssociations', () {
    test('reads every reachable file in precedence order', () async {
      final root = Directory.systemTemp.createTempSync('denial-mimeapps');
      addTearDown(() => root.deleteSync(recursive: true));
      final config = Directory('${root.path}/config')..createSync();
      final data = Directory('${root.path}/data/applications')
        ..createSync(recursive: true);
      File('${config.path}/mimeapps.list').writeAsStringSync(
        '[Default Applications]\nx-scheme-handler/mailto=user.desktop\n',
      );
      File('${data.path}/mimeapps.list').writeAsStringSync(
        '[Default Applications]\nx-scheme-handler/mailto=system.desktop\n'
        '[Added Associations]\ninode/directory=files.desktop\n',
      );
      final paths = RuntimePaths(
        environment: <String, String>{
          'HOME': root.path,
          'XDG_CONFIG_HOME': config.path,
          'XDG_DATA_HOME': '${root.path}/data',
          'XDG_DATA_DIRS': '${root.path}/empty',
        },
      );
      final associations = await loadMacosMimeAssociations(paths);
      expect(associations.candidatesFor('x-scheme-handler/mailto'), <String>[
        'user.desktop',
      ]);
      expect(associations.candidatesFor('inode/directory'), <String>[
        'files.desktop',
      ]);
    });
  });

  group('ShellApplicationRoleSettings', () {
    test('round-trips through the settings document JSON', () {
      final settings = ShellSettings(
        applicationRoles: const ShellApplicationRoleSettings(
          overrides: <String, String>{'fileManager': 'files.desktop'},
        ).withOverride('webBrowser', 'browser.desktop'),
      );
      final decoded = ShellSettings.fromJson(settings.toJson());
      expect(decoded.applicationRoles.overrides, <String, String>{
        'fileManager': 'files.desktop',
        'webBrowser': 'browser.desktop',
      });
      expect(decoded, settings);
    });

    test('rejects malformed roles and desktop-file IDs', () {
      const settings = ShellApplicationRoleSettings();
      expect(
        () => settings.withOverride('bad role', 'a.desktop'),
        throwsArgumentError,
      );
      expect(
        () => settings.withOverride('webBrowser', 'not-a-desktop-id'),
        throwsArgumentError,
      );
      final decoded =
          ShellApplicationRoleSettings.fromJson(const <String, Object?>{
            'webBrowser': 'browser.desktop',
            'bad role': 'a.desktop',
            'media': 'no extension',
            'empty': '',
          });
      expect(decoded.overrides, <String, String>{
        'webBrowser': 'browser.desktop',
      });
    });
  });

  group('role providers', () {
    late Directory root;
    late Map<String, String> environment;
    late _MemorySettingsStore store;

    ProviderContainer roleContainer(List<DesktopApp> apps) {
      return ProviderContainer(
        overrides: [
          startupEnvironmentProvider.overrideWithValue(
            StartupEnvironment(environment),
          ),
          denialBridgeProvider.overrideWithValue(_RoleBridge()),
          settingsStoreProvider.overrideWithValue(store),
          shellControllerProvider.overrideWith(() => _RoleShell()),
          applicationRecentsProvider.overrideWith(() => _RoleRecents()),
          homeGridControllerProvider.overrideWith(() => _RolesGrid(apps)),
        ],
      );
    }

    setUp(() {
      root = Directory.systemTemp.createTempSync('denial-roles');
      environment = <String, String>{
        'HOME': root.path,
        'XDG_CONFIG_HOME': '${root.path}/config',
        'XDG_DATA_HOME': '${root.path}/data',
        'XDG_DATA_DIRS': '${root.path}/system',
        'XDG_CURRENT_DESKTOP': 'Denial',
      };
      store = _MemorySettingsStore();
    });

    tearDown(() {
      root.deleteSync(recursive: true);
    });

    test('resolution follows overrides, freedesktop, then category', () async {
      Directory(environment['XDG_CONFIG_HOME']!).createSync(recursive: true);
      File('${environment['XDG_CONFIG_HOME']}/mimeapps.list').writeAsStringSync(
        '[Default Applications]\n'
        'x-scheme-handler/http=mime-browser.desktop\n',
      );
      final apps = <DesktopApp>[
        roleApp(
          'mime-browser.desktop',
          categories: const <String>['WebBrowser'],
        ),
        roleApp(
          'category-browser.desktop',
          categories: const <String>['WebBrowser'],
        ),
        roleApp(
          'override-browser.desktop',
          categories: const <String>['WebBrowser'],
        ),
      ];
      final container = roleContainer(apps);
      addTearDown(container.dispose);
      await _pump(container);

      Map<MacosApplicationRole, MacosRoleResolution> resolutions() {
        return container.read(macosRoleResolverProvider).value!;
      }

      var browser = resolutions()[MacosApplicationRole.webBrowser]!;
      expect(browser.app?.id, 'mime-browser.desktop');
      expect(browser.source, MacosRoleResolutionSource.freedesktopDefault);

      container
          .read(shellSettingsProvider.notifier)
          .setApplicationRoleOverride('webBrowser', 'override-browser.desktop');
      browser = resolutions()[MacosApplicationRole.webBrowser]!;
      expect(browser.app?.id, 'override-browser.desktop');
      expect(browser.source, MacosRoleResolutionSource.override);

      container
          .read(shellSettingsProvider.notifier)
          .removeApplicationRoleOverride('webBrowser');
      browser = resolutions()[MacosApplicationRole.webBrowser]!;
      expect(browser.app?.id, 'mime-browser.desktop');
      expect(browser.source, MacosRoleResolutionSource.freedesktopDefault);
    });

    test('unresolved roles stay visible at the provider layer', () async {
      final container = roleContainer(<DesktopApp>[]);
      addTearDown(container.dispose);
      await _pump(container);
      final resolution = container
          .read(macosRoleResolutionProvider(MacosApplicationRole.terminal))
          .value;
      expect(resolution?.resolved, isFalse);
      expect(resolution?.source, isNull);
    });

    test('overrides persist through the shared settings store', () async {
      final container = roleContainer(<DesktopApp>[
        roleApp('files.desktop', categories: const <String>['FileManager']),
      ]);
      addTearDown(container.dispose);
      await _pump(container);

      final settings = container.read(shellSettingsProvider.notifier);
      settings.setApplicationRoleOverride('fileManager', 'files.desktop');
      await settings.flush();
      expect(store.writes, isNotEmpty);
      expect(
        store.writes.last.applicationRoles.overrides,
        const <String, String>{'fileManager': 'files.desktop'},
      );

      settings.setApplicationRoleOverride('fileManager', null);
      await settings.flush();
      expect(store.writes.last.applicationRoles.overrides, isEmpty);
    });

    test(
      'launchMacosApplicationRole launches the resolved desktop entry',
      () async {
        final bridge = _RoleBridge();
        final container = ProviderContainer(
          overrides: [
            startupEnvironmentProvider.overrideWithValue(
              StartupEnvironment(environment),
            ),
            denialBridgeProvider.overrideWithValue(bridge),
            settingsStoreProvider.overrideWithValue(store),
            shellControllerProvider.overrideWith(() => _RoleShell()),
            applicationRecentsProvider.overrideWith(() => _RoleRecents()),
            homeGridControllerProvider.overrideWith(
              () => _RolesGrid(<DesktopApp>[
                roleApp(
                  'files.desktop',
                  categories: const <String>['FileManager'],
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);
        await _pump(container);

        final result = await container.read(
          _roleLaunchProvider(MacosApplicationRole.fileManager).future,
        );
        expect(result, MacosRoleLaunchResult.launched);
        expect(bridge.launchedDesktopIds, <String>['files.desktop']);

        final missing = await container.read(
          _roleLaunchProvider(MacosApplicationRole.webBrowser).future,
        );
        expect(missing, MacosRoleLaunchResult.unresolved);
        expect(bridge.launchedDesktopIds, <String>['files.desktop']);
      },
    );
  });
}

Future<void> _pump(ProviderContainer container) async {
  await container.read(homeGridControllerProvider.future);
  await container.read(macosMimeAssociationsProvider.future);
  // Let the settings controller accept its authoritative snapshot.
  await Future<void>.delayed(Duration.zero);
}

final _roleLaunchProvider =
    FutureProvider.family<MacosRoleLaunchResult, MacosApplicationRole>(
      (ref, role) => launchMacosApplicationRole(ref, role),
    );

class _MemorySettingsStore implements SettingsStore {
  final List<ShellSettings> writes = <ShellSettings>[];

  @override
  Future<ShellSettings?> read() async => const ShellSettings();

  @override
  Future<void> write(ShellSettings settings) async {
    writes.add(settings);
  }
}

class _RoleBridge extends DenialBridge {
  final List<String> launchedDesktopIds = <String>[];

  @override
  bool launchDesktopApplication(
    String desktopFileId,
    List<String> argv, {
    int? launchRequestId,
  }) {
    launchedDesktopIds.add(desktopFileId);
    return true;
  }
}

class _RoleShell extends ShellController {
  @override
  ShellState build() => ShellState.initial();

  @override
  void registerLegacyTextInputAppIds(Iterable<String> appIds) {}
}

class _RoleRecents extends ApplicationRecentsController {
  @override
  List<String> build() => const <String>[];

  @override
  void record(String entryId) {}
}

class _RolesGrid extends HomeGridController {
  _RolesGrid(this.apps);

  final List<DesktopApp> apps;

  @override
  Future<HomeGridState> build() async {
    return HomeGridState(
      slots: <HomeGridItem?>[for (final app in apps) HomeGridItem.app(app)],
    );
  }
}
