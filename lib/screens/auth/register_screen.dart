import 'package:flutter/material.dart';

import 'auth_widgets.dart';
import '../home/home_screen.dart';
import 'login_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  AuthRole _role = AuthRole.student; // student | faculty only

  bool get _isFaculty => _role == AuthRole.faculty;

  void _register() {
    // UI-only: no checks, straight to home.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (_) => false,
    );
  }

  void _goLogin() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Create your account.',
      subtitle:
          'Use your college ID and ${_isFaculty ? 'EMP ID' : 'PRN'} — no phone number needed.',
      footerText: 'Already have an account?',
      footerAction: 'Log in',
      onFooterTap: _goLogin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RoleSegmentedControl(
            roles: const [AuthRole.student, AuthRole.faculty],
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
          Row(
            children: const [
              Expanded(
                child: AuthTextField(
                  label: 'First Name',
                  hint: 'Aarav',
                  icon: Icons.person_outline_rounded,
                  capitalization: TextCapitalization.words,
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: AuthTextField(
                  label: 'Surname',
                  hint: 'Sharma',
                  icon: Icons.person_outline_rounded,
                  capitalization: TextCapitalization.words,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          AuthTextField(
            label: _isFaculty ? 'EMP ID' : 'PRN',
            hint: _isFaculty ? 'e.g. EMP2024001' : 'e.g. 2024XXXX',
            icon: Icons.badge_outlined,
            capitalization: TextCapitalization.characters,
          ),
          const SizedBox(height: 14),
          const AuthTextField(
            label: 'Set Password',
            hint: 'Min. 8 characters',
            icon: Icons.lock_outline_rounded,
            obscure: true,
          ),
          const SizedBox(height: 14),
          const AuthTextField(
            label: 'Confirm Password',
            hint: 'Repeat your password',
            icon: Icons.lock_outline_rounded,
            obscure: true,
            textInputAction: TextInputAction.done,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _register,
            child: Text('Register as ${_role.label}'),
          ),
        ],
      ),
    );
  }
}
