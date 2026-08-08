import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../config/secrets.dart';
import '../models/hospital_model.dart';
import 'firebase_service.dart';

/// Result from the routing engine containing the best hospital and its score.
class RoutingResult {
  final HospitalModel hospital;
  final double score;
  final double durationMinutes;
  final bool usedFallback;

  const RoutingResult({
    required this.hospital,
    required this.score,
    required this.durationMinutes,
    required this.usedFallback,
  });
}

/// Coordinates of a point used in OpenRouteService API calls.
class _Coordinate {
  final double lat;
  final double lng;
  const _Coordinate(this.lat, this.lng);
  List<double> toLngLat() => [lng, lat];
}

/// Handles all map and routing operations.
/// Uses the OpenRouteService Matrix + Directions APIs when reachable,
/// falling back to a Euclidean estimate at ~20 km/h (Dhaka traffic average).
class RoutingService {
  RoutingService._internal();
  static final RoutingService instance = RoutingService._internal();

  // ─── OpenRouteService API key (openrouteservice.org) ───
  // Loaded from lib/config/secrets.dart, which is gitignored — see
  // lib/config/secrets.example.dart for the template.
  static const String _orsApiKey = Secrets.orsApiKey;

  static const double _fallbackSpeedKmPerMin = 0.333; // ~20 km/h

  /// OpenRouteService's `driving-car` profile has no live traffic data — it
  /// returns a theoretical free-flow highway duration, which reads as
  /// wildly optimistic for real Bangladesh road/traffic conditions (verified
  /// directly against the API: Khulna → Dhaka comes back as ~141 min, versus
  /// a real-world 5-6 hour drive). This is a rough regional correction
  /// factor, not a measured constant — there's no live-traffic data source
  /// behind it, just a fixed slowdown applied to bring the displayed ETA
  /// closer to reality. Only applied to Matrix-API-derived durations; the
  /// Haversine fallback below already assumes a deliberately slow 20 km/h.
  static const double _trafficRealismMultiplier = 1.8;
  static const String _matrixUrl =
      'https://api.openrouteservice.org/v2/matrix/driving-car';
  static const String _directionsUrl =
      'https://api.openrouteservice.org/v2/directions/driving-car/geojson';

  // ─────────────────────────────────────────────
  //  SCORING ALGORITHM
  //  Score(H) = (0.7 × t_traffic) - (0.3 × N_beds)
  //  Lower score = better hospital
  // ─────────────────────────────────────────────

  double _computeScore(double tTrafficMinutes, int nBeds) {
    return (0.7 * tTrafficMinutes) - (0.3 * nBeds);
  }

  // ─────────────────────────────────────────────
  //  EUCLIDEAN FALLBACK DISTANCE (Haversine)
  // ─────────────────────────────────────────────

