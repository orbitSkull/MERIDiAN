import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';

/// A titled group of rows inside one card.
///
/// Every settings sub-screen is a list of these. Keeping the header, padding
/// and divider rules here means thirty rows across six screens cannot drift
/// apart in their spacing.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.footer,
  });

  final String title;
  final String? subtitle;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.toUpperCase(),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: AppColors.subtextFor(context),
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.subtextFor(context),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    const Padding(
                      padding: EdgeInsets.only(left: 56),
                      child: Divider(height: 1),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
          if (footer != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                footer!,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: AppColors.subtextFor(context),
                ),
              ),
            ),
          ],
          // Keeps the last section off the bottom edge when the list scrolls.
          if (children.isEmpty)
            Text(
              'Nothing to configure yet.',
              style: TextStyle(color: theme.disabledColor),
            ),
        ],
      ),
    );
  }
}

/// A row that navigates somewhere.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
    this.trailing,
    this.destructive = false,
    this.leadingWidget,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? value;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool destructive;
  final Widget? leadingWidget;

  @override
  Widget build(BuildContext context) {
    final titleColor =
        destructive ? Theme.of(context).colorScheme.error : null;

    return ListTile(
      onTap: onTap,
      leading: leadingWidget ??
          Icon(
            icon,
            color: destructive
                ? Theme.of(context).colorScheme.error
                : AppColors.subtextFor(context),
          ),
      title: Text(
        title,
        style: TextStyle(fontWeight: FontWeight.w600, color: titleColor),
      ),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: trailing ??
          (onTap == null
              ? null
              : const Icon(Icons.chevron_right_rounded, size: 20)),
    );
  }
}

/// A row with a switch.
class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final muted = !enabled;
    final titleColor = muted
        ? AppColors.subtextFor(context)
        : AppColors.inkFor(context);

    return SwitchListTile(
      value: value,
      onChanged: enabled ? onChanged : null,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      secondary: Icon(
        icon,
        color: muted
            ? Theme.of(context).disabledColor
            : AppColors.subtextFor(context),
      ),
      title: Text(
        title,
        style: TextStyle(fontWeight: FontWeight.w600, color: titleColor),
      ),
      subtitle: subtitle == null ? null : Text(subtitle!),
    );
  }
}

/// A row with a trailing control that is not a switch, such as a segmented
/// button or a slider.
class SettingsControlTile extends StatelessWidget {
  const SettingsControlTile({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.subtextFor(context)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.subtextFor(context),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                child,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder for a screen that is planned but not built.
///
/// Used instead of a dead ListTile so it is obvious in the UI that the row is
/// deliberate rather than broken.
class ComingSoonTile extends StatelessWidget {
  const ComingSoonTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          'Soon',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.subtextFor(context),
          ),
        ),
      ),
      onTap: () => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$title is planned but not built yet.')),
      ),
    );
  }
}

/// Standard scaffold for a settings sub-screen.
class SettingsScaffold extends StatelessWidget {
  const SettingsScaffold({
    super.key,
    required this.title,
    required this.children,
    this.actions,
  });

  final String title;
  final List<Widget> children;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: children,
      ),
    );
  }
}