import 'package:flutter/material.dart';

import '../../services/api_client.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import '../home/home_screen.dart';
import 'auth_widgets.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  final AuthService auth;

  const LoginScreen({super.key, required this.auth});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _collegeCode = TextEditingController(text: 'MERIDIAN');
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  final _moderatorKey = TextEditingController();

  AuthRole _role = AuthRole.student;
  bool _submitting = false;

  @override
  void dispose() {
    _collegeCode.dispose();
    _identifier.dispose();
    _password.dispose();
    _moderatorKey.dispose();
    super.dispose();
  }

  String get _idLabel => _role == AuthRole.faculty ? 'EMP ID' : 'PRN';
  String get _idHint => _role == AuthRole.faculty
      ? 'e.g. EMP2024001'
      : 'e.g. 2024XXXX';

  bool get _isModerator => _role == AuthRole.moderator;

  String? _validate() {
    if (_collegeCode.text.trim().isEmpty) return 'Enter your college ID.';
    if (_isModerator) {
      if (_moderatorKey.text.trim().isEmpty) return 'Enter your moderator key.';
    } else {
      if (_identifier.text.trim().isEmpty) return 'Enter your $_idLabel.';
      if (_password.text.isEmpty) return 'Enter your password.';
    }
    return null;
  }

  Future<void> _submit() async {
    final problem = _validate();
    if (problem != null) {
      _showError(problem);
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);

    try {
      await widget.auth.login(
        collegeCode: _collegeCode.text.trim().toUpperCase(),
        identifier: _isModerator ? null : _identifier.text.trim(),
        password: _isModerator ? null : _password.text,
        moderatorKey: _isModerator ? _moderatorKey.text.trim() : null,
      );
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => HomeScreen(auth: widget.auth)),
        (_) => false,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _showError(e.message);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
  }

  void _goRegister() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RegisterScreen(auth: widget.auth),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
              AuthRole.moderator,
            ],
            selected: _role,
            onSelected: (r) => setState(() => _role = r),
          ),
          const SizedBox(height: 18),
          AuthTextField(
            label: 'College ID',
            hint: 'e.g. MERIDIAN',
            icon: Icons.apartment_rounded,
            controller: _collegeCode,
            capitalization: TextCapitalization.characters,
          ),
          const SizedBox(height: 14),
          if (_isModerator) ...[
            AuthTextField(
              label: 'Moderator Secret Key',
              hint: 'Enter moderator key',
              icon: Icons.key_rounded,
              controller: _moderatorKey,
              obscure: true,
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
                  Icon(
                    Icons.info_outline_rounded,
                    size: 18,
                    color: AppColors.subtext,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Moderators are assigned by the college admin.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.subtext,
                      ),
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
              controller: _identifier,
              capitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 14),
            // No separate Show/Hide control here: AuthTextField renders its own
            // eye toggle in the suffix when `obscure` is true. A second toggle
            // outside the field never worked, because AuthTextField keeps the
            // revealed state internally and does not re-read widget.obscure.
            AuthTextField(
              label: 'Password',
              hint: 'Enter your password',
              icon: Icons.lock_outline_rounded,
              controller: _password,
              obscure: true,
              textInputAction: TextInputAction.done,
            ),
          ],
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : Text('Log in as ${_role.label}'),
          ),
        ],
      ),
    );
  }
}
