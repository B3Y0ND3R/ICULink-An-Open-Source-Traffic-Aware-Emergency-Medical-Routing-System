import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
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

/// One TomTom Matrix API result: a travel duration plus how much of it (if
/// any) reflects a live-traffic delay rather than a raw free-flow estimate.
class _MatrixEntry {
  final double durationMinutes;
  final int? trafficDelaySeconds;
  const _MatrixEntry(this.durationMinutes, this.trafficDelaySeconds);

  /// TomTom reports `trafficDelayInSeconds: 0` both when a route genuinely
  /// has no current congestion *and* when it simply has no live-traffic
  /// sensor coverage for that road (confirmed directly: a Khulna route came
  /// back with 0 delay and a 69 km/h implied speed — clearly no real data,
  /// not an empty road). There's no way to tell those two cases apart from
  /// the API alone, so treat zero delay as "can't trust this number" rather
  /// than "confirmed clear road."
  bool get hasLiveTrafficData => (trafficDelaySeconds ?? 0) > 0;
}

/// Handles all map and routing operations, deliberately splitting the work
/// across two providers by what each is actually good at:
///
/// - **TomTom Matrix API** for hospital scoring and the displayed ETA — its
///   travel times factor in live traffic, unlike a theoretical free-flow
///   speed.
/// - **OpenRouteService Directions API** for the actual road-following line
///   drawn on the map — verified directly against TomTom on a real Khulna
///   route: TomTom's own road-network data had a gap here and snapped the
///   route over a kilometer from the real start/end point, while ORS (built
///   on OpenStreetMap, which has strong community-mapped coverage in
///   Bangladesh) landed within ~15m of both. ORS has no live traffic data,
///   but that's fine — its output is only ever used for line geometry, never
///   for timing.
///
/// Falls back to a Haversine (great-circle) estimate at ~20 km/h (Dhaka traffic average)
/// for duration, and a straight line for geometry, if the respective
/// provider is unreachable.
class RoutingService {
  RoutingService._internal();
  static final RoutingService instance = RoutingService._internal();

  // Loaded from lib/config/secrets.dart, which is gitignored — see
  // lib/config/secrets.example.dart for the template.
  static const String _tomtomApiKey = Secrets.tomtomApiKey;
  static const String _orsApiKey = Secrets.orsApiKey;

  static const double _fallbackSpeedKmPerMin = 0.333; // ~20 km/h
  static const String _matrixUrl = 'https://api.tomtom.com/routing/matrix/2';
  static const String _orsDirectionsUrl =
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
  //  GREAT-CIRCLE FALLBACK DISTANCE (Haversine)
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
  //  TOMTOM MATRIX ROUTING API
  // ─────────────────────────────────────────────

