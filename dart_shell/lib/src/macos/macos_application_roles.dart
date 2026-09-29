import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../desktop/desktop_workspace.dart';
import '../launcher/controllers/application_recents_controller.dart';
import '../launcher/controllers/home_grid_controller.dart';
import '../launcher/launcher_providers.dart';
import '../launcher/models/desktop_app.dart';
import '../launcher/models/home_grid_item.dart';
import '../settings/settings_application.dart';
import '../settings/settings_controller.dart';
import '../settings/widgets/settings_navigation.dart';
import '../state/shell_controller.dart';
import 'macos_mime_associations.dart';

/// Semantic default-application roles for the macOS shell.
///
/// Finder, Safari, Terminal, and similar names are visual references, not
/// bundled applications. Each role resolves to an installed Linux desktop
/// entry; no role depends on a distribution-specific executable name.
enum MacosApplicationRole {
  fileManager,
  webBrowser,
  terminal,
  mail,
  calendar,
  media,
}

extension MacosApplicationRoleSpec on MacosApplicationRole {
  /// Key under which explicit overrides persist in `ShellSettings`.
  String get settingsKey => name;

  /// Freedesktop MIME types consulted through `mimeapps.list`, in priority
  /// order. Freedesktop standardizes no association for terminal emulators,
  /// so [MacosApplicationRole.terminal] relies on the category fallback.
  List<String> get mimeTypes => switch (this) {
    MacosApplicationRole.fileManager => const <String>['inode/directory'],
    MacosApplicationRole.webBrowser => const <String>[
      'x-scheme-handler/http',
      'x-scheme-handler/https',
      'text/html',
    ],
    MacosApplicationRole.terminal => const <String>[],
    MacosApplicationRole.mail => const <String>['x-scheme-handler/mailto'],
    MacosApplicationRole.calendar => const <String>[
      'x-scheme-handler/webcal',
      'text/calendar',
    ],
    MacosApplicationRole.media => const <String>['video/mp4', 'audio/mpeg'],
  };

  /// Well-known desktop-entry categories tried as the last-resort fallback,
  /// in priority order. Matching is case-insensitive.
  List<String> get categories => switch (this) {
    MacosApplicationRole.fileManager => const <String>['FileManager'],
    MacosApplicationRole.webBrowser => const <String>['WebBrowser'],
    MacosApplicationRole.terminal => const <String>['TerminalEmulator'],
    MacosApplicationRole.mail => const <String>['Email'],
    MacosApplicationRole.calendar => const <String>['Calendar'],
    MacosApplicationRole.media => const <String>[
      'AudioVideo',
      'Video',
      'Audio',
      'Player',
      'Music',
      'Recorder',
      'TV',
    ],
  };
}

/// How a [MacosRoleResolution] produced its application.
enum MacosRoleResolutionSource {
  /// An explicit user override persisted in `ShellSettings`.
  override,

  /// A freedesktop `mimeapps.list` default or added association.
  freedesktopDefault,

  /// A desktop-entry category fallback within the installed catalogue.
  category,
}

/// The outcome of resolving one [MacosApplicationRole].
///
/// [app] is `null` when nothing on the system can serve the role. That
/// missing-handler state is deliberate: callers must surface it visibly and
/// offer the Settings override route rather than silently no-op.
class MacosRoleResolution {
  const MacosRoleResolution({
    required this.role,
    required this.app,
    required this.source,
    this.staleOverrideId,
  });

  const MacosRoleResolution.unresolved(this.role, {this.staleOverrideId})
    : app = null,
      source = null;

  final MacosApplicationRole role;
  final DesktopApp? app;
  final MacosRoleResolutionSource? source;

  /// Set when a persisted override names a desktop entry which is no longer
  /// installed. Resolution falls through to the next source so the role
  /// keeps working, and Settings can flag the stale choice.
  final String? staleOverrideId;

  bool get resolved => app != null;
}

