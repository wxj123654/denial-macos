import 'dart:async';

import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:path/path.dart' as p;

import '../../l10n/generated/app_localizations.dart';
import '../config/startup_environment.dart';
import '../input/shell_interaction_registry.dart';
import '../localization/denial_localizations.dart';
import '../models/clipboard_history.dart';
import '../platform/denial_bridge.dart';
import '../settings/widgets/settings_shortcut_presentation.dart';
import '../state/clipboard_tray.dart';
import '../state/shell_controller.dart';
import '../widgets/shell_cursor.dart';
import 'macos_spotlight_sources.dart';

/// Key for the macOS Apps surface inserted above the desktop chrome.
const macosApplicationsSurfaceKey = ValueKey<String>(
  'macos-applications-surface',
);

/// Key for the Apps surface search field.
const macosApplicationsSearchFieldKey = ValueKey<String>(
  'macos-applications-search-field',
);

/// Key for the Spotlight mode button of [mode].
ValueKey<String> macosSpotlightModeKey(MacosSpotlightMode mode) =>
    ValueKey<String>('macos-spotlight-mode-${mode.name}');

/// Key for the Spotlight category filter chip; `null` selects the All chip.
ValueKey<String> macosSpotlightFilterKey(String category) =>
    ValueKey<String>('macos-spotlight-filter-$category');

/// Key for the grid/list view toggle on the Spotlight surface.
const macosSpotlightViewToggleKey = ValueKey<String>(
  'macos-spotlight-view-toggle',
);

/// Key for the locked Clipboard mode placeholder.
const macosSpotlightClipboardLockedKey = ValueKey<String>(
  'macos-spotlight-clipboard-locked',
);

/// Collects the installed desktop applications from the shared home-grid
/// slots, deduplicated by [DesktopApp.id] and sorted by case-insensitive name
/// then ID so the catalogue order is deterministic.
List<DesktopApp> macosInstalledApplications(List<HomeGridItem?>? slots) {
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

/// Filters [apps] by a case-insensitive substring match over each app's
/// [DesktopApp.searchableText] (name, ID, categories, and keywords).
List<DesktopApp> filterMacosApplications(List<DesktopApp> apps, String query) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) {
    return apps;
  }
  return List<DesktopApp>.unmodifiable(
    apps.where((app) => app.searchableText.contains(normalized)),
  );
}

/// Resolves recent entries into installed applications, preserving the exact
/// recents order. Only `desktop:` recent IDs participate; stale and duplicate
/// IDs are skipped. At most [limit] applications are returned.
List<DesktopApp> suggestMacosApplications(
  List<DesktopApp> apps,
  List<String> recentEntryIds, {
  int limit = 4,
}) {
  if (limit <= 0 || apps.isEmpty || recentEntryIds.isEmpty) {
    return const <DesktopApp>[];
  }
  final byId = <String, DesktopApp>{for (final app in apps) app.id: app};
  final seen = <String>{};
  final suggested = <DesktopApp>[];
  for (final entryId in recentEntryIds) {
    if (!entryId.startsWith('desktop:')) {
      continue;
    }
    final id = entryId.substring('desktop:'.length);
    if (!seen.add(id)) {
      continue;
    }
    final app = byId[id];
    if (app == null) {
      continue;
    }
    suggested.add(app);
    if (suggested.length >= limit) {
      break;
    }
  }
  return List<DesktopApp>.unmodifiable(suggested);
}

class _MacosSpotlightTarget {
  const _MacosSpotlightTarget({
    required this.result,
    required this.selectionId,
    required this.row,
    required this.column,
    required this.scrollTop,
    required this.scrollExtent,
  });

  final MacosSpotlightResult result;
  final String selectionId;
  final int row;
  final int column;
  final double scrollTop;
  final double scrollExtent;
}

/// Centered, bounded macOS-style Spotlight panel over a dismissible barrier.
///
/// Applications mode keeps the Phase 1 semantics: the catalogue is backed by
/// [homeGridControllerProvider] and recent launches by
/// [applicationRecentsProvider]. Files, Actions, and Clipboard history are
/// additional [MacosSpotlightMode]s backed by bounded, cancellable sources —
/// see `macos_spotlight_sources.dart`. Escape and barrier taps dismiss through
/// [onDismiss]; launching reports the chosen app through [onLaunch] exactly
/// once.
class MacosApplicationsSurface extends ConsumerStatefulWidget {
  const MacosApplicationsSurface({
    super.key,
    required this.searchFocusNode,
    required this.onDismiss,
    required this.onLaunch,
    this.initialMode = MacosSpotlightMode.applications,
    this.onOpenFile,
    this.onOpenSettings,
  });

  final FocusNode searchFocusNode;
  final VoidCallback onDismiss;
  final ValueChanged<DesktopApp> onLaunch;

  /// Mode selected when the surface first appears.
  final MacosSpotlightMode initialMode;

  /// Opens a file result's absolute path. Defaults to launching `xdg-open`
  /// through [DenialBridge.launchApplication] so Phase 3 Finder roles can
  /// replace it without touching the surface.
  final ValueChanged<String>? onOpenFile;

  /// Opens System Settings. Defaults to launching the configured
  /// `DENIAL_SETTINGS_BINARY` (falling back to `denial-settings`) without the
  /// scene's focus-an-existing-window pass.
  final VoidCallback? onOpenSettings;

  @override
  ConsumerState<MacosApplicationsSurface> createState() =>
      _MacosApplicationsSurfaceState();
}