  /// Queries the TomTom Matrix Routing API (v2) for live, traffic-aware
  /// travel durations from the ambulance to every hospital in [destinations].
  /// Returns one entry per destination (ordered to match), or null on any
  /// network or API error.
  Future<List<_MatrixEntry>?> _fetchMatrixDurations(
    List<double> ambulance,
    List<List<double>> destinations,
  ) async {
    if (destinations.isEmpty) return [];

    final uri = Uri.parse('$_matrixUrl?key=$_tomtomApiKey');

    try {
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'origins': [
                {
                  'point': {'latitude': ambulance[0], 'longitude': ambulance[1]}
                }
              ],
              'destinations': destinations
                  .map((d) => {
                        'point': {'latitude': d[0], 'longitude': d[1]}
                      })
                  .toList(),
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint('TomTom matrix error: ${response.statusCode} ${response.body}');
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final data = json['data'] as List?;
      if (data == null || data.isEmpty) return null;

      // Response items carry an explicit destinationIndex rather than
      // relying on array order — map back into a list keyed by that index
      // rather than assuming the response preserves request order.
      final entries = List<_MatrixEntry?>.filled(destinations.length, null);
      for (final entry in data) {
        final e = entry as Map<String, dynamic>;
        final destIndex = e['destinationIndex'] as int?;
        final summary = e['routeSummary'] as Map<String, dynamic>?;
        final seconds = (summary?['travelTimeInSeconds'] as num?)?.toDouble();
        final delaySeconds = (summary?['trafficDelayInSeconds'] as num?)?.toInt();
        if (destIndex != null && seconds != null && destIndex < entries.length) {
          entries[destIndex] = _MatrixEntry(seconds / 60.0, delaySeconds);
        }
      }
      return entries
          .map((e) => e ?? const _MatrixEntry(double.infinity, null))
          .toList();
    } catch (e) {
      debugPrint('TomTom matrix exception: $e');
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
  /// 2. Filters out hospitals with 0 ICU beds (or archived).
  /// 3. Queries the TomTom Matrix Routing API for live, traffic-aware travel durations.
  /// 4. Falls back to a Haversine estimate for *all* hospitals if TomTom is
  ///    unavailable or lacks live-traffic data for any of them.
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

    // Step 3: Attempt TomTom Matrix Routing API
    final ambulanceCoord = [ambulanceLat, ambulanceLng];
    final destCoords = eligible.map((h) => [h.lat, h.lng]).toList();

    final matrixDurations =
        await _fetchMatrixDurations(ambulanceCoord, destCoords);

    // Every hospital must be scored on the same basis, otherwise a hospital
    // with a live TomTom estimate gets compared against one with a crude
    // straight-line guess and the ranking is meaningless. So live data is
    // used only when it is trustworthy for *all* eligible hospitals;
    // otherwise every hospital uses the same Haversine estimate.
    final useLiveData = matrixDurations != null &&
        matrixDurations.length == eligible.length &&
        matrixDurations
            .every((e) => e.durationMinutes.isFinite && e.hasLiveTrafficData);
    final usedFallback = !useLiveData;

    // Step 4 & 5: Score each eligible hospital
    RoutingResult? best;

    for (int i = 0; i < eligible.length; i++) {
      final hospital = eligible[i];
      final durationMinutes = useLiveData
          ? matrixDurations[i].durationMinutes
          : _fallbackDurationMinutes(
              ambulanceLat,
              ambulanceLng,
              hospital.lat,
              hospital.lng,
            );

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

  /// Fetches a turn-by-turn route geometry (list of [lat, lng] pairs) between
  /// two points using the OpenRouteService Directions API (OSM-based road
  /// data — chosen for geometry specifically because it covers this app's
  /// target region better than TomTom's commercial map). Purely visual: this
  /// never feeds into the displayed ETA or hospital scoring, both of which
  /// stay on TomTom's traffic-aware Matrix API. Falls back to a direct line
  /// on any network/API error, or if the returned route's endpoints land
  /// implausibly far from the requested coordinates.
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

    final uri = Uri.parse(_orsDirectionsUrl);

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

      if (response.statusCode != 200) {
        debugPrint('ORS routing error: ${response.statusCode} ${response.body}');
        return directLine;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final features = json['features'] as List?;
      if (features == null || features.isEmpty) return directLine;

      final geometry =
          (features[0] as Map<String, dynamic>)['geometry'] as Map<String, dynamic>;
      final coordinates = (geometry['coordinates'] as List).map((coord) {
        final c = coord as List;
        // GeoJSON is [lng, lat] — flip to the [lat, lng] pairs CustomMap expects.
        return [(c[1] as num).toDouble(), (c[0] as num).toDouble()];
      }).toList();

      if (coordinates.length < 2) return directLine;

      // Sanity check kept as cheap insurance regardless of provider — if a
      // route's endpoints don't land near where we asked, a misleading path
      // is worse than a plain straight line.
      const maxSnapDistanceKm = 1.0;
      final startDrift =
          _haversineDistanceKm(fromLat, fromLng, coordinates.first[0], coordinates.first[1]);
      final endDrift =
          _haversineDistanceKm(toLat, toLng, coordinates.last[0], coordinates.last[1]);
      if (startDrift > maxSnapDistanceKm || endDrift > maxSnapDistanceKm) {
        debugPrint(
          'ORS route endpoints too far from requested points '
          '(start drift ${startDrift.toStringAsFixed(2)}km, end drift ${endDrift.toStringAsFixed(2)}km) — using direct line',
        );
        return directLine;
      }

      return coordinates;
    } catch (e) {
      debugPrint('ORS routing exception: $e');
      return directLine;
    }
  }
}