/// Resolves [role] against the installed [apps] catalogue.
///
/// Order: explicit [overrides] entry, then `mimeapps.list`
/// [associations] for the role MIME types, then the first catalogue entry
/// declaring one of the role categories. A set-but-missing override never
/// blocks lower sources; it is reported through
/// [MacosRoleResolution.staleOverrideId] instead.
MacosRoleResolution resolveMacosApplicationRole({
  required MacosApplicationRole role,
  required List<DesktopApp> apps,
  Map<String, String> overrides = const <String, String>{},
  MacosMimeAssociations associations = MacosMimeAssociations.empty,
}) {
  final appsById = <String, DesktopApp>{for (final app in apps) app.id: app};

  final overrideId = overrides[role.settingsKey];
  final overridden = overrideId == null ? null : appsById[overrideId];
  if (overridden != null) {
    return MacosRoleResolution(
      role: role,
      app: overridden,
      source: MacosRoleResolutionSource.override,
    );
  }
  // A configured-but-uninstalled override stays visible through
  // [MacosRoleResolution.staleOverrideId] while resolution falls through.
  final staleOverrideId = overrideId;

  for (final mimeType in role.mimeTypes) {
    for (final id in associations.candidatesFor(mimeType)) {
      final app = appsById[id];
      if (app != null) {
        return MacosRoleResolution(
          role: role,
          app: app,
          source: MacosRoleResolutionSource.freedesktopDefault,
          staleOverrideId: staleOverrideId,
        );
      }
    }
  }

  for (final category in role.categories) {
    final wanted = category.toLowerCase();
    for (final app in apps) {
      final declared = app.categories.any(
        (candidate) => candidate.toLowerCase() == wanted,
      );
      if (declared) {
        return MacosRoleResolution(
          role: role,
          app: app,
          source: MacosRoleResolutionSource.category,
          staleOverrideId: staleOverrideId,
        );
      }
    }
  }

  return MacosRoleResolution.unresolved(role, staleOverrideId: staleOverrideId);
}

/// The installed desktop entries inside home-grid [slots], deduplicated by
/// [DesktopApp.id] and sorted by name then ID so role resolution picks a
/// deterministic catalogue order.
List<DesktopApp> macosRoleCatalogueApplications(List<HomeGridItem?>? slots) {
  final byId = <String, DesktopApp>{};
  for (final item in slots ?? const <HomeGridItem?>[]) {
    final app = item?.app;
    if (app != null) {
      byId[app.id] = app;
    }
  }
  final apps = byId.values.toList(growable: false)
    ..sort((left, right) {
      final byName = left.name.toLowerCase().compareTo(
        right.name.toLowerCase(),
      );
      return byName != 0 ? byName : left.id.compareTo(right.id);
    });
  return List<DesktopApp>.unmodifiable(apps);
}

/// Resolves every role against one catalogue snapshot.
Map<MacosApplicationRole, MacosRoleResolution> resolveMacosApplicationRoles({
  required List<DesktopApp> apps,
  Map<String, String> overrides = const <String, String>{},
  MacosMimeAssociations associations = MacosMimeAssociations.empty,
}) {
  return Map<MacosApplicationRole, MacosRoleResolution>.unmodifiable(
    <MacosApplicationRole, MacosRoleResolution>{
      for (final role in MacosApplicationRole.values)
        role: resolveMacosApplicationRole(
          role: role,
          apps: apps,
          overrides: overrides,
          associations: associations,
        ),
    },
  );
}

/// Parsed `mimeapps.list` associations for the session.
///
/// Reloads when the XDG base directories change and, best effort, when a
/// `mimeapps.list` file is created or modified so `xdg-mime` changes take
/// effect without restarting the session.
final macosMimeAssociationsProvider = FutureProvider<MacosMimeAssociations>((
  ref,
) async {
  final paths = ref.watch(runtimePathsProvider);
  final subscriptions = <StreamSubscription<FileSystemEvent>>[];
  for (final directory in macosMimeappsWatchDirectories(paths)) {
    try {
      if (!directory.existsSync()) {
        continue;
      }
      subscriptions.add(
        directory.watch().listen((event) {
          if (event.path.endsWith('mimeapps.list')) {
            ref.invalidateSelf();
          }
        }, onError: (_) {}),
      );
    } on Object {
      // Watching is best effort; the initial load still applies.
    }
  }
  ref.onDispose(() {
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
  });
  return loadMacosMimeAssociations(paths);
});

