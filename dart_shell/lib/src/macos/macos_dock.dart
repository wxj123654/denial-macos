import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart'
    show ButtonStyle, MenuAnchor, MenuController, MenuItemButton, MenuStyle;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import '../input/shell_interaction_registry.dart';
import '../localization/denial_localizations.dart';
import '../widgets/shell_cursor.dart';
import 'macos_dock_model.dart';

/// Key for the persistent Apps entry in the macOS Dock.
const macosDockApplicationsKey = ValueKey<String>('macos-dock-applications');

/// Key for the persistent System Settings entry in the macOS Dock.
const macosDockSettingsKey = ValueKey<String>('macos-dock-settings');

/// Key for the divider between persistent items and application entries.
const macosDockRunningSeparatorKey = ValueKey<String>(
  'macos-dock-running-separator',
);

/// Key for the `DragTarget<DesktopApp>` that pins dropped applications.
const macosDockDropTargetKey = ValueKey<String>('macos-dock-drop-target');

/// Key for one application-area Dock item.
ValueKey<String> macosDockItemKey(String entryId) =>
    ValueKey<String>('macos-dock-item-$entryId');

/// Key for the running indicator dot under an application Dock item.
ValueKey<String> macosDockRunningIndicatorKey(String entryId) =>
    ValueKey<String>('macos-dock-running-$entryId');

/// Key for a context-menu action inside an application Dock item.
ValueKey<String> macosDockMenuItemKey(String action, String entryId) =>
    ValueKey<String>('macos-dock-menu-$action-$entryId');

/// Maximum number of open windows listed in a Dock context menu.
const int _macosDockMenuWindowLimit = 8;

/// Centered Dock with persistent shell items (Apps and Settings) followed by
/// pinned and running [MacosDockEntry] application groups. One item always
/// represents one application regardless of window count; entries with only
/// minimized windows stay discoverable and restore on activation.
///
/// Keyboard semantics are deterministic: Left/Right arrows move focus along
/// the item order, Enter/Space activate, and the ContextMenu key opens the
/// item's menu. Secondary click opens the same menu.
///
/// When [onPinApp] is provided, the Dock is a `DragTarget<DesktopApp>`:
/// dropping an application pins it by desktop-file id. That is the
/// integration point for dragging from the Apps surface.
class MacosDock extends StatelessWidget {
  const MacosDock({
    super.key,
    required this.entries,
    required this.onOpenApplications,
    required this.onOpenSettings,
    this.onActivateEntry,
    this.onActivateWindow,
    this.onMinimizeEntry,
    this.onQuitEntry,
    this.onTogglePin,
    this.onPinApp,
  });

  /// Ordered application entries: pins first, then unpinned running groups.
  final List<MacosDockEntry> entries;
  final VoidCallback onOpenApplications;
  final VoidCallback onOpenSettings;

  /// Activates an entry: restores its minimized windows and focuses the
  /// topmost, or launches [MacosDockEntry.app] when it has no windows.
  final ValueChanged<MacosDockEntry>? onActivateEntry;

  /// Activates one window of an entry from its context menu.
  final ValueChanged<DenialWindow>? onActivateWindow;

  /// Minimizes every non-minimized window of an entry.
  final ValueChanged<MacosDockEntry>? onMinimizeEntry;

  /// Closes every window of an entry.
  final ValueChanged<MacosDockEntry>? onQuitEntry;

  /// Toggles [MacosDockEntry.pinId] in the persisted pin list.
  final ValueChanged<MacosDockEntry>? onTogglePin;

  /// Pins a dropped application by desktop-file id (`DesktopApp.id`).
  final ValueChanged<String>? onPinApp;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final pinApp = onPinApp;
    final row = FocusTraversalGroup(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DockItem(
            key: macosDockApplicationsKey,
            label: l10n.desktopApplicationsTitle,
            onActivate: onOpenApplications,
            tile: const _PersistentDockTile(
              icon: CupertinoIcons.square_grid_3x2,
            ),
          ),
          _DockItem(
            key: macosDockSettingsKey,
            label: l10n.settingsApplicationTitle,
            onActivate: onOpenSettings,
            tile: const _PersistentDockTile(icon: CupertinoIcons.gear_solid),
          ),
          if (entries.isNotEmpty) const _DockRunningSeparator(),
          for (final entry in entries)
            _MacosDockAppItem(
              key: macosDockItemKey(entry.id),
              entry: entry,
              onActivate: onActivateEntry,
              onActivateWindow: onActivateWindow,
              onMinimize: onMinimizeEntry,
              onQuit: onQuitEntry,
              onTogglePin: onTogglePin,
            ),
        ],
      ),
    );
    if (pinApp == null) {
      return _DockFrame(dropActive: false, child: row);
    }
    return DragTarget<DesktopApp>(
      key: macosDockDropTargetKey,
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => pinApp(details.data.id),
      builder: (context, candidateData, rejectedData) =>
          _DockFrame(dropActive: candidateData.isNotEmpty, child: row),
    );
  }
}

