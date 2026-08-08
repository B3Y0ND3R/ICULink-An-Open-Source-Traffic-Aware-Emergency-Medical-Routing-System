import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';

/// Sign-in / sign-up screen offering both Email+Password and Phone+OTP.
/// On success, [AuthGate] (which wraps this screen) automatically advances
/// to registration-completion or the driver/staff home screen.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _AuthTab { email, phone }

class _LoginScreenState extends State<LoginScreen> {
  _AuthTab _tab = _AuthTab.email;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.xl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: AppSpacing.xl),
              _buildTabToggle(),
              const SizedBox(height: AppSpacing.lg),
              if (_tab == _AuthTab.email)
                const _EmailAuthForm()
              else
                const _PhoneAuthForm(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.accentSubtle,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: const Icon(
            Icons.monitor_heart_rounded,
            color: AppColors.accent,
            size: 24,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'ICULink',
          style: GoogleFonts.inter(
            color: AppColors.textPrimary,
            fontSize: 24,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Sign in to continue',
          style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 14),
        ),
      ],
    );
  }

  Widget _buildTabToggle() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(child: _tabButton('Email', _AuthTab.email)),
          Expanded(child: _tabButton('Phone', _AuthTab.phone)),
        ],
      ),
    );
  }

  Widget _tabButton(String label, _AuthTab tab) {
    final selected = _tab == tab;
    return GestureDetector(
      onTap: () => setState(() => _tab = tab),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.surfaceRaised : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: GoogleFonts.inter(
            color: selected ? AppColors.textPrimary : AppColors.textTertiary,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────
//  EMAIL / PASSWORD FORM
// ──────────────────────────────────────────────────────

class _EmailAuthForm extends StatefulWidget {
  const _EmailAuthForm();

  @override
  State<_EmailAuthForm> createState() => _EmailAuthFormState();
}

class _EmailAuthFormState extends State<_EmailAuthForm> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isRegistering = false;
  bool _isSubmitting = false;
  String? _errorText;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorText = 'Enter both email and password.');
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });
    try {
      if (_isRegistering) {
        await AuthService.instance.signUpWithEmail(email, password);
      } else {
        await AuthService.instance.signInWithEmail(email, password);
      }
      // AuthGate's authStateChanges() stream picks up the change automatically.
    } on FirebaseAuthException catch (e) {
      setState(() => _errorText = e.message ?? e.code);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AuthTextField(
          controller: _emailController,
          label: 'Email',
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: AppSpacing.sm),
        _AuthTextField(
          controller: _passwordController,
          label: 'Password',
          obscureText: true,
        ),
        if (_errorText != null) ...[
          const SizedBox(height: AppSpacing.sm),
          _ErrorText(_errorText!),
        ],
        const SizedBox(height: AppSpacing.md),
        _SubmitButton(
          label: _isRegistering ? 'Create Account' : 'Log In',
          isSubmitting: _isSubmitting,
          onTap: _submit,
        ),
        const SizedBox(height: AppSpacing.md),
        Center(
          child: TextButton(
            onPressed: () => setState(() => _isRegistering = !_isRegistering),
            child: Text(
              _isRegistering
                  ? 'Already have an account? Log in'
                  : "Don't have an account? Sign up",
            ),
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────
//  PHONE / OTP FORM
// ──────────────────────────────────────────────────────

class _PhoneAuthForm extends StatefulWidget {
  const _PhoneAuthForm();

  @override
  State<_PhoneAuthForm> createState() => _PhoneAuthFormState();
}

class _PhoneAuthFormState extends State<_PhoneAuthForm> {
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();
  String? _verificationId;
  bool _isSubmitting = false;
  String? _errorText;

  @override
  void dispose() {
    _phoneController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) {
      setState(() => _errorText = 'Enter a phone number.');
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });
    try {
      await AuthService.instance.startPhoneSignIn(
        phoneNumber: phone,
        onCodeSent: (verificationId) {
          if (!mounted) return;
          setState(() {
            _verificationId = verificationId;
            _isSubmitting = false;
          });
        },
        onError: (e) {
          if (!mounted) return;
          setState(() {
            _errorText = e.message ?? e.code;
            _isSubmitting = false;
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = 'Failed to send code: $e';
        _isSubmitting = false;
      });
    }
  }

  Future<void> _confirmCode() async {
    final code = _otpController.text.trim();
    final verificationId = _verificationId;
    if (verificationId == null || code.isEmpty) return;
    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });
    try {
      await AuthService.instance.confirmPhoneCode(
        verificationId: verificationId,
        smsCode: code,
      );
    } on FirebaseAuthException catch (e) {
      setState(() => _errorText = e.message ?? e.code);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final codeSent = _verificationId != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AuthTextField(
          controller: _phoneController,
          label: 'Phone number (e.g. +8801700000000)',
          keyboardType: TextInputType.phone,
          enabled: !codeSent,
        ),
        if (codeSent) ...[
          const SizedBox(height: AppSpacing.sm),
          _AuthTextField(
            controller: _otpController,
            label: '6-digit code',
            keyboardType: TextInputType.number,
          ),
        ],
        if (_errorText != null) ...[
          const SizedBox(height: AppSpacing.sm),
          _ErrorText(_errorText!),
        ],
        const SizedBox(height: AppSpacing.md),
        _SubmitButton(
          label: codeSent ? 'Verify Code' : 'Send Code',
          isSubmitting: _isSubmitting,
          onTap: codeSent ? _confirmCode : _sendCode,
        ),
        if (codeSent) ...[
          const SizedBox(height: AppSpacing.md),
          Center(
            child: TextButton(
              onPressed: () => setState(() {
                _verificationId = null;
                _otpController.clear();
              }),
              child: const Text('Use a different number'),
            ),
          ),
        ],
      ],
    );
  }
}

// ──────────────────────────────────────────────────────
//  SHARED WIDGETS
// ──────────────────────────────────────────────────────

class _AuthTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool obscureText;
  final bool enabled;
  final TextInputType keyboardType;

  const _AuthTextField({
    required this.controller,
    required this.label,
    this.obscureText = false,
    this.enabled = true,
    this.keyboardType = TextInputType.text,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      enabled: enabled,
      keyboardType: keyboardType,
      style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 15),
      decoration: InputDecoration(labelText: label),
    );
  }
}

class _ErrorText extends StatelessWidget {
  final String text;
  const _ErrorText(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: GoogleFonts.inter(color: AppColors.accent, fontSize: 13),
    );
  }
}

class _SubmitButton extends StatelessWidget {
  final String label;
  final bool isSubmitting;
  final VoidCallback onTap;

  const _SubmitButton({
    required this.label,
    required this.isSubmitting,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: isSubmitting ? null : onTap,
        child: isSubmitting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : Text(label),
      ),
    );
  }
}
