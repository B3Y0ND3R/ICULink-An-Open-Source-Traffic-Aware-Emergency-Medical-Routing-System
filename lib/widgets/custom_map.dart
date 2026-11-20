import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/hospital_model.dart';
import '../models/booking_model.dart';
import '../theme/app_theme.dart';

// ─────────────────────────────────────────────
//  CUSTOM MAP WIDGET
//  A reusable flutter_map component used both by the
//  ambulance navigation screen and the hospital ER panel.
// ─────────────────────────────────────────────

class CustomMap extends StatefulWidget {
  /// Center position for the map camera.
  final LatLng initialCenter;

  /// Optional ambulance marker position.
  final LatLng? ambulancePosition;

  /// Optional destination hospital.
  final HospitalModel? destinationHospital;

  /// All hospitals to show as markers on the map.
  final List<HospitalModel> hospitals;

  /// Active bookings (used to show additional ambulance positions
  /// on the hospital ER panel).
  final List<BookingModel> activeBookings;

  /// Polyline route points as [lat, lng] pairs (OpenRouteService geometry,
  /// or a straight line if that service is unavailable).
  final List<List<double>> routePolyline;

  /// Initial zoom level.
  final double initialZoom;

  /// Whether the map should show interactive hospital pins.
  final bool showHospitalPins;

  /// Callback when a hospital pin is tapped.
  final void Function(HospitalModel)? onHospitalTapped;

  const CustomMap({
    super.key,
    required this.initialCenter,
    this.ambulancePosition,
    this.destinationHospital,
    this.hospitals = const [],
    this.activeBookings = const [],
    this.routePolyline = const [],
    this.initialZoom = 13.0,
    this.showHospitalPins = false,
    this.onHospitalTapped,
  });

  @override
  State<CustomMap> createState() => _CustomMapState();
}

class _CustomMapState extends State<CustomMap> {
  late MapController _mapController;
  StreamSubscription<MapEvent>? _mapEventSub;