/// Rounded translucent Dock frame. Brightens and draws an accent border
/// while a compatible drag hovers over the Dock.
class _DockFrame extends StatelessWidget {
  const _DockFrame({required this.dropActive, required this.child});

  final bool dropActive;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: (dark ? MacosColors.black : MacosColors.white).withValues(
          alpha: dropActive ? 0.68 : 0.5,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: dropActive
              ? theme.primaryColor
              : (dark ? MacosColors.white : MacosColors.black).withValues(
                  alpha: 0.12,
                ),
        ),
      ),
      child: child,
    );
  }
}

/// One focusable Dock item: a tile with an optional running indicator,
/// primary-tap activation, deterministic arrow/Enter/ContextMenu keyboard
/// handling, and an optional secondary-click context menu.
class _DockItem extends StatefulWidget {
  const _DockItem({
    super.key,
    required this.label,
    required this.tile,
    this.running = false,
    this.active = false,
    this.dimmed = false,
    this.runningIndicatorKey,
    this.onActivate,
    this.menuChildrenBuilder,
  });

  final String label;
  final Widget tile;
  final bool running;
  final bool active;
  final bool dimmed;
  final Key? runningIndicatorKey;
  final VoidCallback? onActivate;

  /// When set, secondary click and the ContextMenu key open this menu.
  final List<Widget> Function(BuildContext context)? menuChildrenBuilder;

  @override
  State<_DockItem> createState() => _DockItemState();
}

