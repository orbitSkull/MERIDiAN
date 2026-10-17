import 'package:flutter/material.dart';

import '../../services/api_client.dart';
import '../../services/auth_service.dart';
import '../home/home_screen.dart';
import 'auth_widgets.dart';
import 'login_screen.dart';

class RegisterScreen extends StatefulWidget {
  final AuthService auth;

  const RegisterScreen({super.key, required this.auth});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _collegeCode = TextEditingController(text: 'MERIDIAN');
  final _firstName = TextEditingController();
  final _surname = TextEditingController();
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();

  AuthRole _role = AuthRole.student; // student | faculty only
  bool _submitting = false;

  @override
  void dispose() {
    _collegeCode.dispose();
    _firstName.dispose();
    _surname.dispose();
    _identifier.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  bool get _isFaculty => _role == AuthRole.faculty;

  String get _idLabel => _isFaculty ? 'EMP ID' : 'PRN';
  String get _idHint => _isFaculty ? 'e.g. EMP2024001' : 'e.g. 2024XXXX';

  String? _validate() {
    if (_collegeCode.text.trim().isEmpty) return 'Enter your college ID.';
    if (_firstName.text.trim().isEmpty) return 'Enter your first name.';
    if (_surname.text.trim().isEmpty) return 'Enter your surname.';
    if (_identifier.text.trim().isEmpty) return 'Enter your $_idLabel.';
    if (_password.text.length < 8) return 'Password must be at least 8 characters.';
    if (_password.text != _confirmPassword.text) {
      return 'Passwords do not match.';
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
      await widget.auth.register(
        collegeCode: _collegeCode.text.trim().toUpperCase(),
        role: _isFaculty ? 'faculty' : 'student',
        firstName: _firstName.text.trim(),
        surname: _surname.text.trim(),
        prn: _isFaculty ? null : _identifier.text.trim(),
        empId: _isFaculty ? _identifier.text.trim() : null,
        password: _password.text,
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

  void _goLogin() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => LoginScreen(auth: widget.auth)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Create your account.',
      subtitle:
          'Use your college ID and ${_isFaculty ? 'EMP ID' : 'PRN'} \u2014 no phone number needed.',
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
          AuthTextField(
            label: 'College ID',
            hint: 'e.g. MERIDIAN',
            icon: Icons.apartment_rounded,
            controller: _collegeCode,
            capitalization: TextCapitalization.characters,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: AuthTextField(
                  label: 'First Name',
                  hint: 'Aarav',
                  icon: Icons.person_outline_rounded,
                  controller: _firstName,
                  capitalization: TextCapitalization.words,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AuthTextField(
                  label: 'Surname',
                  hint: 'Sharma',
                  icon: Icons.person_outline_rounded,
                  controller: _surname,
                  capitalization: TextCapitalization.words,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          AuthTextField(
            label: _idLabel,
            hint: _idHint,
            icon: Icons.badge_outlined,
            controller: _identifier,
            capitalization: TextCapitalization.characters,
          ),
          const SizedBox(height: 14),
          AuthTextField(
            label: 'Set Password',
            hint: 'Min. 8 characters',
            icon: Icons.lock_outline_rounded,
            controller: _password,
            obscure: true,
          ),
          const SizedBox(height: 14),
          AuthTextField(
            label: 'Confirm Password',
            hint: 'Repeat your password',
            icon: Icons.lock_outline_rounded,
            controller: _confirmPassword,
            obscure: true,
            textInputAction: TextInputAction.done,
          ),
          const SizedBox(height: 20),
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
                : Text('Register as ${_role.label}'),
          ),
        ],
      ),
    );
  }
}