  double _haversineDistanceKm(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const double earthRadiusKm = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLng = _degToRad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_degToRad(lat1)) *
            cos(_degToRad(lat2)) *
            sin(dLng / 2) *
            sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusKm * c;
  }

  double _degToRad(double deg) => deg * (pi / 180);

  double _fallbackDurationMinutes(
    double ambulanceLat,
    double ambulanceLng,
    double hospitalLat,
    double hospitalLng,
  ) {
    final distKm = _haversineDistanceKm(
      ambulanceLat,
      ambulanceLng,
      hospitalLat,
      hospitalLng,
    );
    return distKm / _fallbackSpeedKmPerMin;
  }

  // ─────────────────────────────────────────────
  //  OPENROUTESERVICE MATRIX API
  // ─────────────────────────────────────────────

  /// Queries the OpenRouteService Matrix API.
  /// Returns a list of durations (in minutes) from the ambulance to each
  /// hospital in [destinations]. Returns null on any network or API error.
  Future<List<double>?> _fetchMatrixDurations(
    _Coordinate ambulance,
    List<_Coordinate> destinations,
  ) async {
    if (destinations.isEmpty) return [];

    final locations = [
      ambulance.toLngLat(),
      ...destinations.map((d) => d.toLngLat()),
    ];
    final destinationIndices = List.generate(destinations.length, (i) => i + 1);

    final uri = Uri.parse(_matrixUrl);

    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Authorization': _orsApiKey,
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'locations': locations,
              'sources': [0],
              'destinations': destinationIndices,
              'metrics': ['duration'],
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final durationsRaw = (json['durations'] as List?)?.firstOrNull as List?;
      if (durationsRaw == null) return null;

      // Convert seconds to minutes
      return durationsRaw
          .map((v) => ((v as num?)?.toDouble() ?? double.infinity) / 60.0)
          .toList();
    } catch (_) {
      return null;
    }
  }

  // ─────────────────────────────────────────────
  //  MAIN ROUTING ENTRY POINT
  // ─────────────────────────────────────────────

  /// Finds the optimal hospital for an ambulance at ([ambulanceLat], [ambulanceLng]).
  ///
  /// Steps:
  /// 1. Fetches all hospitals from Firestore.
  /// 2. Filters out hospitals with 0 ICU beds.
  /// 3. Queries the OpenRouteService Matrix API for live travel durations.
  /// 4. Falls back to Haversine estimate if OpenRouteService is unavailable.
  /// 5. Scores each hospital and returns the best match.
  Future<RoutingResult?> findOptimalHospital({
    required double ambulanceLat,
    required double ambulanceLng,
  }) async {
    // Step 1 & 2: Fetch and filter hospitals
    final allHospitals = await FirebaseService.instance.fetchAllHospitals();
    final eligible = allHospitals
        .where((h) => h.vacantIcuBeds > 0 && !h.archived)
        .toList();

    if (eligible.isEmpty) return null;

    // Step 3: Attempt OpenRouteService Matrix API
    final ambulanceCoord = _Coordinate(ambulanceLat, ambulanceLng);
    final destCoords =
        eligible.map((h) => _Coordinate(h.lat, h.lng)).toList();

    final matrixDurations =
        await _fetchMatrixDurations(ambulanceCoord, destCoords);

    bool usedFallback = matrixDurations == null;

    // Step 4 & 5: Score each eligible hospital
    RoutingResult? best;

    for (int i = 0; i < eligible.length; i++) {
      final hospital = eligible[i];
      double durationMinutes;

      if (!usedFallback &&
          i < matrixDurations!.length &&
          matrixDurations[i].isFinite) {
        durationMinutes = matrixDurations[i] * _trafficRealismMultiplier;
      } else {
        durationMinutes = _fallbackDurationMinutes(
          ambulanceLat,
          ambulanceLng,
          hospital.lat,
          hospital.lng,
        );
        usedFallback = true;
      }

      final score = _computeScore(durationMinutes, hospital.vacantIcuBeds);

      if (best == null || score < best.score) {
        best = RoutingResult(
          hospital: hospital,
          score: score,
          durationMinutes: durationMinutes,
          usedFallback: usedFallback,
        );
      }
    }

    return best;
  }

  /// Fetches a turn-by-turn route geometry (list of lat/lng) between two points
  /// using the OpenRouteService Directions API. Falls back to a direct line
  /// on any network or API error.
  Future<List<List<double>>> fetchRoutePolyline({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
  }) async {
    final directLine = [
      [fromLat, fromLng],
      [toLat, toLng],
    ];

    final uri = Uri.parse(_directionsUrl);

    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Authorization': _orsApiKey,
              'Content-Type': 'application/json',
              'Accept': 'application/geo+json',
            },
            body: jsonEncode({
              'coordinates': [
                [fromLng, fromLat],
                [toLng, toLat],
              ],
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return directLine;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final features = json['features'] as List?;
      if (features == null || features.isEmpty) return directLine;

      final geometry =
          (features[0] as Map<String, dynamic>)['geometry'] as Map<String, dynamic>;
      final coordinates = (geometry['coordinates'] as List)
          .map((coord) {
            final c = coord as List;
            // GeoJSON is [lng, lat]
            return [
              (c[1] as num).toDouble(),
              (c[0] as num).toDouble(),
            ];
          })
          .toList();

      return coordinates;
    } catch (_) {
      return directLine;
    }
  }
}
