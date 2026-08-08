import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import '../models/booking_model.dart';
import '../models/hospital_model.dart';
import '../services/auth_service.dart';
import '../services/firebase_service.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/custom_map.dart';
import 'hospital_form_screen.dart';
import 'hospital_history_screen.dart';

// ─────────────────────────────────────────────────────────────────
//  HOSPITAL SCREEN
//  Tablet/Web ER Dashboard with:
//    • Real-time ICU/ventilator counter grid
//    • Firestore stream listener for incoming bookings
//    • Full-screen flashing alarm overlay with audio
//    • Live ambulance map during active alert
// ─────────────────────────────────────────────────────────────────

class HospitalScreen extends StatefulWidget {
  const HospitalScreen({super.key});

  @override
  State<HospitalScreen> createState() => _HospitalScreenState();
}

class _HospitalScreenState extends State<HospitalScreen>
    with TickerProviderStateMixin {
  // ── Selected hospital (staff picks from list)
  HospitalModel? _selectedHospital;
  List<HospitalModel> _allHospitals = [];
  List<HospitalModel> _archivedHospitals = [];
  List<BookingModel> _activeBookings = [];
  BookingModel? _selectedBooking;
  bool _alarmActive = false;
  bool _hospitalsLoaded = false;

  StreamSubscription<List<HospitalModel>>? _hospitalSub;
  StreamSubscription<List<BookingModel>>? _bookingSub;

  late AnimationController _flashController;
  late Animation<double> _flashAnimation;

  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _flashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..repeat(reverse: true);
    _flashAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(_flashController);

    // Register this device's FCM token so the Cloud Function that pushes
    // "incoming ambulance" alerts (functions/index.js) can reach it. Safe
    // to call every time this screen is entered — arrayUnion is idempotent.
    NotificationService.instance.registerTokenForCurrentUser();

    _hospitalSub = FirebaseService.instance.streamAllHospitals().listen((list) {
      if (!mounted) return;
      final myUid = AuthService.instance.currentUser?.uid;
      final mine = list.where((h) => h.ownerUids.contains(myUid));
      final myHospitals = mine.where((h) => !h.archived).toList();
      final myArchived = mine.where((h) => h.archived).toList();
      setState(() {
        _allHospitals = myHospitals;
        _archivedHospitals = myArchived;
        _hospitalsLoaded = true;
        if (_selectedHospital != null) {
          final stillActive = myHospitals
              .where((h) => h.id == _selectedHospital!.id)
              .firstOrNull;
          if (stillActive != null) {
            // Keep the dashboard's local copy fresh (e.g. edited name).
            _selectedHospital = stillActive;
          } else {
            // Archived (or otherwise removed) from under the current view —
            // fall back to the selector rather than showing a stale/ghost
            // dashboard.
            _bookingSub?.cancel();
            _stopAlarm();
            _selectedHospital = null;
          }
        }
      });
    });
  }

  void _selectHospital(HospitalModel h) {
    _bookingSub?.cancel();
    setState(() {
      _selectedHospital = h;
      _activeBookings = [];
      _selectedBooking = null;
      _alarmActive = false;
    });
    _bookingSub = FirebaseService.instance
        .streamActiveBookingsForHospital(h.id)
        .listen((bookings) {
      if (!mounted) return;
      final hadAlarm = _alarmActive;
      final hasBookings = bookings.isNotEmpty;
      setState(() {
        _activeBookings = bookings;
        _alarmActive = hasBookings;
        // Keep the selected booking pointed at its latest coordinates, or
        // fall back to the first booking if the selection is stale/unset.
        final stillActive = _selectedBooking == null
            ? null
            : bookings.where((b) => b.id == _selectedBooking!.id).firstOrNull;
        _selectedBooking = stillActive ?? (hasBookings ? bookings.first : null);
      });
      if (hasBookings && !hadAlarm) _triggerAlarm();
      if (!hasBookings && hadAlarm) _stopAlarm();
    });
  }

  Future<void> _triggerAlarm() async {
    _flashController.repeat(reverse: true);
    try {
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.play(AssetSource('audio/alarm.mp3'));
    } catch (_) {
      // Audio may not be available in all environments
    }
  }

  Future<void> _stopAlarm() async {
    _flashController.stop();
    await _audioPlayer.stop();
  }

  Future<void> _updateField(String field, int delta) async {
    final hospital = _selectedHospital;
    if (hospital == null) return;

    // Optimistic local update so the tap feels instant instead of
    // waiting on the Firestore round-trip.
    final currentValue = field == 'vacant_icu_beds'
        ? hospital.vacantIcuBeds
        : hospital.availableVentilators;
    final optimisticValue = (currentValue + delta).clamp(0, 999);

    setState(() {
      _selectedHospital = field == 'vacant_icu_beds'
          ? hospital.copyWith(vacantIcuBeds: optimisticValue)
          : hospital.copyWith(availableVentilators: optimisticValue);
    });

    try {
      await FirebaseService.instance.updateHospitalField(
        hospital.id,
        field,
        delta,
      );
    } catch (e) {
      if (!mounted) return;
      // Roll back and surface the failure — silent no-ops are what made
      // the buttons feel broken in the first place.
      setState(() => _selectedHospital = hospital);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Update failed: $e')),
      );
    }
  }

  @override
  void dispose() {
    _hospitalSub?.cancel();
    _bookingSub?.cancel();
    _flashController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _confirmSignOut() async {
    if (_alarmActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('An ambulance is incoming — resolve it before signing out.'),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You\'ll need to log in again to manage this hospital.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await AuthService.instance.signOut();
      // AuthGate's authStateChanges() stream swaps back to LoginScreen automatically.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          SafeArea(
            child: _selectedHospital == null
                ? _buildHospitalSelector()
                : _buildDashboard(),
          ),
          if (_alarmActive) _buildAlarmOverlay(),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  HOSPITAL SELECTOR
  // ─────────────────────────────────────────────

  Widget _buildHospitalSelector() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: _confirmSignOut,
                icon: const Icon(Icons.logout_rounded, color: AppColors.textPrimary),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  'Select Your Hospital',
                  style: GoogleFonts.inter(
                    color: AppColors.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                onPressed: _openAddHospital,
                icon: const Icon(Icons.add_rounded, color: AppColors.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Choose the facility you are managing',
            style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 14),
          ),
          const SizedBox(height: AppSpacing.lg),
          Expanded(
            child: !_hospitalsLoaded
                ? const Center(child: CircularProgressIndicator())
                : _allHospitals.isEmpty && _archivedHospitals.isEmpty
                    ? _buildNoHospitalsAssigned()
                    : _buildHospitalLists(),
          ),
        ],
      ),
    );
  }

  Widget _buildHospitalLists() {
    return ListView(
      children: [
        if (_allHospitals.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: Text(
              'No active hospitals — all of yours are archived below.',
              style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 13),
            ),
          )
        else
          ..._allHospitals.map(
            (h) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _HospitalListTile(
                hospital: h,
                onTap: () => _selectHospital(h),
              ),
            ),
          ),
        if (_archivedHospitals.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            'Archived (${_archivedHospitals.length})',
            style: GoogleFonts.inter(
              color: AppColors.textTertiary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          ..._archivedHospitals.map(
            (h) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _ArchivedHospitalTile(
                hospital: h,
                onRestore: () => _unarchive(h),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildNoHospitalsAssigned() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.local_hospital_outlined, color: AppColors.textTertiary, size: 40),
            const SizedBox(height: AppSpacing.md),
            Text(
              'No hospital assigned yet',
              style: GoogleFonts.inter(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Add a hospital yourself, or ask an administrator to link '
              'your account to an existing one.',
              style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 13, height: 1.4),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            OutlinedButton.icon(
              onPressed: _openAddHospital,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                side: const BorderSide(color: AppColors.border),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
              ),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add Hospital'),
            ),
          ],
        ),
      ),
    );
  }

  void _openAddHospital() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HospitalFormScreen()),
    );
  }

  void _openEditHospital(HospitalModel h) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => HospitalFormScreen(existing: h)),
    );
  }

  Future<void> _confirmArchive(HospitalModel h) async {
    if (_alarmActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('An ambulance is incoming — resolve it before archiving.'),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Archive this hospital?'),
        content: Text(
          '${h.name} will be hidden from your selector and from driver '
          'routing. Its booking history is kept, and you can restore it '
          'later from the Archived section.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await FirebaseService.instance.setHospitalArchived(h.id, true);
      if (!mounted) return;
      _bookingSub?.cancel();
      _stopAlarm();
      setState(() => _selectedHospital = null);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not archive: $e')),
      );
    }
  }

  Future<void> _unarchive(HospitalModel h) async {
    try {
      await FirebaseService.instance.setHospitalArchived(h.id, false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not restore: $e')),
      );
    }
  }

  // ─────────────────────────────────────────────
  //  MAIN DASHBOARD
  // ─────────────────────────────────────────────

  Widget _buildDashboard() {
    final h = _selectedHospital!;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top bar
          Row(
            children: [
              IconButton(
                onPressed: () {
                  _bookingSub?.cancel();
                  _stopAlarm();
                  setState(() => _selectedHospital = null);
                },
                icon: const Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      h.name,
                      style: GoogleFonts.inter(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      h.contact,
                      style: GoogleFonts.inter(color: AppColors.textTertiary, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              _StatusBadge(active: _alarmActive, count: _activeBookings.length),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => HospitalHistoryScreen(
                        hospitalId: h.id,
                        hospitalName: h.name,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.history_rounded, color: AppColors.textSecondary, size: 20),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded, color: AppColors.textSecondary, size: 20),
                color: AppColors.surfaceRaised,
                onSelected: (value) {
                  switch (value) {
                    case 'edit':
                      _openEditHospital(h);
                      break;
                    case 'archive':
                      _confirmArchive(h);
                      break;
                    case 'signout':
                      _confirmSignOut();
                      break;
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: Text('Edit Hospital'),
                  ),
                  const PopupMenuItem(
                    value: 'archive',
                    child: Text('Archive Hospital'),
                  ),
                  const PopupMenuItem(
                    value: 'signout',
                    child: Text('Sign Out'),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: AppSpacing.lg),

          // Resource grid
          Row(
            children: [
              Expanded(
                child: _ResourceCard(
                  label: 'ICU Beds',
                  value: h.vacantIcuBeds,
                  icon: Icons.bed_rounded,
                  onIncrement: () => _updateField('vacant_icu_beds', 1),
                  onDecrement: () => _updateField('vacant_icu_beds', -1),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _ResourceCard(
                  label: 'Ventilators',
                  value: h.availableVentilators,
                  icon: Icons.air_rounded,
                  onIncrement: () => _updateField('available_ventilators', 1),
                  onDecrement: () => _updateField('available_ventilators', -1),
                ),
              ),
            ],
          ),

          const SizedBox(height: AppSpacing.lg),

          Text(
            'Incoming ambulances (${_activeBookings.length})',
            style: GoogleFonts.inter(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),

          const SizedBox(height: AppSpacing.sm),

          if (_activeBookings.isEmpty)
            Expanded(child: _buildIdleState())
          else
            Expanded(child: _buildActiveBookingView()),
        ],
      ),
    );
  }

  Widget _buildIdleState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.local_hospital_outlined, color: AppColors.textTertiary, size: 40),
          const SizedBox(height: AppSpacing.md),
          Text(
            'No active emergencies',
            style: GoogleFonts.inter(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Monitoring in real time',
            style: GoogleFonts.inter(color: AppColors.textTertiary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveBookingView() {
    // Fall back to the first booking if nothing is explicitly selected yet
    // (e.g. right after the stream's first emission).
    final focused = _selectedBooking ?? _activeBookings.first;

    return Column(
      children: [
        // Scrollable list of every active booking — tap one to focus the
        // shared map on it. Flex-shared with the map below so it can never
        // overflow regardless of screen size or how many bookings there
        // are; it just gets a proportional share of whatever space exists.
        Flexible(
          flex: 2,
          child: ListView.separated(
            itemCount: _activeBookings.length,
            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
            itemBuilder: (_, i) {
              final booking = _activeBookings[i];
              return _BookingInfoCard(
                booking: booking,
                selected: booking.id == focused.id,
                onTap: () => setState(() => _selectedBooking = booking),
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        // Live map — shows every active booking as a marker; the selected
        // one drives the camera position.
        Expanded(
          flex: 5,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: CustomMap(
              initialCenter: LatLng(focused.currentLat, focused.currentLng),
              ambulancePosition: LatLng(focused.currentLat, focused.currentLng),
              destinationHospital: _selectedHospital,
              activeBookings: _activeBookings,
              initialZoom: 13,
            ),
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────
  //  ALARM OVERLAY
  //  Deliberately kept high-intensity — this is a real safety-critical
  //  alert (an ambulance is incoming), not decoration.
  // ─────────────────────────────────────────────

  Widget _buildAlarmOverlay() {
    return AnimatedBuilder(
      animation: _flashAnimation,
      builder: (_, __) {
        return IgnorePointer(
          ignoring: false,
          child: GestureDetector(
            onTap: () {}, // absorb taps on overlay edges
            child: Container(
              color: Color.lerp(
                AppColors.alarm.withOpacity(0.0),
                AppColors.alarm.withOpacity(0.14),
                _flashAnimation.value,
              ),
              child: SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    margin: const EdgeInsets.all(AppSpacing.md),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.md,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.alarm,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.emergency_share_rounded, color: Colors.white, size: 28)
                            .animate(onPlay: (c) => c.repeat(reverse: true))
                            .scaleXY(end: 1.15, duration: 500.ms),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Incoming emergency',
                                style: GoogleFonts.inter(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                '${_activeBookings.length} ambulance(s) en route · prepare ICU',
                                style: GoogleFonts.inter(color: Colors.white.withOpacity(0.85), fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: _stopAlarm,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm + 2,
                              vertical: AppSpacing.xs + 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(AppRadius.sm),
                            ),
                            child: Text(
                              'Mute',
                              style: GoogleFonts.inter(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ──────────────────────────────────────────────────────
//  SUBWIDGETS
// ──────────────────────────────────────────────────────

class _HospitalListTile extends StatelessWidget {
  final HospitalModel hospital;
  final VoidCallback onTap;
  const _HospitalListTile({required this.hospital, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hasBeds = hospital.vacantIcuBeds > 0;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.surfaceRaised,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: const Icon(Icons.local_hospital_rounded, color: AppColors.textSecondary, size: 20),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hospital.name,
                    style: GoogleFonts.inter(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: hasBeds ? AppColors.success : AppColors.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${hospital.vacantIcuBeds} ICU beds',
                        style: GoogleFonts.inter(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        '${hospital.availableVentilators} vents',
                        style: GoogleFonts.inter(color: AppColors.textTertiary, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }
}

class _ArchivedHospitalTile extends StatelessWidget {
  final HospitalModel hospital;
  final VoidCallback onRestore;
  const _ArchivedHospitalTile({required this.hospital, required this.onRestore});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface.withOpacity(0.5),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              hospital.name,
              style: GoogleFonts.inter(
                color: AppColors.textTertiary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: onRestore,
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }
}

class _ResourceCard extends StatelessWidget {
  final String label;
  final int value;
  final IconData icon;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  const _ResourceCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.onIncrement,
    required this.onDecrement,
  });

  @override
  Widget build(BuildContext context) {
    final isEmpty = value == 0;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.textSecondary, size: 18),
              const SizedBox(width: AppSpacing.xs),
              Flexible(
                child: Text(
                  label,
                  style: GoogleFonts.inter(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _CountButton(
                  icon: Icons.remove_rounded,
                  onTap: value > 0 ? onDecrement : null,
                ),
                const SizedBox(width: AppSpacing.sm + 4),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$value',
                      style: GoogleFonts.inter(
                        color: isEmpty ? AppColors.accent : AppColors.textPrimary,
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        height: 1.0,
                      ),
                    ),
                    Text(
                      'available',
                      style: GoogleFonts.inter(color: AppColors.textTertiary, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(width: AppSpacing.sm + 4),
                _CountButton(
                  icon: Icons.add_rounded,
                  onTap: onIncrement,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CountButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _CountButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.border),
        ),
        child: Icon(
          icon,
          color: enabled ? AppColors.textPrimary : AppColors.textTertiary,
          size: 20,
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final bool active;
  final int count;
  const _StatusBadge({required this.active, required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 6),
      decoration: BoxDecoration(
        color: active ? AppColors.accentSubtle : AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: active ? AppColors.accent : AppColors.textTertiary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            active ? 'Alert ($count)' : 'Standby',
            style: GoogleFonts.inter(
              color: active ? AppColors.accent : AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _BookingInfoCard extends StatelessWidget {
  final BookingModel booking;
  final bool selected;
  final VoidCallback? onTap;
  const _BookingInfoCard({
    required this.booking,
    this.selected = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm + 4),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.emergency_share_rounded, color: AppColors.accent, size: 20),
            const SizedBox(width: AppSpacing.sm + 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    booking.ambulanceId,
                    style: GoogleFonts.inter(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    'Lat ${booking.currentLat.toStringAsFixed(4)}, Lng ${booking.currentLng.toStringAsFixed(4)}',
                    style: GoogleFonts.inter(color: AppColors.textTertiary, fontSize: 11),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs + 2, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.surfaceRaised,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'EN ROUTE',
                style: GoogleFonts.inter(
                  color: AppColors.textSecondary,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