class _MacosApplicationsSurfaceState
    extends ConsumerState<MacosApplicationsSurface> {
  static const double _tileExtent = 108;
  static const double _suggestedTileExtent = 92;
  static const double _tileSpacing = 8;
  static const double _listRowExtent = 44;
  static const Duration _searchDebounce = Duration(milliseconds: 140);

  late final TextEditingController _searchController;
  final ScrollController _scrollController = ScrollController();
  Timer? _fileSearchTimer;
  int _fileSearchSerial = 0;
  List<MacosSpotlightFileResult> _fileResults =
      const <MacosSpotlightFileResult>[];
  bool _filesLoading = false;
  late MacosSpotlightMode _mode;
  final Map<MacosSpotlightMode, Object> _categories =
      <MacosSpotlightMode, Object>{};
  String _lastSearchText = '';
  String? _selectedTargetId;
  List<HomeGridItem?>? _cachedSlots;
  List<DesktopApp>? _cachedInstalled;
  List<_MacosSpotlightTarget> _visibleTargets = const <_MacosSpotlightTarget>[];

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _searchController = TextEditingController()
      ..addListener(_handleQueryChanged);
    if (_mode == MacosSpotlightMode.files) {
      _runFileSearch();
    }
  }

  @override
  void dispose() {
    _fileSearchSerial += 1;
    _fileSearchTimer?.cancel();
    _searchController
      ..removeListener(_handleQueryChanged)
      ..dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleQueryChanged() {
    final searchText = _searchController.text;
    if (searchText == _lastSearchText) {
      return;
    }
    _lastSearchText = searchText;
    setState(() => _selectedTargetId = null);
    _resetScroll();
    if (_mode == MacosSpotlightMode.files) {
      _scheduleFileSearch();
    }
  }

  void _clearSearch() {
    _searchController.clear();
    widget.searchFocusNode.requestFocus();
  }

  void _selectMode(MacosSpotlightMode mode) {
    if (_mode == mode) {
      return;
    }
    setState(() {
      _mode = mode;
      _selectedTargetId = null;
    });
    _resetScroll();
    // Stale file results never survive a mode change; a new query starts
    // immediately so the Files pane is responsive without typing.
    _fileSearchSerial += 1;
    if (mode == MacosSpotlightMode.files) {
      _runFileSearch();
    } else {
      _filesLoading = false;
    }
  }

  Object? _selectedCategory(MacosSpotlightMode mode) => _categories[mode];

  void _selectCategory(MacosSpotlightMode mode, Object? category) {
    if (_selectedCategory(mode) == category) {
      return;
    }
    setState(() {
      if (category == null) {
        _categories.remove(mode);
      } else {
        _categories[mode] = category;
      }
      _selectedTargetId = null;
    });
    _resetScroll();
    if (mode == MacosSpotlightMode.files) {
      _runFileSearch();
    }
  }

  void _scheduleFileSearch() {
    _fileSearchTimer?.cancel();
    _fileSearchTimer = Timer(_searchDebounce, _runFileSearch);
  }

  /// Runs the bounded Files-mode query, dropping stale responses by serial.
  void _runFileSearch() {
    _fileSearchTimer?.cancel();
    _fileSearchTimer = null;
    final serial = ++_fileSearchSerial;
    final query = _searchController.text;
    final category =
        _selectedCategory(MacosSpotlightMode.files)
            as MacosSpotlightFileCategory?;
    if (!_filesLoading) {
      setState(() => _filesLoading = true);
    }
    unawaited(
      ref
          .read(macosSpotlightFileSearchProvider)
          .search(
            query,
            category: category,
            isCancelled: () => !mounted || serial != _fileSearchSerial,
          )
          .then((results) {
            if (!mounted || serial != _fileSearchSerial) {
              return;
            }
            setState(() {
              _fileResults = results;
              _filesLoading = false;
            });
          }),
    );
  }

  List<DesktopApp> _resolveInstalled(List<HomeGridItem?>? slots) {
    final cached = _cachedInstalled;
    if (cached != null && identical(slots, _cachedSlots)) {
      return cached;
    }
    final resolved = macosInstalledApplications(slots);
    _cachedSlots = slots;
    _cachedInstalled = resolved;
    return resolved;
  }

  String _selectionId(MacosSpotlightResult result) =>
      '${_mode.name}:${result.resultId}';

  int _selectedIndexFor(List<_MacosSpotlightTarget> targets) {
    if (targets.isEmpty) {
      return -1;
    }
    final selectedTargetId = _selectedTargetId;
    if (selectedTargetId == null) {
      return 0;
    }
    final index = targets.indexWhere(
      (target) => target.selectionId == selectedTargetId,
    );
    return index < 0 ? 0 : index;
  }

  void _selectIndex(List<_MacosSpotlightTarget> targets, int index) {
    if (targets.isEmpty) {
      return;
    }
    final selected = targets[index];
    setState(() => _selectedTargetId = selected.selectionId);
    _revealSelected(selected);
  }

  void _moveSelection(List<_MacosSpotlightTarget> targets, int delta) {
    if (targets.isEmpty) {
      return;
    }
    _selectIndex(
      targets,
      (_selectedIndexFor(targets) + delta) % targets.length,
    );
  }

  void _moveSelectionVertically(
    List<_MacosSpotlightTarget> targets,
    int direction,
  ) {
    if (targets.isEmpty) {
      return;
    }
    final current = targets[_selectedIndexFor(targets)];
    final rowCount = targets.last.row + 1;
    final targetRow = (current.row + direction) % rowCount;
    final rowTargets = targets
        .where((target) => target.row == targetRow)
        .toList(growable: false);
    final targetColumn = current.column.clamp(0, rowTargets.length - 1).toInt();
    _selectIndex(targets, targets.indexOf(rowTargets[targetColumn]));
  }

  void _activateSelected() {
    final targets = _visibleTargets;
    final selectedIndex = _selectedIndexFor(targets);
    if (selectedIndex >= 0) {
      _activateResult(targets[selectedIndex].result);
    }
  }

  void _activateResult(MacosSpotlightResult result) {
    switch (result) {
      case MacosSpotlightApplicationResult(:final app):
        widget.onLaunch(app);
      case MacosSpotlightFileResult(:final path):
        _openFile(path);
      case MacosSpotlightActionResult(:final action):
        _runAction(action);
      case MacosSpotlightClipboardResult(:final entry):
        unawaited(_activateClipboard(entry));
    }
  }

  void _openFile(String path) {
    final onOpenFile = widget.onOpenFile;
    if (onOpenFile != null) {
      onOpenFile(path);
    } else {
      ref.read(denialBridgeProvider).launchApplication(<String>[
        'xdg-open',
        path,
      ]);
    }
    widget.onDismiss();
  }

  /// Runs a Spotlight action, preferring the scene callbacks where they exist
  /// and falling back to the shared shell providers otherwise.
  void _runAction(MacosSpotlightAction action) {
    switch (action) {
      case MacosSpotlightAction.openSettings:
        final onOpenSettings = widget.onOpenSettings;
        if (onOpenSettings != null) {
          onOpenSettings();
        } else {
          _launchSettingsFallback();
        }
      case MacosSpotlightAction.openClipboard:
        ref.read(clipboardTrayProvider.notifier).open();
      case MacosSpotlightAction.captureRegion:
        ref.read(denialBridgeProvider).takeScreenshot();
      case MacosSpotlightAction.windowSwitcher:
        ref.read(shellControllerProvider.notifier).switchAdjacentWindow(1);
      case MacosSpotlightAction.lockScreen:
        ref.read(shellControllerProvider.notifier).lock();
      case MacosSpotlightAction.logOut:
        ref.read(denialBridgeProvider).requestLogout();
    }
    widget.onDismiss();
  }

  void _launchSettingsFallback() {
    final configured = ref
        .read(startupEnvironmentProvider)['DENIAL_SETTINGS_BINARY']
        ?.trim();
    final executable = configured == null || configured.isEmpty
        ? 'denial-settings'
        : configured;
    ref.read(denialBridgeProvider).launchApplication(<String>[executable]);
  }

  Future<void> _activateClipboard(ClipboardHistoryEntry entry) async {
    // The compositor redacts locked snapshots before they reach Flutter, and
    // the shell lock state additionally gates interaction here.
    if (_clipboardLocked) {
      return;
    }
    final activated = await ref
        .read(clipboardHistoryProvider.notifier)
        .activate(entry.id);
    if (activated && mounted) {
      widget.onDismiss();
    }
  }

  bool get _clipboardLocked {
    if (_mode != MacosSpotlightMode.clipboard) {
      return false;
    }
    if (ref.read(shellControllerProvider).locked) {
      return true;
    }
    return ref.read(clipboardHistoryProvider).snapshot?.locked ?? false;
  }

  void _resetScroll() {
    if (!_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels != position.minScrollExtent) {
      position.jumpTo(position.minScrollExtent);
    }
  }

  void _revealSelected(_MacosSpotlightTarget target) {
    if (!_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    final itemTop = target.scrollTop;
    final itemBottom = itemTop + target.scrollExtent;
    final viewport = position.viewportDimension;
    final current = position.pixels;
    final double scrollTarget;
    if (itemBottom > current + viewport) {
      scrollTarget = itemBottom - viewport + _tileSpacing;
    } else if (itemTop < current) {
      scrollTarget = itemTop - _tileSpacing;
    } else {
      return;
    }
    position.jumpTo(
      scrollTarget
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble(),
    );
  }

  int _crossAxisCountFor(double width) {
    final count = (width / (_tileExtent + _tileSpacing)).ceil();
    return count < 1 ? 1 : count;
  }

  /// Lays out [suggested] and [results] for keyboard navigation and scroll
  /// reveal. Grid mode keeps the Phase 1 two-section layout (a compact
  /// suggested row above the catalogue grid); list mode gives every result
  /// its own row.
  List<_MacosSpotlightTarget> _resolveTargets(
    List<MacosSpotlightResult> suggested,
    List<MacosSpotlightResult> results,
    int columnCount,
    MacosSpotlightViewMode viewMode,
  ) {
    if (viewMode == MacosSpotlightViewMode.list) {
      return <_MacosSpotlightTarget>[
        for (
          var index = 0;
          index < suggested.length + results.length;
          index += 1
        )
          _MacosSpotlightTarget(
            result: index < suggested.length
                ? suggested[index]
                : results[index - suggested.length],
            selectionId: _selectionId(
              index < suggested.length
                  ? suggested[index]
                  : results[index - suggested.length],
            ),
            row: index,
            column: 0,
            scrollTop: index * (_listRowExtent + _tileSpacing),
            scrollExtent: _listRowExtent,
          ),
      ];
    }
    final catalogRowOffset = suggested.isEmpty ? 0 : 1;
    final catalogScrollOffset = suggested.isEmpty
        ? 0.0
        : _suggestedTileExtent + _tileSpacing * 2 + 1;
    return <_MacosSpotlightTarget>[
      for (var index = 0; index < suggested.length; index += 1)
        _MacosSpotlightTarget(
          result: suggested[index],
          selectionId: _selectionId(suggested[index]),
          row: 0,
          column: index,
          scrollTop: 0,
          scrollExtent: _suggestedTileExtent,
        ),
      for (var index = 0; index < results.length; index += 1)
        _MacosSpotlightTarget(
          result: results[index],
          selectionId: _selectionId(results[index]),
          row: catalogRowOffset + (index ~/ columnCount),
          column: index % columnCount,
          scrollTop:
              catalogScrollOffset +
              (index ~/ columnCount) * (_tileExtent + _tileSpacing),
          scrollExtent: _tileExtent,
        ),
    ];
  }

  String _modeLabel(MacosSpotlightMode mode, AppLocalizations l10n) {
    return switch (mode) {
      MacosSpotlightMode.applications => l10n.desktopApplicationsTitle,
      MacosSpotlightMode.files => l10n.macosSpotlightModeFiles,
      MacosSpotlightMode.actions => l10n.macosSpotlightModeActions,
      MacosSpotlightMode.clipboard => l10n.macosSpotlightModeClipboard,
    };
  }

  String _actionLabel(MacosSpotlightAction action, AppLocalizations l10n) {
    final shortcutAction = action.shortcutAction;
    if (shortcutAction != null) {
      return settingsShortcutActionLabel(context, shortcutAction);
    }
    return l10n.macosSpotlightActionLogOut;
  }

  IconData _actionIcon(MacosSpotlightAction action) {
    final shortcutAction = action.shortcutAction;
    if (shortcutAction != null) {
      return settingsShortcutActionIcon(shortcutAction);
    }
    return CupertinoIcons.square_arrow_right;
  }

  /// Per-mode category filter options: freedesktop categories in Applications
  /// mode, file-type buckets in Files mode, and content kinds in Clipboard
  /// mode. Actions mode has no filterable categories.
  List<Object> _categoriesFor(
    MacosSpotlightMode mode,
    List<DesktopApp> installed,
  ) {
    return switch (mode) {
      MacosSpotlightMode.applications => macosSpotlightApplicationCategories(
        installed,
      ),
      MacosSpotlightMode.files => MacosSpotlightFileCategory.values,
      MacosSpotlightMode.actions => const <Object>[],
      MacosSpotlightMode.clipboard => MacosSpotlightClipboardCategory.values,
    };
  }

  String _categoryLabel(Object category, AppLocalizations l10n) {
    return switch (category) {
      MacosSpotlightFileCategory.documents => l10n.macosSpotlightFileDocuments,
      MacosSpotlightFileCategory.images => l10n.macosSpotlightFileImages,
      MacosSpotlightFileCategory.audio => l10n.macosSpotlightFileAudio,
      MacosSpotlightFileCategory.video => l10n.macosSpotlightFileVideo,
      MacosSpotlightFileCategory.other => l10n.macosSpotlightFileOther,
      MacosSpotlightClipboardCategory.text => l10n.clipboardTypeText,
      MacosSpotlightClipboardCategory.image => l10n.clipboardTypeImage,
      MacosSpotlightClipboardCategory.files => l10n.clipboardTypeFiles,
      String() => category,
      _ => category.toString(),
    };
  }

  String _categoryKey(Object category) {
    return switch (category) {
      Enum() => category.name,
      String() => category,
      _ => category.toString(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final grid = ref.watch(homeGridControllerProvider);
    final slots = grid.asData?.value.slots;
    final appsLoading = slots == null && grid.isLoading;
    final recentEntryIds = ref.watch(applicationRecentsProvider);
    final installed = _resolveInstalled(slots);
    final viewMode = ref.watch(macosSpotlightViewModeProvider);
    // Clipboard history and the shell lock are only observed while the
    // Clipboard mode is visible, keeping provider traffic scoped to the mode.
    final clipboardState = _mode == MacosSpotlightMode.clipboard
        ? ref.watch(clipboardHistoryProvider)
        : null;
    final shellLocked = _mode == MacosSpotlightMode.clipboard
        ? ref.watch(shellControllerProvider.select((state) => state.locked))
        : false;
    final theme = MacosTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final l10n = context.l10n;
    final query = _searchController.text;

    // Resolve the mode's ordered catalogue results. Suggested applications
    // still lead the Applications mode, preserving the Phase 1 two-section
    // layout; their limit depends on the measured column count, so they are
    // resolved inside the LayoutBuilder below.
    final results = <MacosSpotlightResult>[];
    final clipboardLocked =
        _mode == MacosSpotlightMode.clipboard &&
        (shellLocked || (clipboardState?.snapshot?.locked ?? false));
    switch (_mode) {
      case MacosSpotlightMode.applications:
        for (final app in filterMacosApplicationsByCategory(
          filterMacosApplications(installed, query),
          _selectedCategory(_mode) as String?,
        )) {
          results.add(MacosSpotlightApplicationResult(app));
        }
      case MacosSpotlightMode.files:
        results.addAll(_fileResults);
      case MacosSpotlightMode.actions:
        results.addAll(
          filterMacosSpotlightActions(
            macosSpotlightActions,
            query,
            labelFor: (action) => _actionLabel(action, l10n),
          ).map(MacosSpotlightActionResult.new),
        );
      case MacosSpotlightMode.clipboard:
        if (!clipboardLocked) {
          results.addAll(
            filterMacosSpotlightClipboardEntries(
              clipboardState?.entries ?? const <ClipboardHistoryEntry>[],
              query,
              category:
                  _selectedCategory(_mode) as MacosSpotlightClipboardCategory?,
            ).map(MacosSpotlightClipboardResult.new),
          );
        }
    }

    return ShellInputRegion(
      debugLabel: 'macos-applications',
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      child: FocusTraversalGroup(
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape): widget.onDismiss,
            const SingleActivator(LogicalKeyboardKey.tab): () =>
                _moveSelection(_visibleTargets, 1),
            const SingleActivator(LogicalKeyboardKey.tab, shift: true): () =>
                _moveSelection(_visibleTargets, -1),
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                _moveSelectionVertically(_visibleTargets, 1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                _moveSelectionVertically(_visibleTargets, -1),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _moveSelection(_visibleTargets, 1),
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _moveSelection(_visibleTargets, -1),
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onDismiss,
                  child: ColoredBox(
                    color: (dark ? MacosColors.black : MacosColors.white)
                        .withValues(alpha: 0.3),
                  ),
                ),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 720,
                      maxHeight: 560,
                    ),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                      decoration: BoxDecoration(
                        color: (dark ? MacosColors.black : MacosColors.white)
                            .withValues(alpha: 0.86),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: (dark ? MacosColors.white : MacosColors.black)
                              .withValues(alpha: 0.12),
                        ),
                        boxShadow: const <BoxShadow>[
                          BoxShadow(
                            color: Color(0x33000000),
                            blurRadius: 32,
                            offset: Offset(0, 12),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          _MacosAppSearchField(
                            controller: _searchController,
                            focusNode: widget.searchFocusNode,
                            onClear: _clearSearch,
                            onSubmit: _activateSelected,
                            placeholder:
                                _mode == MacosSpotlightMode.applications
                                ? l10n.desktopSearchApplications
                                : l10n.macosSpotlightSearch,
                          ),
                          const SizedBox(height: 10),
                          _MacosSpotlightModeBar(
                            mode: _mode,
                            labelFor: (mode) => _modeLabel(mode, l10n),
                            viewMode: viewMode,
                            onSelectMode: _selectMode,
                            onToggleView: () => ref
                                .read(macosSpotlightViewModeProvider.notifier)
                                .setMode(
                                  viewMode == MacosSpotlightViewMode.grid
                                      ? MacosSpotlightViewMode.list
                                      : MacosSpotlightViewMode.grid,
                                ),
                          ),
                          _MacosSpotlightFilterRow(
                            categories: _categoriesFor(_mode, installed),
                            selected: _selectedCategory(_mode),
                            labelFor: (category) =>
                                _categoryLabel(category, l10n),
                            keyFor: _categoryKey,
                            allLabel: l10n.macosSpotlightFilterAll,
                            onSelect: (category) =>
                                _selectCategory(_mode, category),
                          ),
                          const SizedBox(height: 10),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final columnCount = _crossAxisCountFor(
                                  constraints.maxWidth,
                                );
                                final suggested = <MacosSpotlightResult>[
                                  if (_mode == MacosSpotlightMode.applications)
                                    for (final app in suggestMacosApplications(
                                      results
                                          .whereType<
                                            MacosSpotlightApplicationResult
                                          >()
                                          .map((result) => result.app)
                                          .toList(growable: false),
                                      recentEntryIds,
                                      limit: columnCount,
                                    ))
                                      MacosSpotlightApplicationResult(
                                        app,
                                        suggested: true,
                                      ),
                                ];
                                final targets = _resolveTargets(
                                  suggested,
                                  results,
                                  columnCount,
                                  viewMode,
                                );
                                _visibleTargets = targets;
                                final selectedStillVisible = targets.any(
                                  (target) =>
                                      target.selectionId == _selectedTargetId,
                                );
                                final effectiveSelectedId = selectedStillVisible
                                    ? _selectedTargetId
                                    : (targets.isEmpty
                                          ? null
                                          : targets.first.selectionId);
                                if (clipboardLocked) {
                                  return const _MacosSpotlightLockedState();
                                }
                                if (_mode == MacosSpotlightMode.applications &&
                                    appsLoading) {
                                  return Center(
                                    child: Text(
                                      l10n.desktopLoadingApplications,
                                    ),
                                  );
                                }
                                if (_mode == MacosSpotlightMode.files &&
                                    _filesLoading &&
                                    results.isEmpty) {
                                  return Center(
                                    child: Text(l10n.commonLoading),
                                  );
                                }
                                if (_mode == MacosSpotlightMode.clipboard &&
                                    (clipboardState?.loading ?? false) &&
                                    results.isEmpty) {
                                  return Center(
                                    child: Text(l10n.commonLoading),
                                  );
                                }
                                if (results.isEmpty && suggested.isEmpty) {
                                  return _MacosSpotlightEmptyState(
                                    mode: _mode,
                                    hasQuery: query.trim().isNotEmpty,
                                    clipboardError:
                                        clipboardState?.error != null,
                                  );
                                }
                                if (viewMode == MacosSpotlightViewMode.list) {
                                  return ListView.separated(
                                    controller: _scrollController,
                                    itemCount:
                                        suggested.length + results.length,
                                    separatorBuilder: (_, _) =>
                                        const SizedBox(height: _tileSpacing),
                                    itemBuilder: (context, index) {
                                      final result = index < suggested.length
                                          ? suggested[index]
                                          : results[index - suggested.length];
                                      return _MacosSpotlightListRow(
                                        key: ValueKey<String>(
                                          'macos-spotlight-result-'
                                          '${_mode.name}-${result.resultId}',
                                        ),
                                        result: result,
                                        selected:
                                            effectiveSelectedId ==
                                            _selectionId(result),
                                        actionIconFor: _actionIcon,
                                        actionLabelFor: (action) =>
                                            _actionLabel(action, l10n),
                                        onTap: () => _activateResult(result),
                                      );
                                    },
                                  );
                                }
                                return CustomScrollView(
                                  controller: _scrollController,
                                  slivers: <Widget>[
                                    if (suggested.isNotEmpty) ...<Widget>[
                                      SliverToBoxAdapter(
                                        child: _MacosAppSuggestionsRow(
                                          results: suggested,
                                          effectiveSelectedId:
                                              effectiveSelectedId,
                                          selectionIdFor: _selectionId,
                                          onActivate: _activateResult,
                                        ),
                                      ),
                                      SliverToBoxAdapter(
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: _tileSpacing,
                                          ),
                                          child: Container(
                                            height: 1,
                                            color:
                                                (dark
                                                        ? MacosColors.white
                                                        : MacosColors.black)
                                                    .withValues(alpha: 0.12),
                                          ),
                                        ),
                                      ),
                                    ],
                                    SliverGrid(
                                      gridDelegate:
                                          const SliverGridDelegateWithMaxCrossAxisExtent(
                                            maxCrossAxisExtent: _tileExtent,
                                            mainAxisExtent: _tileExtent,
                                            crossAxisSpacing: _tileSpacing,
                                            mainAxisSpacing: _tileSpacing,
                                          ),
                                      delegate: SliverChildBuilderDelegate((
                                        context,
                                        index,
                                      ) {
                                        final result = results[index];
                                        return _MacosSpotlightGridTile(
                                          result: result,
                                          selected:
                                              effectiveSelectedId ==
                                              _selectionId(result),
                                          actionIconFor: _actionIcon,
                                          actionLabelFor: (action) =>
                                              _actionLabel(action, l10n),
                                          onTap: () => _activateResult(result),
                                        );
                                      }, childCount: results.length),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MacosAppSuggestionsRow extends StatelessWidget {
  const _MacosAppSuggestionsRow({
    required this.results,
    required this.effectiveSelectedId,
    required this.selectionIdFor,
    required this.onActivate,
  });

  final List<MacosSpotlightResult> results;
  final String? effectiveSelectedId;
  final String Function(MacosSpotlightResult result) selectionIdFor;
  final ValueChanged<MacosSpotlightResult> onActivate;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: context.l10n.desktopApplicationSuggestionsTitle,
      child: SizedBox(
        height: _MacosApplicationsSurfaceState._suggestedTileExtent,
        child: GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: _MacosApplicationsSurfaceState._tileExtent,
            mainAxisExtent: _MacosApplicationsSurfaceState._suggestedTileExtent,
            crossAxisSpacing: _MacosApplicationsSurfaceState._tileSpacing,
          ),
          itemCount: results.length,
          itemBuilder: (context, index) {
            final result = results[index];
            return _MacosSpotlightGridTile(
              result: result,
              compact: true,
              selected: effectiveSelectedId == selectionIdFor(result),
              onTap: () => onActivate(result),
            );
          },
        ),
      ),
    );
  }
}

/// Mode segmented buttons plus the persisted grid/list view toggle.
class _MacosSpotlightModeBar extends StatelessWidget {
  const _MacosSpotlightModeBar({
    required this.mode,
    required this.labelFor,
    required this.viewMode,
    required this.onSelectMode,
    required this.onToggleView,
  });

  final MacosSpotlightMode mode;
  final String Function(MacosSpotlightMode mode) labelFor;
  final MacosSpotlightViewMode viewMode;
  final ValueChanged<MacosSpotlightMode> onSelectMode;
  final VoidCallback onToggleView;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final foreground = dark ? MacosColors.white : MacosColors.black;
    final l10n = context.l10n;
    final list = viewMode == MacosSpotlightViewMode.list;
    return Row(
      children: [
        for (final candidate in MacosSpotlightMode.values) ...[
          _MacosSpotlightModeButton(
            key: macosSpotlightModeKey(candidate),
            label: labelFor(candidate),
            selected: candidate == mode,
            onTap: () => onSelectMode(candidate),
          ),
          if (candidate != MacosSpotlightMode.values.last)
            const SizedBox(width: 4),
        ],
        const Spacer(),
        Semantics(
          button: true,
          label: list
              ? l10n.macosSpotlightGridView
              : l10n.macosSpotlightListView,
          child: MouseRegion(
            cursor: ShellMouseCursors.link,
            child: GestureDetector(
              key: macosSpotlightViewToggleKey,
              behavior: HitTestBehavior.opaque,
              onTap: onToggleView,
              child: SizedBox.square(
                dimension: 28,
                child: Icon(
                  list
                      ? CupertinoIcons.square_grid_2x2
                      : CupertinoIcons.list_bullet,
                  size: 17,
                  color: foreground.withValues(alpha: 0.65),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MacosSpotlightModeButton extends StatefulWidget {
  const _MacosSpotlightModeButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_MacosSpotlightModeButton> createState() =>
      _MacosSpotlightModeButtonState();
}

class _MacosSpotlightModeButtonState extends State<_MacosSpotlightModeButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final foreground = dark ? MacosColors.white : MacosColors.black;
    final highlighted = widget.selected || _hovered;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: MouseRegion(
        cursor: ShellMouseCursors.link,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: widget.selected
                  ? theme.primaryColor.withValues(alpha: 0.24)
                  : highlighted
                  ? foreground.withValues(alpha: 0.08)
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
                color: foreground.withValues(alpha: widget.selected ? 1 : 0.72),
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontally scrolling filter chips; empty [categories] renders nothing.
class _MacosSpotlightFilterRow extends StatelessWidget {
  const _MacosSpotlightFilterRow({
    required this.categories,
    required this.selected,
    required this.labelFor,
    required this.keyFor,
    required this.allLabel,
    required this.onSelect,
  });

  final List<Object> categories;
  final Object? selected;
  final String Function(Object category) labelFor;
  final String Function(Object category) keyFor;
  final String allLabel;
  final ValueChanged<Object?> onSelect;

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 28,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _MacosSpotlightFilterChip(
            key: macosSpotlightFilterKey('all'),
            label: allLabel,
            selected: selected == null,
            onTap: () => onSelect(null),
          ),
          for (final category in categories)
            _MacosSpotlightFilterChip(
              key: macosSpotlightFilterKey(keyFor(category)),
              label: labelFor(category),
              selected: selected == category,
              onTap: () => onSelect(category),
            ),
        ],
      ),
    );
  }
}

class _MacosSpotlightFilterChip extends StatelessWidget {
  const _MacosSpotlightFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final foreground = dark ? MacosColors.white : MacosColors.black;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: MouseRegion(
        cursor: ShellMouseCursors.link,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: selected
                  ? theme.primaryColor.withValues(alpha: 0.24)
                  : foreground.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected
                    ? theme.primaryColor.withValues(alpha: 0.6)
                    : foreground.withValues(alpha: 0.14),
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: foreground.withValues(alpha: selected ? 1 : 0.7),
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Icon-and-label grid tile for non-application Spotlight results, and the
/// tile used by the suggested applications row.
class _MacosSpotlightGridTile extends StatefulWidget {
  const _MacosSpotlightGridTile({
    required this.result,
    required this.selected,
    required this.onTap,
    this.actionIconFor,
    this.actionLabelFor,
    this.compact = false,
  });

  final MacosSpotlightResult result;
  final bool selected;
  final VoidCallback onTap;
  final IconData Function(MacosSpotlightAction action)? actionIconFor;
  final String Function(MacosSpotlightAction action)? actionLabelFor;
  final bool compact;

  @override
  State<_MacosSpotlightGridTile> createState() =>
      _MacosSpotlightGridTileState();
}

class _MacosSpotlightGridTileState extends State<_MacosSpotlightGridTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final foreground = dark ? MacosColors.white : MacosColors.black;
    final highlighted = widget.selected || _hovered;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: _semanticsLabel(context),
      child: MouseRegion(
        cursor: ShellMouseCursors.link,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: highlighted
                  ? theme.primaryColor.withValues(alpha: 0.22)
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(12),
              border: widget.selected
                  ? Border.all(color: theme.primaryColor.withValues(alpha: 0.7))
                  : null,
            ),
            child: Column(
              children: [
                SizedBox(width: 52, height: 52, child: _buildIcon(context)),
                const SizedBox(height: 6),
                if (widget.compact)
                  Text(
                    _title(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: foreground,
                      decoration: TextDecoration.none,
                    ),
                  )
                else
                  Expanded(
                    child: Text(
                      _title(context),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: foreground,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _title(BuildContext context) {
    return switch (widget.result) {
      MacosSpotlightApplicationResult(:final app) => app.name,
      MacosSpotlightFileResult(:final path) => p.basename(path),
      MacosSpotlightActionResult(:final action) =>
        widget.actionLabelFor?.call(action) ?? action.name,
      MacosSpotlightClipboardResult(:final entry) =>
        entry.preview.isEmpty ? entry.primaryMimeType : entry.preview,
    };
  }

  String _semanticsLabel(BuildContext context) {
    return switch (widget.result) {
      MacosSpotlightApplicationResult(:final app) =>
        context.l10n.desktopLaunchApplication(app.name),
      _ => _title(context),
    };
  }

  Widget _buildIcon(BuildContext context) {
    final theme = MacosTheme.of(context);
    final foreground = theme.brightness == Brightness.dark
        ? MacosColors.white
        : MacosColors.black;
    return switch (widget.result) {
      MacosSpotlightApplicationResult(:final app) => DeferredAppIcon(
        iconPath: app.iconPath,
      ),
      MacosSpotlightFileResult(:final isDirectory) => Icon(
        isDirectory ? CupertinoIcons.folder_fill : CupertinoIcons.doc_fill,
        size: 40,
        color: foreground.withValues(alpha: 0.7),
      ),
      MacosSpotlightActionResult(:final action) => Icon(
        widget.actionIconFor?.call(action) ?? CupertinoIcons.bolt_fill,
        size: 36,
        color: foreground.withValues(alpha: 0.7),
      ),
      MacosSpotlightClipboardResult(:final entry) => Icon(
        switch (macosSpotlightClipboardCategoryFor(entry)) {
          MacosSpotlightClipboardCategory.image => CupertinoIcons.photo,
          MacosSpotlightClipboardCategory.files => CupertinoIcons.folder,
          MacosSpotlightClipboardCategory.text => CupertinoIcons.doc_text,
        },
        size: 36,
        color: foreground.withValues(alpha: 0.7),
      ),
    };
  }
}

/// Single-row result presentation for list view.
class _MacosSpotlightListRow extends StatefulWidget {
  const _MacosSpotlightListRow({
    super.key,
    required this.result,
    required this.selected,
    required this.onTap,
    this.actionIconFor,
    this.actionLabelFor,
  });

  final MacosSpotlightResult result;
  final bool selected;
  final VoidCallback onTap;
  final IconData Function(MacosSpotlightAction action)? actionIconFor;
  final String Function(MacosSpotlightAction action)? actionLabelFor;

  @override
  State<_MacosSpotlightListRow> createState() => _MacosSpotlightListRowState();
}

class _MacosSpotlightListRowState extends State<_MacosSpotlightListRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final foreground = dark ? MacosColors.white : MacosColors.black;
    final highlighted = widget.selected || _hovered;
    final subtitle = _subtitle();
    return Semantics(
      button: true,
      selected: widget.selected,
      label: _semanticsLabel(context),
      child: MouseRegion(
        cursor: ShellMouseCursors.link,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: _MacosApplicationsSurfaceState._listRowExtent,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: highlighted
                  ? theme.primaryColor.withValues(alpha: 0.22)
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(9),
              border: widget.selected
                  ? Border.all(color: theme.primaryColor.withValues(alpha: 0.7))
                  : null,
            ),
            child: Row(
              children: [
                SizedBox(width: 28, height: 28, child: _buildIcon(context)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: foreground,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: foreground.withValues(alpha: 0.55),
                            decoration: TextDecoration.none,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _title(BuildContext context) {
    return switch (widget.result) {
      MacosSpotlightApplicationResult(:final app) => app.name,
      MacosSpotlightFileResult(:final path) => p.basename(path),
      MacosSpotlightActionResult(:final action) =>
        widget.actionLabelFor?.call(action) ?? action.name,
      MacosSpotlightClipboardResult(:final entry) =>
        entry.preview.isEmpty ? entry.primaryMimeType : entry.preview,
    };
  }

  String? _subtitle() {
    return switch (widget.result) {
      MacosSpotlightFileResult(:final path) => p.dirname(path),
      MacosSpotlightClipboardResult(:final entry) =>
        entry.sourceTitle.isEmpty ? null : entry.sourceTitle,
      _ => null,
    };
  }

  String _semanticsLabel(BuildContext context) {
    return switch (widget.result) {
      MacosSpotlightApplicationResult(:final app) =>
        context.l10n.desktopLaunchApplication(app.name),
      _ => _title(context),
    };
  }

  Widget _buildIcon(BuildContext context) {
    final theme = MacosTheme.of(context);
    final foreground = theme.brightness == Brightness.dark
        ? MacosColors.white
        : MacosColors.black;
    return switch (widget.result) {
      MacosSpotlightApplicationResult(:final app) => DeferredAppIcon(
        iconPath: app.iconPath,
      ),
      MacosSpotlightFileResult(:final isDirectory) => Icon(
        isDirectory ? CupertinoIcons.folder_fill : CupertinoIcons.doc_fill,
        size: 20,
        color: foreground.withValues(alpha: 0.7),
      ),
      MacosSpotlightActionResult(:final action) => Icon(
        widget.actionIconFor?.call(action) ?? CupertinoIcons.bolt_fill,
        size: 20,
        color: foreground.withValues(alpha: 0.7),
      ),
      MacosSpotlightClipboardResult(:final entry) => Icon(
        switch (macosSpotlightClipboardCategoryFor(entry)) {
          MacosSpotlightClipboardCategory.image => CupertinoIcons.photo,
          MacosSpotlightClipboardCategory.files => CupertinoIcons.folder,
          MacosSpotlightClipboardCategory.text => CupertinoIcons.doc_text,
        },
        size: 20,
        color: foreground.withValues(alpha: 0.7),
      ),
    };
  }
}

class _MacosAppSearchField extends StatelessWidget {
  const _MacosAppSearchField({
    required this.controller,
    required this.focusNode,
    required this.onClear,
    required this.onSubmit,
    required this.placeholder,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClear;
  final VoidCallback onSubmit;
  final String placeholder;

  static final List<TextInputFormatter> _inputFormatters =
      List<TextInputFormatter>.unmodifiable(<TextInputFormatter>[
        FilteringTextInputFormatter.deny(RegExp(r'[\u0000-\u001F\u007F]')),
      ]);

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final hasQuery = controller.text.isNotEmpty;
    final foreground = dark ? MacosColors.white : MacosColors.black;
    final l10n = context.l10n;
    return Semantics(
      textField: true,
      label: placeholder,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: (dark ? MacosColors.white : MacosColors.black).withValues(
            alpha: dark ? 0.12 : 0.06,
          ),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: (dark ? MacosColors.white : MacosColors.black).withValues(
              alpha: 0.14,
            ),
          ),
        ),
        child: SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(
                  CupertinoIcons.search,
                  size: 18,
                  color: foreground.withValues(alpha: 0.55),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      if (!hasQuery)
                        IgnorePointer(
                          child: Text(
                            placeholder,
                            style: TextStyle(
                              color: foreground.withValues(alpha: 0.45),
                              fontSize: 14,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      EditableText(
                        key: macosApplicationsSearchFieldKey,
                        controller: controller,
                        focusNode: focusNode,
                        mouseCursor: ShellMouseCursors.text,
                        autofocus: true,
                        maxLines: 1,
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.search,
                        onEditingComplete: () {},
                        onSubmitted: (_) => onSubmit(),
                        style: theme.typography.body.copyWith(
                          color: foreground,
                        ),
                        cursorColor: theme.primaryColor,
                        backgroundCursorColor: foreground.withValues(
                          alpha: 0.55,
                        ),
                        selectionColor: theme.primaryColor.withValues(
                          alpha: 0.3,
                        ),
                        inputFormatters: _inputFormatters,
                      ),
                    ],
                  ),
                ),
                if (hasQuery) ...[
                  const SizedBox(width: 8),
                  Semantics(
                    button: true,
                    label: l10n.desktopClearApplicationSearch,
                    child: MouseRegion(
                      cursor: ShellMouseCursors.link,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onClear,
                        child: SizedBox.square(
                          dimension: 24,
                          child: Icon(
                            CupertinoIcons.clear_thick_circled,
                            size: 16,
                            color: foreground.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Empty-state message per mode; the Applications copy stays Phase 1.
class _MacosSpotlightEmptyState extends StatelessWidget {
  const _MacosSpotlightEmptyState({
    required this.mode,
    required this.hasQuery,
    required this.clipboardError,
  });

  final MacosSpotlightMode mode;
  final bool hasQuery;
  final bool clipboardError;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final foreground = theme.brightness == Brightness.dark
        ? MacosColors.white
        : MacosColors.black;
    final l10n = context.l10n;
    final message = switch (mode) {
      MacosSpotlightMode.applications => l10n.desktopNoApplicationsFound,
      MacosSpotlightMode.clipboard when clipboardError =>
        l10n.clipboardUnavailableTitle,
      MacosSpotlightMode.clipboard when hasQuery =>
        l10n.clipboardNoSearchResultsTitle,
      MacosSpotlightMode.clipboard => l10n.clipboardEmptyTitle,
      _ => l10n.macosSpotlightNoResults,
    };
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            CupertinoIcons.search,
            size: 30,
            color: foreground.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: theme.typography.body.copyWith(
              color: foreground.withValues(alpha: 0.65),
            ),
          ),
        ],
      ),
    );
  }
}

/// Clipboard history remains sealed while the session is locked, mirroring
/// the clipboard tray's redaction policy.
class _MacosSpotlightLockedState extends StatelessWidget {
  const _MacosSpotlightLockedState();

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final foreground = theme.brightness == Brightness.dark
        ? MacosColors.white
        : MacosColors.black;
    final l10n = context.l10n;
    return Center(
      key: macosSpotlightClipboardLockedKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            CupertinoIcons.lock,
            size: 30,
            color: foreground.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.clipboardHistoryLockedTitle,
            style: theme.typography.body.copyWith(
              color: foreground.withValues(alpha: 0.8),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.clipboardHistoryLockedDescription,
            textAlign: TextAlign.center,
            style: theme.typography.body.copyWith(
              color: foreground.withValues(alpha: 0.65),
            ),
          ),
        ],
      ),
    );
  }
}
