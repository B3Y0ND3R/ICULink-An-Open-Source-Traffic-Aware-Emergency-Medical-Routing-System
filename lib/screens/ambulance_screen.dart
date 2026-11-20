import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';
import '../models/booking_model.dart';
import '../services/auth_service.dart';
import '../services/firebase_service.dart';
import '../services/routing_service.dart';
import '../theme/app_theme.dart';
import '../widgets/custom_map.dart';
import 'driver_history_screen.dart';

// ─────────────────────────────────────────────────────────────────
//  AMBULANCE SCREEN
//  Full ambulance driver UI with:
//    • GPS acquisition
//    • Routing algorithm execution
//    • Real-time coordinate upload every 5 seconds
//    • Full-screen navigation map
// ─────────────────────────────────────────────────────────────────

enum _AmbulanceState { idle, locating, routing, navigating, error }

class AmbulanceScreen extends StatefulWidget {
  const AmbulanceScreen({super.key});

  @override
  State<AmbulanceScreen> createState() => _AmbulanceScreenState();
}

class _AmbulanceScreenState extends State<AmbulanceScreen> {
  _AmbulanceState _appState = _AmbulanceState.idle;

  Position? _currentPosition;
  RoutingResult? _routingResult;
  BookingModel? _activeBooking;

  List<List<double>> _routePolyline = [];

  String _statusMessage = 'Ready to dispatch';
  String _errorMessage = '';

  StreamSubscription<Position>? _positionSub;
  bool _uploadingPosition = false;

  final _uuid = const Uuid();

  // Populated from the signed-in driver's profile in initState — stable
  // across sessions, unlike the old per-launch timestamp-based ID.
  String _ambulanceId = '';
  String _driverUid = '';

  late final Future<void> _profileReady;

  @override
  void initState() {
    super.initState();
    _profileReady = _loadDriverProfile();
  }

  Future<void> _loadDriverProfile() async {
    final profile = await AuthService.instance.fetchCurrentUserProfile();
    final uid = AuthService.instance.currentUser?.uid ?? '';
    if (!mounted) return;
    setState(() {
      _driverUid = uid;
      _ambulanceId = profile?.vehicleId ?? uid;
    });
    // A freshly opened driver screen has no active trip, so close any trip
    // a previous crashed/killed session left EN_ROUTE.
    if (uid.isNotEmpty) {
      await FirebaseService.instance.cancelOrphanedBookingsForDriver(uid);
    }
  }

  Future<void> _confirmSignOut() async {
    if (_appState == _AmbulanceState.navigating) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cancel or complete your active dispatch before signing out.'),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You\'ll need to log in again to dispatch.'),
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
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  //  MAIN SOS DISPATCH FLOW
  // ─────────────────────────────────────────────

  Future<void> _onSosPressed() async {
    setState(() {
      _appState = _AmbulanceState.locating;
      _statusMessage = 'Acquiring GPS signal…';
      _errorMessage = '';
    });

    try {
      // The profile supplies the driver UID / vehicle ID stamped on the
      // booking — make sure it has finished loading before dispatching.
      await _profileReady;
      if (!mounted) return;
      if (_driverUid.isEmpty) {
        _setError('Not signed in. Please log in again.');
        return;
      }

      // Step 1: Get current GPS position
      final position = await _acquireGpsPosition();
      if (position == null || !mounted) return;

      setState(() {
        _currentPosition = position;
        _appState = _AmbulanceState.routing;
        _statusMessage = 'Running routing algorithm…';
      });

      // Step 2: Run scoring algorithm
      final result = await RoutingService.instance.findOptimalHospital(
        ambulanceLat: position.latitude,
        ambulanceLng: position.longitude,
      );
      if (!mounted) return;

      if (result == null) {
        _setError('No hospitals with available ICU beds found.');
        return;
      }

      setState(() {
        _routingResult = result;
        _statusMessage = 'Fetching route to ${result.hospital.name}…';
      });

      // Step 3: Fetch polyline route
      final polyline = await RoutingService.instance.fetchRoutePolyline(
        fromLat: position.latitude,
        fromLng: position.longitude,
        toLat: result.hospital.lat,
        toLng: result.hospital.lng,
      );
      if (!mounted) return;

      // Step 4: Commit booking to Firestore
      final booking = BookingModel(
        id: _uuid.v4(),
        ambulanceId: _ambulanceId,
        driverUid: _driverUid,
        currentLat: position.latitude,
        currentLng: position.longitude,
        targetHospitalId: result.hospital.id,
        targetHospitalName: result.hospital.name,
        status: BookingStatus.enRoute,
        createdAt: DateTime.now(),
      );

      await FirebaseService.instance.createBooking(booking);
      if (!mounted) return;

      // Step 5: Start live location upload
      _startLocationTracking(booking.id);

      setState(() {
        _activeBooking = booking;
        _routePolyline = polyline;
        _appState = _AmbulanceState.navigating;
        _statusMessage = 'Navigating to ${result.hospital.name}';
      });
    } catch (e) {
      debugPrint('SOS dispatch failed: $e');
      _setError('Dispatch failed — check your connection and try again.');
    }
  }