class _DockItemState extends State<_DockItem> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'macos-dock-item');
  final MenuController _menuController = MenuController();
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _activate() {
    _focusNode.requestFocus();
    widget.onActivate?.call();
  }

  void _openMenu() {
    _focusNode.requestFocus();
    if (!_menuController.isOpen) {
      _menuController.open();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = theme.primaryColor;
    final menuChildrenBuilder = widget.menuChildrenBuilder;
    Widget item = CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            FocusScope.of(context).nextFocus(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            FocusScope.of(context).previousFocus(),
        const SingleActivator(LogicalKeyboardKey.enter): _activate,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _activate,
        const SingleActivator(LogicalKeyboardKey.space): _activate,
        if (menuChildrenBuilder != null)
          const SingleActivator(LogicalKeyboardKey.contextMenu): _openMenu,
      },
      child: FocusableActionDetector(
        focusNode: _focusNode,
        mouseCursor: ShellMouseCursors.link,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _activate,
          onSecondaryTapUp: menuChildrenBuilder != null
              ? (_) => _openMenu()
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(
                  opacity: widget.dimmed ? 0.55 : 1,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(11),
                      border: widget.active || _focused
                          ? Border.all(
                              color: accent.withValues(alpha: 0.9),
                              width: widget.active ? 1.5 : 1,
                            )
                          : null,
                    ),
                    child: widget.tile,
                  ),
                ),
                const SizedBox(height: 2),
                Container(
                  key: widget.running ? widget.runningIndicatorKey : null,
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: widget.running
                        ? (dark ? MacosColors.white : MacosColors.black)
                              .withValues(alpha: 0.8)
                        : const Color(0x00000000),
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (menuChildrenBuilder != null) {
      item = MenuAnchor(
        controller: _menuController,
        alignmentOffset: const Offset(0, 4),
        style: _menuStyle(dark),
        menuChildren: menuChildrenBuilder(context),
        child: item,
      );
    }
    return Semantics(button: true, label: widget.label, child: item);
  }

  MenuStyle _menuStyle(bool dark) {
    return MenuStyle(
      alignment: AlignmentDirectional.bottomCenter,
      backgroundColor: WidgetStatePropertyAll<Color>(
        (dark ? const Color(0xFF2B2B2E) : MacosColors.white).withValues(
          alpha: 0.96,
        ),
      ),
      elevation: const WidgetStatePropertyAll<double>(8),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(vertical: 4),
      ),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

/// One application-group Dock item with a running indicator, active-state
/// ring, catalogue icon or letter fallback, and a window/pin/quit menu.
class _MacosDockAppItem extends StatelessWidget {
  const _MacosDockAppItem({
    super.key,
    required this.entry,
    this.onActivate,
    this.onActivateWindow,
    this.onMinimize,
    this.onQuit,
    this.onTogglePin,
  });

  final MacosDockEntry entry;
  final ValueChanged<MacosDockEntry>? onActivate;
  final ValueChanged<DenialWindow>? onActivateWindow;
  final ValueChanged<MacosDockEntry>? onMinimize;
  final ValueChanged<MacosDockEntry>? onQuit;
  final ValueChanged<MacosDockEntry>? onTogglePin;

  @override
  Widget build(BuildContext context) {
    return _DockItem(
      label: entry.label,
      running: entry.running,
      runningIndicatorKey: macosDockRunningIndicatorKey(entry.id),
      active: entry.active,
      dimmed: entry.allWindowsMinimized,
      tile: _DockEntryTile(entry: entry),
      onActivate: () => onActivate?.call(entry),
      menuChildrenBuilder: _menuChildren,
    );
  }

  List<Widget> _menuChildren(BuildContext context) {
    final l10n = context.l10n;
    final buttonStyle = _menuButtonStyle(context);
    final children = <Widget>[];
    if (!entry.running) {
      children.add(
        _menuItem(
          key: macosDockMenuItemKey('open', entry.id),
          label: l10n.desktopDockOpen,
          style: buttonStyle,
          onPressed: onActivate == null ? null : () => onActivate?.call(entry),
        ),
      );
    } else {
      // List the group's windows topmost-first so the focused window heads
      // the menu, capped so large groups keep the menu bounded.
      final windows = entry.windows.reversed
          .take(_macosDockMenuWindowLimit)
          .toList(growable: false);
      for (final window in windows) {
        final minimized = entry.minimizedObjectIds.contains(window.objectId);
        children.add(
          _menuItem(
            key: macosDockMenuItemKey('window-${window.objectId}', entry.id),
            label: window.displayTitle,
            style: buttonStyle,
            dimmed: minimized,
            onPressed: () => onActivateWindow?.call(window),
          ),
        );
      }
      children.add(const _DockMenuDivider());
      children.add(
        _menuItem(
          key: macosDockMenuItemKey('minimize', entry.id),
          label: l10n.desktopDockMinimize,
          style: buttonStyle,
          onPressed: entry.allWindowsMinimized || onMinimize == null
              ? null
              : () => onMinimize?.call(entry),
        ),
      );
    }
    if (onTogglePin != null) {
      children.add(
        _menuItem(
          key: macosDockMenuItemKey('pin', entry.id),
          label: entry.pinned
              ? l10n.desktopDockRemoveFromDock
              : l10n.desktopDockKeepInDock,
          style: buttonStyle,
          onPressed: () => onTogglePin?.call(entry),
        ),
      );
    }
    if (entry.running && onQuit != null) {
      children.add(const _DockMenuDivider());
      children.add(
        _menuItem(
          key: macosDockMenuItemKey('quit', entry.id),
          label: l10n.desktopDockQuit,
          style: buttonStyle,
          onPressed: () => onQuit?.call(entry),
        ),
      );
    }
    return children;
  }

  Widget _menuItem({
    required Key key,
    required String label,
    required ButtonStyle style,
    bool dimmed = false,
    VoidCallback? onPressed,
  }) {
    return ShellInputRegion(
      debugLabel: 'macos-dock-menu-item',
      child: MenuItemButton(
        key: key,
        style: style,
        onPressed: onPressed,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: dimmed ? const TextStyle(fontStyle: FontStyle.italic) : null,
        ),
      ),
    );
  }

  ButtonStyle _menuButtonStyle(BuildContext context) {
    final dark = MacosTheme.of(context).brightness == Brightness.dark;
    final foreground = dark ? MacosColors.white : MacosColors.black;
    return MenuItemButton.styleFrom(
      foregroundColor: foreground.withValues(alpha: 0.9),
      disabledForegroundColor: foreground.withValues(alpha: 0.35),
      textStyle: const TextStyle(fontSize: 13),
      minimumSize: const Size(180, 30),
      padding: const EdgeInsets.symmetric(horizontal: 12),
    );
  }
}

/// Hairline divider between persistent Dock items and application entries.
class _DockRunningSeparator extends StatelessWidget {
  const _DockRunningSeparator();

  @override
  Widget build(BuildContext context) {
    final dark = MacosTheme.of(context).brightness == Brightness.dark;
    return Container(
      key: macosDockRunningSeparatorKey,
      width: 1,
      height: 36,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: (dark ? MacosColors.white : MacosColors.black).withValues(
        alpha: 0.18,
      ),
    );
  }
}

/// Thin horizontal rule between a Dock menu's window list and its actions.
class _DockMenuDivider extends StatelessWidget {
  const _DockMenuDivider();

  @override
  Widget build(BuildContext context) {
    final dark = MacosTheme.of(context).brightness == Brightness.dark;
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      color: (dark ? MacosColors.white : MacosColors.black).withValues(
        alpha: 0.12,
      ),
    );
  }
}

/// Icon content of a persistent Dock item.
class _PersistentDockTile extends StatelessWidget {
  const _PersistentDockTile({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    return Container(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(11),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 22, color: MacosColors.white),
    );
  }
}

/// Icon content of an application Dock item: the resolved catalogue icon
/// when available, else the app's first-letter tile.
class _DockEntryTile extends StatelessWidget {
  const _DockEntryTile({required this.entry});

  final MacosDockEntry entry;

  @override
  Widget build(BuildContext context) {
    final iconPath = entry.app?.iconPath;
    if (iconPath != null) {
      return Padding(
        padding: const EdgeInsets.all(4),
        child: AppIconImage(iconPath: iconPath),
      );
    }
    final accent = MacosTheme.of(context).primaryColor;
    final source = entry.label.trim();
    final label = source.isEmpty ? '?' : source.substring(0, 1).toUpperCase();
    return Container(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(11),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: MacosColors.white,
        ),
      ),
    );
  }
}
