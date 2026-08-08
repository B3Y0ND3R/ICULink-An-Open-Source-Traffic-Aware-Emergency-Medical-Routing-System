import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';

/// One-time profile-completion screen shown to a driver right after their
/// first successful sign-in (email or phone), before they reach the
/// Ambulance Driver home screen. Collects a name and a vehicle/ambulance ID,
/// which becomes the driver's stable, human-readable identifier going
/// forward (replacing the old per-session timestamp-based ID).
class DriverRegisterScreen extends StatefulWidget {
  const DriverRegisterScreen({super.key});

  @override
  State<DriverRegisterScreen> createState() => _DriverRegisterScreenState();
}

class _DriverRegisterScreenState extends State<DriverRegisterScreen> {
  final _nameController = TextEditingController();
  final _vehicleController = TextEditingController();
  bool _isSubmitting = false;
  String? _errorText;

  @override
  void dispose() {
    _nameController.dispose();
    _vehicleController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    final vehicleId = _vehicleController.text.trim();
    if (name.isEmpty || vehicleId.isEmpty) {
      setState(() => _errorText = 'Enter both your name and vehicle ID.');
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });
    try {
      await AuthService.instance.createDriverProfile(
        name: name,
        vehicleId: vehicleId,
      );
      // AuthGate's profile stream has already swapped its body to
      // AmbulanceScreen by now, but this screen was reached via
      // Navigator.push from RoleSelectionScreen, so it's still sitting on
      // top of that swapped-in screen in the stack. Pop back to root to
      // reveal it.
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = 'Could not save profile: $e');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

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
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.accentSubtle,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: const Icon(
                  Icons.emergency_share_rounded,
                  color: AppColors.accent,
                  size: 24,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Driver details',
                style: GoogleFonts.inter(
                  color: AppColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'One-time setup before your first dispatch',
                style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: AppSpacing.xl),
              TextField(
                controller: _nameController,
                style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 15),
                decoration: const InputDecoration(labelText: 'Your name'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _vehicleController,
                style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 15),
                decoration: const InputDecoration(
                  labelText: 'Ambulance / vehicle ID (e.g. DHAKA-METRO-3011)',
                ),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _errorText!,
                  style: GoogleFonts.inter(color: AppColors.accent, fontSize: 13),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _submit,
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