  // Auto-follows the live position by default. The moment the user touches
  // the map (drag, pinch, scroll-zoom, double-tap...) this flips off so
  // their view stops getting yanked back every time a new GPS fix arrives
  // — that was the actual bug: the camera used to force-recenter on every
  // position update regardless of what the user was doing. A small
  // "recenter" button lets them opt back in deliberately.
  bool _followMode = true;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _mapEventSub = _mapController.mapEventStream.listen((event) {
      // Only genuine user gestures end follow mode. Programmatic moves and
      // the size-change event flutter_map emits after the first layout (and
      // on every resize) must not — otherwise follow mode would switch off
      // as soon as the map first appears.
      final isUserGesture = event.source != MapEventSource.mapController &&
          event.source != MapEventSource.nonRotatedSizeChange &&
          event.source != MapEventSource.fitCamera &&
          event.source != MapEventSource.interactiveFlagsChanged &&
          event.source != MapEventSource.custom;
      if (isUserGesture && _followMode) {
        setState(() => _followMode = false);
      }
    });
  }

  @override
  void didUpdateWidget(covariant CustomMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only auto-follow the live position while the user hasn't taken
    // manual control of the camera.
    if (_followMode &&
        widget.ambulancePosition != null &&
        widget.ambulancePosition != oldWidget.ambulancePosition) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mapController.move(widget.ambulancePosition!, _mapController.camera.zoom);
      });
    }
  }

  void _recenter() {
    final position = widget.ambulancePosition;
    if (position == null) return;
    _mapController.move(position, _mapController.camera.zoom);
    setState(() => _followMode = true);
  }

  @override
  void dispose() {
    _mapEventSub?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  //  MARKER BUILDERS
  // ─────────────────────────────────────────────

  List<Marker> _buildHospitalMarkers() {
    return widget.hospitals.map((hospital) {
      final hasBedsAvailable = hospital.vacantIcuBeds > 0;
      final color = hasBedsAvailable ? AppColors.success : AppColors.accent;
      return Marker(
        point: LatLng(hospital.lat, hospital.lng),
        width: 40,
        height: 52,
        child: GestureDetector(
          onTap: () => widget.onHospitalTapped?.call(hospital),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.background, width: 2),
                ),
                child: Center(
                  child: Text(
                    '${hospital.vacantIcuBeds}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Container(
                width: 2,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }

  Marker _buildAmbulanceMarker(LatLng position, {String? label}) {
    return Marker(
      point: position,
      width: 88,
      height: 60,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.background, width: 2.5),
            ),
            child: const Icon(Icons.emergency, color: Colors.white, size: 18),
          ),
          if (label != null)
            Container(
              constraints: const BoxConstraints(maxWidth: 84),
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Marker? _buildDestinationMarker() {
    final h = widget.destinationHospital;
    if (h == null) return null;
    return Marker(
      point: LatLng(h.lat, h.lng),
      width: 56,
      height: 56,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.borderStrong, width: 2),
        ),
        child: const Icon(Icons.local_hospital_rounded, color: Colors.white, size: 24),
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  POLYLINE
  // ─────────────────────────────────────────────

  List<Polyline> _buildRoutePolyline() {
    final route = widget.routePolyline;
    if (route.length < 2) return <Polyline>[];
    final points = route.map((p) => LatLng(p[0], p[1])).toList();
    return [
      // Shadow polyline — subtle depth, not glow
      Polyline(
        points: points,
        strokeWidth: 7,
        color: Colors.black.withValues(alpha: 0.35),
      ),
      // Main route polyline
      Polyline(
        points: points,
        strokeWidth: 4,
        color: const Color(0xFF5E82C7),
        strokeCap: StrokeCap.round,
        strokeJoin: StrokeJoin.round,
      ),
      // Dashed centerline — standard wayfinding pattern, not decoration
      Polyline(
        points: points,
        strokeWidth: 1.5,
        color: Colors.white.withValues(alpha: 0.5),
        pattern: StrokePattern.dashed(segments: const [10, 8]),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Build all markers
    final markers = <Marker>[];

    if (widget.showHospitalPins) {
      markers.addAll(_buildHospitalMarkers());
    }

    // Ambulance position on the map. When activeBookings are supplied (ER
    // panel) each one already gets its own labelled marker, so the focus
    // position must not be drawn a second time on top of it.
    if (widget.ambulancePosition != null && widget.activeBookings.isEmpty) {
      markers.add(_buildAmbulanceMarker(widget.ambulancePosition!));
    }

    // Active bookings (for hospital ER view showing incoming ambulances)
    for (final booking in widget.activeBookings) {
      markers.add(_buildAmbulanceMarker(
        LatLng(booking.currentLat, booking.currentLng),
        label: booking.ambulanceId,
      ));
    }

    // Destination marker
    final destMarker = _buildDestinationMarker();
    if (destMarker != null) markers.add(destMarker);

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: widget.initialCenter,
            initialZoom: widget.initialZoom,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all,
            ),
            backgroundColor: AppColors.background,
          ),
          children: [
            // ─ Base tile layer (OSM – completely free)
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.joldibed',
              tileBuilder: _darkModeTileBuilder,
              maxZoom: 19,
            ),

            // ─ Route polylines
            PolylineLayer(polylines: _buildRoutePolyline()),

            // ─ Markers layer
            MarkerLayer(markers: markers),

            // ─ Attribution
            const RichAttributionWidget(
              attributions: [
                TextSourceAttribution('OpenStreetMap contributors'),
              ],
            ),
          ],
        ),

        // ─ Recenter button — only shown once the user has panned away
        // from the live position, so they can deliberately snap back.
        if (!_followMode && widget.ambulancePosition != null)
          Positioned(
            right: 12,
            bottom: 12,
            child: _RecenterButton(onTap: _recenter),
          ),
      ],
    );
  }

  /// Custom tile builder to apply a neutral dark tint to OSM tiles,
  /// matching the app's near-black surface tone rather than a blue-tinted
  /// "futuristic dashboard" look.
  Widget _darkModeTileBuilder(
    BuildContext context,
    Widget tileWidget,
    TileImage tile,
  ) {
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix([
        0.28, 0.28, 0.28, 0, 0,
        0.28, 0.28, 0.28, 0, 0,
        0.28, 0.28, 0.28, 0, 0,
        0, 0, 0, 1, 0,
      ]),
      child: tileWidget,
    );
  }
}

/// Small floating control that appears once the user has manually panned
/// the map away from the live-tracked position, letting them snap back on
/// purpose instead of having the camera do it for them.
class _RecenterButton extends StatelessWidget {
  final VoidCallback onTap;
  const _RecenterButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: AppColors.surface,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.border),
          boxShadow: AppShadow.card,
        ),
        child: const Icon(
          Icons.my_location_rounded,
          color: AppColors.textPrimary,
          size: 20,
        ),
      ),
    );
  }
}
