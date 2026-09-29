import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../launcher/models/desktop_app.dart';
import '../localization/denial_localizations.dart';
import '../settings/widgets/settings_controls.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import 'macos_application_roles.dart';

/// Key for the default-applications Settings page body.
const settingsDefaultApplicationsPageKey = ValueKey<String>(
  'settings-default-applications-page',
);

/// The dropdown value which clears an override and returns a role to
/// freedesktop resolution.
const settingsDefaultApplicationsAutomaticValue = '';

/// Key for the per-role application picker.
ValueKey<String> settingsDefaultApplicationsRoleKey(
  MacosApplicationRole role,
) => ValueKey<String>('settings-default-applications-role-${role.settingsKey}');

/// "Default applications" override page shared by the embedded and the
/// standalone Denial Settings surfaces.
///
/// Each row persists one explicit choice per [MacosApplicationRole]; the
/// "System default" choice clears the override so the role follows
/// `mimeapps.list` and the category fallback again. Rows also surface the
/// effective resolution so a missing handler fails visibly inside Settings.
class SettingsDefaultApplicationsPage extends StatelessWidget {
  const SettingsDefaultApplicationsPage({
    required this.overrides,
    required this.resolutions,
    required this.applications,
    required this.onSelect,
    required this.onReset,
    this.loading = false,
    super.key,
  });

  /// Persisted overrides keyed by [MacosApplicationRoleSpec.settingsKey].
  final Map<String, String> overrides;

  /// Effective resolution per role, from `macosRoleResolverProvider`.
  final Map<MacosApplicationRole, MacosRoleResolution> resolutions;

  /// Installed desktop entries offered as picker choices.
  final List<DesktopApp> applications;

  /// True while the catalogue or associations are still loading.
  final bool loading;

  /// Called with a desktop-file ID, or `null` to clear the override.
  final void Function(MacosApplicationRole role, String? desktopFileId)
  onSelect;

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hasOverrides = overrides.keys.any(
      (key) =>
          MacosApplicationRole.values.any((role) => role.settingsKey == key),
    );
    return SettingsPageLayout(
      icon: Icons.app_settings_alt_rounded,
      eyebrow: l10n.settingsEnvironmentSection,
      title: l10n.settingsDefaultApplicationsTitle,
      onReset: hasOverrides ? onReset : null,
      children: [
        SettingsCardGroup(
          key: settingsDefaultApplicationsPageKey,
          children: [
            for (final role in MacosApplicationRole.values)
              _roleSection(context, role),
          ],
        ),
      ],
    );
  }

  Widget _roleSection(BuildContext context, MacosApplicationRole role) {
    final l10n = context.l10n;
    final resolution = resolutions[role];
    final overrideId = overrides[role.settingsKey];
    final installedIds = <String>{
      for (final application in applications) application.id,
    };
    final choices = <SettingsChoice<String>>[
      SettingsChoice(
        settingsDefaultApplicationsAutomaticValue,
        l10n.settingsDefaultApplicationsAutomatic,
      ),
      for (final application in applications)
        SettingsChoice(application.id, application.name),
      if (overrideId != null && !installedIds.contains(overrideId))
        SettingsChoice(
          overrideId,
          l10n.settingsDefaultApplicationsNotInstalled(overrideId),
        ),
    ];
    return SettingsSection(
      title: _roleLabel(l10n, role),
      status: resolution?.app?.name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSelect<String>(
            key: settingsDefaultApplicationsRoleKey(role),
            label: l10n.settingsDefaultApplicationsOpensWith,
            description: _roleDescription(l10n, role),
            value: overrideId ?? settingsDefaultApplicationsAutomaticValue,
            choices: choices,
            enabled: !loading,
            onChanged: (id) => onSelect(
              role,
              id == settingsDefaultApplicationsAutomaticValue ? null : id,
            ),
          ),
          if (resolution != null && !resolution.resolved) ...[
            const SizedBox(height: 8),
            Text(
              l10n.settingsDefaultApplicationsUnavailable,
              style: ShellText.base.copyWith(
                color: context.shellColors.textTertiary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _roleLabel(AppLocalizations l10n, MacosApplicationRole role) {
    return switch (role) {
      MacosApplicationRole.fileManager =>
        l10n.settingsDefaultApplicationsRoleFiles,
      MacosApplicationRole.webBrowser =>
        l10n.settingsDefaultApplicationsRoleBrowser,
      MacosApplicationRole.terminal =>
        l10n.settingsDefaultApplicationsRoleTerminal,
      MacosApplicationRole.mail => l10n.settingsDefaultApplicationsRoleMail,
      MacosApplicationRole.calendar =>
        l10n.settingsDefaultApplicationsRoleCalendar,
      MacosApplicationRole.media => l10n.settingsDefaultApplicationsRoleMedia,
    };
  }

  String _roleDescription(AppLocalizations l10n, MacosApplicationRole role) {
    return switch (role) {
      MacosApplicationRole.fileManager =>
        l10n.settingsDefaultApplicationsRoleFilesDescription,
      MacosApplicationRole.webBrowser =>
        l10n.settingsDefaultApplicationsRoleBrowserDescription,
      MacosApplicationRole.terminal =>
        l10n.settingsDefaultApplicationsRoleTerminalDescription,
      MacosApplicationRole.mail =>
        l10n.settingsDefaultApplicationsRoleMailDescription,
      MacosApplicationRole.calendar =>
        l10n.settingsDefaultApplicationsRoleCalendarDescription,
      MacosApplicationRole.media =>
        l10n.settingsDefaultApplicationsRoleMediaDescription,
    };
  }
}