  // ─────────────────────────────────────────────
  //  GPS HELPERS
  // ─────────────────────────────────────────────

  Future<Position?> _acquireGpsPosition() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _setError('Location services are disabled. Please enable GPS.');
        return null;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _setError('Location permission denied.');
          return null;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _setError('Location permission permanently denied.');
        return null;
      }

      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 15));
    } catch (e) {
      // Never invent a position: routing an ambulance from a made-up
      // location is worse than not routing. A recent real fix is acceptable;
      // otherwise tell the driver.
      debugPrint('GPS fix failed: $e');
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) return last;
      } catch (_) {}
      _setError('Could not get a GPS fix. Move to an open area and retry.');
      return null;
    }
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _appState = _AmbulanceState.error;
      _errorMessage = message;
    });
  }

  // ─────────────────────────────────────────────
  //  LIVE LOCATION TRACKING – pushes to Firestore about every 5s
  //
  //  Uses a position stream (with an Android foreground service) rather than
  //  a Dart timer, so updates keep flowing when the driver switches to a
  //  navigation/phone app and the hospital keeps seeing the live position.
  // ─────────────────────────────────────────────

  LocationSettings _trackingSettings() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'ICULink dispatch active',
          notificationText: 'Sharing live location with the receiving hospital',
          enableWakeLock: true,
        ),
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.high);
  }

  void _startLocationTracking(String bookingId) {
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: _trackingSettings(),
    ).listen(
      (position) async {
        if (mounted) {
          setState(() {
            _currentPosition = position;
            _activeBooking = _activeBooking?.copyWith(
              currentLat: position.latitude,
              currentLng: position.longitude,
            );
          });
        }
        // Skip (rather than queue) uploads while one is still in flight.
        if (_uploadingPosition) return;
        _uploadingPosition = true;
        try {
          await FirebaseService.instance.updateBookingCoordinates(
            bookingId,
            position.latitude,
            position.longitude,
          );
        } catch (e) {
          debugPrint('Location upload failed: $e'); // retry on next fix
        } finally {
          _uploadingPosition = false;
        }
      },
      onError: (Object e) => debugPrint('Position stream error: $e'),
    );
  }

  void _stopLocationTracking() {
    _positionSub?.cancel();
    _positionSub = null;
  }

  // ─────────────────────────────────────────────
  //  CANCEL BOOKING
  // ─────────────────────────────────────────────

  /// Writes the final status first; only if that succeeds is tracking
  /// stopped, so a failed write can't leave the hospital alarm stuck on an
  /// ambulance the driver believes is finished. Returns whether it worked.
  Future<bool> _finishBooking(BookingStatus status) async {
    final booking = _activeBooking;
    if (booking != null) {
      try {
        await FirebaseService.instance.updateBookingStatus(booking.id, status);
      } catch (e) {
        debugPrint('Booking status update failed: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not update the dispatch — check your connection and try again.'),
            ),
          );
        }
        return false;
      }
    }
    _stopLocationTracking();
    return true;
  }

  void _resetToIdle() {
    setState(() {
      _appState = _AmbulanceState.idle;
      _activeBooking = null;
      _routingResult = null;
      _routePolyline = [];
      _statusMessage = 'Ready to dispatch';
    });
  }

  Future<void> _cancelBooking() async {
    if (!await _finishBooking(BookingStatus.cancelled)) return;
    if (mounted) _resetToIdle();
  }

  // ─────────────────────────────────────────────
  //  MARK AS ARRIVED
  // ─────────────────────────────────────────────

  Future<void> _markArrived() async {
    if (!await _finishBooking(BookingStatus.arrived)) return;
    if (mounted) _showArrivalDialog();
  }

  void _showArrivalDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 48),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Arrived',
              style: GoogleFonts.inter(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Hospital has been notified.',
              style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _resetToIdle();
                },
                child: const Text('New Mission'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: _appState == _AmbulanceState.navigating
          ? _buildNavigationView()
          : _buildIdleView(),
    );
  }

  // ─── IDLE / LOCATING / ROUTING / ERROR VIEW ───

  Widget _buildIdleView() {
    return Stack(
      children: [
        // Background map (Dhaka center when idle)
        if (_currentPosition != null)
          CustomMap(
            initialCenter: LatLng(
              _currentPosition!.latitude,
              _currentPosition!.longitude,
            ),
            ambulancePosition: LatLng(
              _currentPosition!.latitude,
              _currentPosition!.longitude,
            ),
            initialZoom: 14,
          )
        else
          const CustomMap(
            initialCenter: LatLng(23.8103, 90.4125),
            initialZoom: 12,
          ),

        // ── Dark overlay — functional (keeps controls legible over the map)
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.background.withValues(alpha: 0.35),
                AppColors.background.withValues(alpha: 0.9),
              ],
            ),
          ),
        ),

        // ── Content
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Column(
              children: [
                const SizedBox(height: AppSpacing.sm),
                _buildTopBar(),
                const Spacer(),
                _buildStatusCard(),
                const SizedBox(height: AppSpacing.xl),
                _buildSosButton(),
                const SizedBox(height: AppSpacing.xxl),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        IconButton(
          onPressed: _confirmSignOut,
          icon: const Icon(Icons.logout_rounded, color: AppColors.textPrimary),
        ),
        const SizedBox(width: AppSpacing.xs),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Ambulance Driver',
                style: GoogleFonts.inter(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                _ambulanceId,
                style: GoogleFonts.inter(color: AppColors.textTertiary, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const Spacer(),
        Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(color: AppColors.success, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          'Online',
          style: GoogleFonts.inter(
            color: AppColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DriverHistoryScreen(driverUid: _driverUid),
              ),
            );
          },
          icon: const Icon(Icons.history_rounded, color: AppColors.textSecondary, size: 20),
        ),
      ],
    );
  }

  Widget _buildStatusCard() {
    IconData statusIcon = Icons.info_outline_rounded;
    Color iconColor = AppColors.textSecondary;
    Color textColor = AppColors.textSecondary;

    if (_appState == _AmbulanceState.locating || _appState == _AmbulanceState.routing) {
      statusIcon = Icons.sync_rounded;
      iconColor = AppColors.textPrimary;
    } else if (_appState == _AmbulanceState.error) {
      statusIcon = Icons.warning_rounded;
      iconColor = AppColors.accent;
      textColor = AppColors.accent;
    }

    return Container(
      width: double.infinity,
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
              if (_appState == _AmbulanceState.locating ||
                  _appState == _AmbulanceState.routing)
                _SpinningIcon(icon: statusIcon, color: iconColor)
              else
                Icon(statusIcon, color: iconColor, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  _appState == _AmbulanceState.error ? _errorMessage : _statusMessage,
                  style: GoogleFonts.inter(color: textColor, fontSize: 14),
                ),
              ),
            ],
          ),
          if (_currentPosition != null) ...[
            const SizedBox(height: AppSpacing.sm),
            const Divider(),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                _CoordChip(
                  label: 'LAT',
                  value: _currentPosition!.latitude.toStringAsFixed(4),
                ),
                _CoordChip(
                  label: 'LNG',
                  value: _currentPosition!.longitude.toStringAsFixed(4),
                ),
                _CoordChip(
                  label: 'ACC',
                  value: '±${_currentPosition!.accuracy.toStringAsFixed(0)}m',
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSosButton() {
    final bool isLoading = _appState == _AmbulanceState.locating ||
        _appState == _AmbulanceState.routing;

    return GestureDetector(
      onTap: isLoading ? null : _onSosPressed,
      child: Container(
        width: 176,
        height: 176,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isLoading ? AppColors.surfaceRaised : AppColors.accent,
          boxShadow: isLoading ? null : AppShadow.card,
        ),
        child: isLoading
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(
                    color: AppColors.textPrimary,
                    strokeWidth: 2.5,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Processing…',
                    style: GoogleFonts.inter(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.emergency_share_rounded, color: Colors.white, size: 40),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'SOS',
                    style: GoogleFonts.inter(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Find optimal ICU',
                    style: GoogleFonts.inter(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  // ─── NAVIGATION VIEW (full screen map) ───

  Widget _buildNavigationView() {
    final hospital = _routingResult?.hospital;
    final ambulanceLat = _activeBooking?.currentLat ??
        _currentPosition?.latitude ??
        23.8103;
    final ambulanceLng = _activeBooking?.currentLng ??
        _currentPosition?.longitude ??
        90.4125;

    return Stack(
      children: [
        // Full-screen map. Keyed on the active booking's id so a fresh
        // dispatch always gets a brand-new map widget/state instead of
        // reusing the idle screen's — without this, Flutter reconciles
        // both views' CustomMap as the same element (same type, same Stack
        // position), so initState (and initialCenter) only ever fires once
        // ever, and any pan/follow-mode state left over from idly browsing
        // the map before pressing SOS carries straight into navigation,
        // sometimes leaving the camera far from the driver's real position.
        CustomMap(
          key: ValueKey('nav_${_activeBooking?.id}'),
          initialCenter: LatLng(ambulanceLat, ambulanceLng),
          ambulancePosition: LatLng(ambulanceLat, ambulanceLng),
          destinationHospital: hospital,
          routePolyline: _routePolyline,
          initialZoom: 14,
        ),

        // ── Top Info Panel
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: [
                _buildNavigationHeader(hospital),
                const Spacer(),
                _buildNavigationBottomBar(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNavigationHeader(dynamic hospital) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadow.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(color: AppColors.success, shape: BoxShape.circle),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                'EN ROUTE',
                style: GoogleFonts.inter(
                  color: AppColors.success,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
              const Spacer(),
              if (_routingResult?.usedFallback == true)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceRaised,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Text(
                    'FALLBACK ROUTE',
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
          const SizedBox(height: AppSpacing.sm),
          Text(
            hospital?.name ?? 'Unknown Hospital',
            style: GoogleFonts.inter(
              color: AppColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _InfoPill(
                icon: Icons.timer_outlined,
                label: '${_routingResult?.durationMinutes.toStringAsFixed(0) ?? "--"} min',
              ),
              _InfoPill(
                icon: Icons.bed_outlined,
                label: '${hospital?.vacantIcuBeds ?? "--"} ICU beds',
              ),
              _InfoPill(
                icon: Icons.air,
                label: '${hospital?.availableVentilators ?? "--"} vents',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationBottomBar() {
    return Row(
      children: [
        Expanded(
          child: _ActionButton(
            label: 'Cancel',
            icon: Icons.close_rounded,
            filled: false,
            onTap: _cancelBooking,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          flex: 2,
          child: _ActionButton(
            label: 'Mark Arrived',
            icon: Icons.check_rounded,
            filled: true,
            onTap: _markArrived,
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────
//  REUSABLE SMALL WIDGETS
// ──────────────────────────────────────────────────────

class _CoordChip extends StatelessWidget {
  final String label;
  final String value;

  const _CoordChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              color: AppColors.textTertiary,
              fontSize: 9,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          Text(
            value,
            style: GoogleFonts.inter(
              color: AppColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppColors.textSecondary, size: 14),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.inter(
              color: AppColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool filled;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.filled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm + 6),
        decoration: BoxDecoration(
          color: filled ? AppColors.success : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: filled ? null : Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: filled ? Colors.black : AppColors.textPrimary, size: 18),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: GoogleFonts.inter(
                color: filled ? Colors.black : AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpinningIcon extends StatefulWidget {
  final IconData icon;
  final Color color;

  const _SpinningIcon({required this.icon, required this.color});

  @override
  State<_SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<_SpinningIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _c,
      child: Icon(widget.icon, color: widget.color, size: 18),
    );
  }
}
