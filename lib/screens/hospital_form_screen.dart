import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';
import '../models/hospital_model.dart';
import '../services/auth_service.dart';
import '../services/firebase_service.dart';
import '../theme/app_theme.dart';

/// Self-service hospital form, shared by two flows:
///
/// - **Add** ([existing] is null): creates a brand new hospital, with the
///   creator automatically set as its sole initial owner (see
///   firestore.rules — creation is only allowed when the creator names
///   themselves as the owner). Includes an initial-resources section since
///   there's no dashboard yet to set those from.
/// - **Edit** ([existing] is provided): updates an existing hospital's
///   name/contact/location. Resource counts stay on the dashboard's
///   dedicated +/- controls, so this mode hides that section entirely.
class HospitalFormScreen extends StatefulWidget {
  final HospitalModel? existing;
  const HospitalFormScreen({super.key, this.existing});

  @override
  State<HospitalFormScreen> createState() => _HospitalFormScreenState();
}

class _HospitalFormScreenState extends State<HospitalFormScreen> {
  late final _nameController = TextEditingController(text: widget.existing?.name ?? '');
  late final _contactController = TextEditingController(text: widget.existing?.contact ?? '');
  final _icuBedsController = TextEditingController(text: '0');
  final _ventilatorsController = TextEditingController(text: '0');
  late final _latController =
      TextEditingController(text: widget.existing?.lat.toStringAsFixed(6) ?? '');
  late final _lngController =
      TextEditingController(text: widget.existing?.lng.toStringAsFixed(6) ?? '');

  final _uuid = const Uuid();

  bool get _isEditing => widget.existing != null;

  bool _isLocating = false;
  bool _isSubmitting = false;
  String? _errorText;

  @override
  void dispose() {
    _nameController.dispose();
    _contactController.dispose();
    _icuBedsController.dispose();
    _ventilatorsController.dispose();
    _latController.dispose();
    _lngController.dispose();
    super.dispose();
  }

  Future<void> _useCurrentLocation() async {
    setState(() {
      _isLocating = true;
      _errorText = null;
    });
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw 'Location services are disabled.';
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          throw 'Location permission denied.';
        }
      }
      if (permission == LocationPermission.deniedForever) {
        throw 'Location permission permanently denied.';
      }
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() {
        _latController.text = position.latitude.toStringAsFixed(6);
        _lngController.text = position.longitude.toStringAsFixed(6);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = 'Could not get location: $e');
    } finally {
      if (mounted) setState(() => _isLocating = false);
    }
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    final contact = _contactController.text.trim();
    final lat = double.tryParse(_latController.text.trim());
    final lng = double.tryParse(_lngController.text.trim());

    if (name.isEmpty) {
      setState(() => _errorText = 'Enter a hospital name.');
      return;
    }
    if (name.length > 120) {
      setState(() => _errorText = 'Hospital name is too long (max 120 characters).');
      return;
    }
    if (contact.length > 40) {
      setState(() => _errorText = 'Contact number is too long (max 40 characters).');
      return;
    }
    if (lat == null || lng == null) {
      setState(() => _errorText = 'Set a location — tap "Use my current location" or enter coordinates.');
      return;
    }
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      setState(() => _errorText = 'Coordinates out of range (latitude ±90, longitude ±180).');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });

    try {
      if (_isEditing) {
        await FirebaseService.instance.updateHospitalDetails(
          widget.existing!.id,
          name: name,
          contact: contact,
          lat: lat,
          lng: lng,
        );
      } else {
        final icuBeds = int.tryParse(_icuBedsController.text.trim());
        final ventilators = int.tryParse(_ventilatorsController.text.trim());
        if (icuBeds == null ||
            ventilators == null ||
            icuBeds < 0 ||
            ventilators < 0 ||
            icuBeds > 999 ||
            ventilators > 999) {
          setState(() {
            _errorText = 'ICU beds and ventilators must be whole numbers from 0 to 999.';
            _isSubmitting = false;
          });
          return;
        }
        final uid = AuthService.instance.currentUser?.uid;
        if (uid == null) {
          setState(() {
            _errorText = 'Not signed in.';
            _isSubmitting = false;
          });
          return;
        }
        final hospital = HospitalModel(
          id: _uuid.v4(),
          name: name,
          lat: lat,
          lng: lng,
          vacantIcuBeds: icuBeds,
          availableVentilators: ventilators,
          contact: contact,
          ownerUids: [uid],
        );
        await FirebaseService.instance.setHospital(hospital);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = '${_isEditing ? "Could not save changes" : "Could not create hospital"}: $e');
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
              Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    _isEditing ? 'Edit Hospital' : 'Add Hospital',
                    style: GoogleFonts.inter(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                _isEditing
                    ? 'Update this hospital\'s name, contact, or location.'
                    : 'You\'ll automatically become this hospital\'s manager.',
                style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: AppSpacing.xl),

              TextField(
                controller: _nameController,
                style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 15),
                decoration: const InputDecoration(labelText: 'Hospital name'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _contactController,
                keyboardType: TextInputType.phone,
                style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 15),
                decoration: const InputDecoration(labelText: 'Contact number (optional)'),
              ),

              const SizedBox(height: AppSpacing.lg),
              Text(
                'Location',
                style: GoogleFonts.inter(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _latController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 15),
                      decoration: const InputDecoration(labelText: 'Latitude'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _lngController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 15),
                      decoration: const InputDecoration(labelText: 'Longitude'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _isLocating ? null : _useCurrentLocation,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
                  ),
                  icon: _isLocating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.my_location_rounded, size: 18),
                  label: Text(_isLocating ? 'Locating…' : 'Use my current location'),
                ),
              ),

              if (!_isEditing) ...[
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'Initial resources',
                  style: GoogleFonts.inter(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _icuBedsController,
                        keyboardType: TextInputType.number,
                        style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 15),
                        decoration: const InputDecoration(labelText: 'ICU beds'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: TextField(
                        controller: _ventilatorsController,
                        keyboardType: TextInputType.number,
                        style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 15),
                        decoration: const InputDecoration(labelText: 'Ventilators'),
                      ),
                    ),
                  ],
                ),
              ],

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
                      : Text(_isEditing ? 'Save Changes' : 'Create Hospital'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
