import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../input/shell_interaction_registry.dart';
import '../localization/denial_localizations.dart';
import '../widgets/shell_cursor.dart';

/// Key for the macOS Apps surface inserted above the desktop chrome.
const macosApplicationsSurfaceKey = ValueKey<String>(
  'macos-applications-surface',
);

/// Key for the Apps surface search field.
const macosApplicationsSearchFieldKey = ValueKey<String>(
  'macos-applications-search-field',
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

class _MacosAppTarget {
  const _MacosAppTarget({
    required this.app,
    required this.selectionId,
    required this.row,
    required this.column,
    required this.scrollTop,
    required this.scrollExtent,
  });

  final DesktopApp app;
  final String selectionId;
  final int row;
  final int column;
  final double scrollTop;
  final double scrollExtent;
}

String _catalogTargetId(String appId) => 'catalog:$appId';

String _suggestedTargetId(String appId) => 'suggested:$appId';

/// Centered, bounded macOS-style Apps panel over a dismissible barrier.
///
/// The catalogue is backed by [homeGridControllerProvider] and recent
/// launches by [applicationRecentsProvider]. Escape and barrier taps dismiss
/// through [onDismiss]; launching reports the chosen app through [onLaunch]
/// exactly once.
class MacosApplicationsSurface extends ConsumerStatefulWidget {
  const MacosApplicationsSurface({
    super.key,
    required this.searchFocusNode,
    required this.onDismiss,
    required this.onLaunch,
  });

  final FocusNode searchFocusNode;
  final VoidCallback onDismiss;
  final ValueChanged<DesktopApp> onLaunch;

  @override
  ConsumerState<MacosApplicationsSurface> createState() =>
      _MacosApplicationsSurfaceState();
}

class _MacosApplicationsSurfaceState
    extends ConsumerState<MacosApplicationsSurface> {
  static const double _tileExtent = 108;
  static const double _suggestedTileExtent = 92;
  static const double _tileSpacing = 8;

  late final TextEditingController _searchController;
  final ScrollController _gridController = ScrollController();
  String _lastSearchText = '';
  String? _selectedTargetId;
  List<HomeGridItem?>? _cachedSlots;
  List<DesktopApp>? _cachedInstalled;
  List<_MacosAppTarget> _visibleTargets = const <_MacosAppTarget>[];

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController()
      ..addListener(_handleQueryChanged);
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_handleQueryChanged)
      ..dispose();
    _gridController.dispose();
    super.dispose();
  }

  void _handleQueryChanged() {
    final searchText = _searchController.text;
    if (searchText == _lastSearchText) {
      return;
    }
    _lastSearchText = searchText;
    setState(() => _selectedTargetId = null);
    _resetGridScroll();
  }

  void _clearSearch() {
    _searchController.clear();
    widget.searchFocusNode.requestFocus();
  }

  List<DesktopApp> _resolveInstalled(List<HomeGridItem?>? slots) {
    final cached = _cachedInstalled;
    if (cached != null && identical(slots, _cachedSlots)) {
      return cached;
    }
    final resolved = macosInstalledApplications(slots);
    _cachedSlots = slots;
    _cachedInstalled = resolved;
    if (!resolved.any((app) => 'catalog:${app.id}' == _selectedTargetId) &&
        !resolved.any((app) => 'suggested:${app.id}' == _selectedTargetId)) {
      _selectedTargetId = null;
    }
    return resolved;
  }

  int _selectedIndexFor(List<_MacosAppTarget> targets) {
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

  void _selectIndex(List<_MacosAppTarget> targets, int index) {
    if (targets.isEmpty) {
      return;
    }
    final selected = targets[index];
    setState(() => _selectedTargetId = selected.selectionId);
    _revealSelected(selected);
  }

  void _moveSelection(List<_MacosAppTarget> targets, int delta) {
    if (targets.isEmpty) {
      return;
    }
    _selectIndex(
      targets,
      (_selectedIndexFor(targets) + delta) % targets.length,
    );
  }

  void _moveSelectionVertically(List<_MacosAppTarget> targets, int direction) {
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

  void _launchSelected() {
    final targets = _visibleTargets;
    final selectedIndex = _selectedIndexFor(targets);
    if (selectedIndex >= 0) {
      widget.onLaunch(targets[selectedIndex].app);
    }
  }

  void _resetGridScroll() {
    if (!_gridController.hasClients) {
      return;
    }
    final position = _gridController.position;
    if (position.pixels != position.minScrollExtent) {
      position.jumpTo(position.minScrollExtent);
    }
  }

  void _revealSelected(_MacosAppTarget target) {
    if (!_gridController.hasClients) {
      return;
    }
    final position = _gridController.position;
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

  List<_MacosAppTarget> _resolveTargets(
    List<DesktopApp> suggested,
    List<DesktopApp> apps,
    int columnCount,
  ) {
    final catalogRowOffset = suggested.isEmpty ? 0 : 1;
    final catalogScrollOffset = suggested.isEmpty
        ? 0.0
        : _suggestedTileExtent + _tileSpacing * 2 + 1;
    return <_MacosAppTarget>[
      for (var index = 0; index < suggested.length; index += 1)
        _MacosAppTarget(
          app: suggested[index],
          selectionId: _suggestedTargetId(suggested[index].id),
          row: 0,
          column: index,
          scrollTop: 0,
          scrollExtent: _suggestedTileExtent,
        ),
      for (var index = 0; index < apps.length; index += 1)
        _MacosAppTarget(
          app: apps[index],
          selectionId: _catalogTargetId(apps[index].id),
          row: catalogRowOffset + (index ~/ columnCount),
          column: index % columnCount,
          scrollTop:
              catalogScrollOffset +
              (index ~/ columnCount) * (_tileExtent + _tileSpacing),
          scrollExtent: _tileExtent,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final grid = ref.watch(homeGridControllerProvider);
    final slots = grid.asData?.value.slots;
    final loading = slots == null && grid.isLoading;
    final recentEntryIds = ref.watch(applicationRecentsProvider);
    final installed = _resolveInstalled(slots);
    final apps = filterMacosApplications(installed, _searchController.text);
    final theme = MacosTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final l10n = context.l10n;
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
                            onSubmit: _launchSelected,
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final columnCount = _crossAxisCountFor(
                                  constraints.maxWidth,
                                );
                                final suggested = suggestMacosApplications(
                                  apps,
                                  recentEntryIds,
                                  limit: columnCount,
                                );
                                final targets = _resolveTargets(
                                  suggested,
                                  apps,
                                  columnCount,
                                );
                                _visibleTargets = targets;
                                final effectiveSelectedId =
                                    _selectedTargetId ??
                                    (targets.isEmpty
                                        ? null
                                        : targets.first.selectionId);
                                if (loading) {
                                  return Center(
                                    child: Text(
                                      l10n.desktopLoadingApplications,
                                    ),
                                  );
                                }
                                if (installed.isEmpty || apps.isEmpty) {
                                  return const _MacosAppSearchEmptyState();
                                }
                                return CustomScrollView(
                                  controller: _gridController,
                                  slivers: <Widget>[
                                    if (suggested.isNotEmpty) ...<Widget>[
                                      SliverToBoxAdapter(
                                        child: _MacosAppSuggestionsRow(
                                          apps: suggested,
                                          effectiveSelectedId:
                                              effectiveSelectedId,
                                          onLaunch: widget.onLaunch,
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
                                        final app = apps[index];
                                        return _MacosAppTile(
                                          app: app,
                                          selected:
                                              effectiveSelectedId ==
                                              _catalogTargetId(app.id),
                                          onTap: () => widget.onLaunch(app),
                                        );
                                      }, childCount: apps.length),
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
    required this.apps,
    required this.effectiveSelectedId,
    required this.onLaunch,
  });

  final List<DesktopApp> apps;
  final String? effectiveSelectedId;
  final ValueChanged<DesktopApp> onLaunch;

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
          itemCount: apps.length,
          itemBuilder: (context, index) {
            final app = apps[index];
            return _MacosAppTile(
              app: app,
              compact: true,
              selected: effectiveSelectedId == _suggestedTargetId(app.id),
              onTap: () => onLaunch(app),
            );
          },
        ),
      ),
    );
  }
}

class _MacosAppSearchField extends StatelessWidget {
  const _MacosAppSearchField({
    required this.controller,
    required this.focusNode,
    required this.onClear,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClear;
  final VoidCallback onSubmit;

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
      label: l10n.desktopSearchApplications,
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
                            l10n.desktopSearchApplications,
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

class _MacosAppSearchEmptyState extends StatelessWidget {
  const _MacosAppSearchEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final foreground = theme.brightness == Brightness.dark
        ? MacosColors.white
        : MacosColors.black;
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
            context.l10n.desktopNoApplicationsFound,
            style: theme.typography.body.copyWith(
              color: foreground.withValues(alpha: 0.65),
            ),
          ),
        ],
      ),
    );
  }
}

class _MacosAppTile extends StatefulWidget {
  const _MacosAppTile({
    required this.app,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final DesktopApp app;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  State<_MacosAppTile> createState() => _MacosAppTileState();
}

class _MacosAppTileState extends State<_MacosAppTile> {
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
      label: context.l10n.desktopLaunchApplication(widget.app.name),
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
                SizedBox(
                  width: 52,
                  height: 52,
                  child: DeferredAppIcon(iconPath: widget.app.iconPath),
                ),
                const SizedBox(height: 6),
                if (widget.compact)
                  Text(
                    widget.app.name,
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
                      widget.app.name,
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
}