/// Resolves every macOS application role from the shared desktop-entry
/// catalogue, `mimeapps.list` associations, and persisted user overrides.
///
/// Watching this provider re-resolves live when the catalogue refreshes or
/// when a role override is written — including a write committed by the
/// standalone Settings process through the shared settings document.
final macosRoleResolverProvider =
    Provider<AsyncValue<Map<MacosApplicationRole, MacosRoleResolution>>>((ref) {
      final grid = ref.watch(homeGridControllerProvider);
      final associations = ref.watch(macosMimeAssociationsProvider);
      final overrides = ref.watch(
        shellSettingsProvider.select(
          (settings) => settings.applicationRoles.overrides,
        ),
      );
      return grid.when(
        data: (state) => AsyncData(
          resolveMacosApplicationRoles(
            apps: macosRoleCatalogueApplications(state.slots),
            overrides: overrides,
            associations:
                associations.asData?.value ?? MacosMimeAssociations.empty,
          ),
        ),
        loading: () => const AsyncLoading(),
        error: AsyncError.new,
      );
    });

/// Resolution for a single [MacosApplicationRole].
final macosRoleResolutionProvider =
    Provider.family<AsyncValue<MacosRoleResolution>, MacosApplicationRole>((
      ref,
      role,
    ) {
      return ref
          .watch(macosRoleResolverProvider)
          .whenData(
            (resolutions) =>
                resolutions[role] ?? MacosRoleResolution.unresolved(role),
          );
    });

/// Result of [launchMacosApplicationRole].
enum MacosRoleLaunchResult {
  /// The resolved application was launched.
  launched,

  /// An already-open window of the resolved application was focused.
  focusedExisting,

  /// No application can serve the role; the caller must surface the missing
  /// handler and offer the Settings override route.
  unresolved,

  /// The role resolved, but the compositor rejected the launch request.
  launchRejected,
}

/// Launches (or focuses) the application serving [role].
///
/// Mirrors the Apps-surface launch semantics: records the launch in recents,
/// registers legacy text-input identities for terminal emulators, focuses a
/// matching open window instead of relaunching, and otherwise launches the
/// resolved desktop entry through `appLauncherProvider`.
Future<MacosRoleLaunchResult> launchMacosApplicationRole(
  Ref ref,
  MacosApplicationRole role,
) async {
  final resolution = ref.read(macosRoleResolutionProvider(role)).asData?.value;
  final app = resolution?.app;
  if (app == null) {
    return MacosRoleLaunchResult.unresolved;
  }
  ref
      .read(applicationRecentsProvider.notifier)
      .record(desktopApplicationRecentId(app.id));
  final launcher = ref.read(appLauncherProvider);
  final shell = ref.read(shellControllerProvider.notifier);
  final expectedIds = launcher.expectedWindowAppIds(app);
  if (launcher.usesLegacyTextInput(app)) {
    shell.registerLegacyTextInputAppIds(expectedIds);
  }
  final existing = launcher.findOpenWindow(
    app,
    ref.read(shellControllerProvider).openAppWindows,
  );
  if (existing != null) {
    ref.read(desktopWorkspaceProvider.notifier).activate(existing.objectId);
    shell.focusWindow(existing);
    return MacosRoleLaunchResult.focusedExisting;
  }
  final launched = await launcher.launch(app);
  return launched
      ? MacosRoleLaunchResult.launched
      : MacosRoleLaunchResult.launchRejected;
}

/// Routes the standalone Settings application to the default-applications
/// page. An already-open Settings window is activated first; the launch
/// still carries `--page=defaultApplications` so the running instance's
/// activation channel navigates to the page. This is the visible affordance
/// for unresolved roles.
void openMacosDefaultApplicationsSettings(Ref ref) {
  for (final window in ref.read(shellControllerProvider).openAppWindows) {
    if (isDenialSettingsApplicationId(window.appId)) {
      ref.read(desktopWorkspaceProvider.notifier).activate(window.objectId);
      ref.read(shellControllerProvider.notifier).focusWindow(window);
      break;
    }
  }
  final configured = ref
      .read(startupEnvironmentProvider)['DENIAL_SETTINGS_BINARY']
      ?.trim();
  final executable = configured == null || configured.isEmpty
      ? 'denial-settings'
      : configured;
  ref.read(denialBridgeProvider).launchApplication(<String>[
    executable,
    '--page=${SettingsPageId.defaultApplications.name}',
  ]);
}
