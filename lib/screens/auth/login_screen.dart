import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../home/home_screen.dart';
import 'auth_widgets.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  AuthRole _role = AuthRole.student;

  String get _idLabel =>
      _role == AuthRole.faculty ? 'EMP ID' : 'PRN';
  String get _idHint => _role == AuthRole.faculty
      ? 'e.g. EMP2024001'
      : 'e.g. 2024XXXX';

  void _login() {
    // UI-only: no checks, straight to home.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (_) => false,
    );
  }

  void _goRegister() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RegisterScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isModerator = _role == AuthRole.moderator;

    return AuthScaffold(
      title: 'Welcome back.',
      subtitle: 'Log in to your college\u2019s MERIDiAN workspace.',
      footerText: 'New here?',
      footerAction: 'Create account',
      onFooterTap: _goRegister,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RoleSegmentedControl(
            roles: const [
              AuthRole.student,
              AuthRole.faculty,
              AuthRole.moderator
            ],
            selected: _role,
            onSelected: (r) => setState(() => _role = r),
          ),
          const SizedBox(height: 18),
          const AuthTextField(
            label: 'College ID',
            hint: 'e.g. MERIDIAN-01',
            icon: Icons.apartment_rounded,
            capitalization: TextCapitalization.characters,
          ),
          const SizedBox(height: 14),
          if (isModerator) ...[
            const AuthTextField(
              label: 'Moderator Secret Key',
              hint: 'Enter moderator key',
              icon: Icons.key_rounded,
              textInputAction: TextInputAction.done,
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 18, color: AppColors.subtext),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Moderators are assigned by the college admin.',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.subtext),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            AuthTextField(
              label: _idLabel,
              hint: _idHint,
              icon: Icons.badge_outlined,
              capitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 14),
            const AuthTextField(
              label: 'Password',
              hint: 'Enter your password',
              icon: Icons.lock_outline_rounded,
              obscure: true,
              textInputAction: TextInputAction.done,
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _login,
            child: Text('Log in as ${_role.label}'),
          ),
        ],
      ),
    );
  }
}
