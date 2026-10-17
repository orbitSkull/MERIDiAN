import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

enum AuthRole { student, faculty, moderator }

extension AuthRoleLabel on AuthRole {
  String get label {
    switch (this) {
      case AuthRole.student:
        return 'Student';
      case AuthRole.faculty:
        return 'Faculty';
      case AuthRole.moderator:
        return 'Moderator';
    }
  }

  IconData get icon {
    switch (this) {
      case AuthRole.student:
        return Icons.school_rounded;
      case AuthRole.faculty:
        return Icons.person_rounded;
      case AuthRole.moderator:
        return Icons.shield_rounded;
    }
  }
}

/// Segmented role picker used on both login + register.
class RoleSegmentedControl extends StatelessWidget {
  final List<AuthRole> roles;
  final AuthRole selected;
  final ValueChanged<AuthRole> onSelected;

  const RoleSegmentedControl({
    super.key,
    required this.roles,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFE9ECF3),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: roles.map((role) {
          final isActive = role == selected;
          return Expanded(
            child: GestureDetector(
              onTap: () => onSelected(role),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: isActive ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                  boxShadow: isActive
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      role.icon,
                      size: 16,
                      color: isActive
                          ? AppColors.primary
                          : AppColors.subtext,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      role.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: isActive
                            ? AppColors.ink
                            : AppColors.subtext,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Shared styled text field.
class AuthTextField extends StatefulWidget {
  final String label;
  final String hint;
  final IconData icon;
  final bool obscure;
  final TextInputAction textInputAction;
  final TextCapitalization capitalization;
  final TextEditingController? controller;

  const AuthTextField({
    super.key,
    required this.label,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.textInputAction = TextInputAction.next,
    this.capitalization = TextCapitalization.none,
    this.controller,
  });

  @override
  State<AuthTextField> createState() => _AuthTextFieldState();
}

class _AuthTextFieldState extends State<AuthTextField> {
  late bool _hidden = widget.obscure;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: widget.controller,
          obscureText: _hidden,
          textInputAction: widget.textInputAction,
          textCapitalization: widget.capitalization,
          decoration: InputDecoration(
            hintText: widget.hint,
            prefixIcon: Icon(widget.icon, size: 20),
            suffixIcon: widget.obscure
                ? IconButton(
                    onPressed: () =>
                        setState(() => _hidden = !_hidden),
                    icon: Icon(
                      _hidden
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 20,
                    ),
                  )
                : null,
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: AppColors.primary, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

/// Shared auth page scaffold: logo, card, footer link.
class AuthScaffold extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  final String footerText;
  final String footerAction;
  final VoidCallback onFooterTap;

  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    required this.footerText,
    required this.footerAction,
    required this.onFooterTap,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'MERIDiAN',
                    textAlign: TextAlign.center,
                    style:
                        Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2,
                            ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(
                          color: AppColors.ink,
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.subtext,
                          height: 1.5,
                        ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.08),
                          blurRadius: 30,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: child,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(footerText,
                          style: const TextStyle(
                              color: AppColors.subtext, fontSize: 14)),
                      TextButton(
                        onPressed: onFooterTap,
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: Size.zero,
                          tapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          foregroundColor: AppColors.primary,
                          textStyle: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14),
                        ),
                        child: Text(footerAction),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
