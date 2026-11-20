import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/hospital_model.dart';
import '../models/booking_model.dart';
import '../utils/stream_extensions.dart';

/// Central Firebase service that handles all Firestore reads and writes.
/// Uses real-time streams for live UI updates without manual polling.
class FirebaseService {
  FirebaseService._internal();
  static final FirebaseService instance = FirebaseService._internal();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ─────────────────────────────────────────────
  //  HOSPITAL OPERATIONS
  // ─────────────────────────────────────────────

  /// Returns a real-time stream of all hospitals in Firestore.
  Stream<List<HospitalModel>> streamAllHospitals() {
    return _db
        .collection('hospitals')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((doc) => HospitalModel.fromFirestore(doc))
              .toList(),
        )
        .recoverWith(() => <HospitalModel>[], logLabel: 'streamAllHospitals');
  }

  /// Real-time stream of the hospitals owned by [uid] (archived ones
  /// included — the caller splits them). Server-side filtered so staff
  /// don't download the whole directory.
  Stream<List<HospitalModel>> streamHospitalsForOwner(String uid) {
    return _db
        .collection('hospitals')
        .where('owner_uids', arrayContains: uid)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((doc) => HospitalModel.fromFirestore(doc))
              .toList(),
        )
        .recoverWith(() => <HospitalModel>[],
            logLabel: 'streamHospitalsForOwner');
  }

  /// Fetches all hospitals as a one-time read (used in routing algorithm).
  Future<List<HospitalModel>> fetchAllHospitals() async {
    try {
      final snapshot = await _db.collection('hospitals').get();
      return snapshot.docs
          .map((doc) => HospitalModel.fromFirestore(doc))
          .toList();
    } catch (e) {
      debugPrint('fetchAllHospitals error: $e');
      return [];
    }
  }

  /// Fetches a single hospital by its document [id].
  Future<HospitalModel?> fetchHospitalById(String id) async {
    final doc = await _db.collection('hospitals').doc(id).get();
    if (!doc.exists) return null;
    return HospitalModel.fromFirestore(doc);
  }

  /// Returns a real-time stream for a single hospital document.
  Stream<HospitalModel?> streamHospital(String hospitalId) {
    return _db
        .collection('hospitals')
        .doc(hospitalId)
        .snapshots()
        .map((doc) => doc.exists ? HospitalModel.fromFirestore(doc) : null);
  }

  /// Atomically increments [fieldName] by [delta] for a given hospital.
  /// [delta] can be negative to decrement.
  Future<void> updateHospitalField(
    String hospitalId,
    String fieldName,
    int delta,
  ) async {
    final ref = _db.collection('hospitals').doc(hospitalId);
    await _db.runTransaction((tx) async {
      final snapshot = await tx.get(ref);
      if (!snapshot.exists) return;
      final current = (snapshot.data()?[fieldName] as num?)?.toInt() ?? 0;
      final updated = (current + delta).clamp(0, 999);
      tx.update(ref, {fieldName: updated});
    });
  }

  /// Writes a complete hospital document (used by the Add Hospital form).
  Future<void> setHospital(HospitalModel hospital) async {
    await _db
        .collection('hospitals')
        .doc(hospital.id)
        .set(hospital.toFirestore());
  }

  /// Updates a hospital's profile fields (name/contact/location). Does not
  /// touch resource counts — those stay on the dedicated +/- flow in
  /// [updateHospitalField] — or owner_uids, which is admin-only.
  Future<void> updateHospitalDetails(
    String hospitalId, {
    required String name,
    required String contact,
    required double lat,
    required double lng,
  }) async {
    await _db.collection('hospitals').doc(hospitalId).update({
      'name': name,
      'contact': contact,
      'lat': lat,
      'lng': lng,
    });
  }

  /// Soft-deletes (or restores) a hospital. Archived hospitals stay in
  /// Firestore — and every booking that ever referenced them keeps
  /// resolving correctly — but are hidden from the staff selector and
  /// excluded from driver routing.
  Future<void> setHospitalArchived(String hospitalId, bool archived) async {
    await _db.collection('hospitals').doc(hospitalId).update({
      'archived': archived,
    });
  }

  // ─────────────────────────────────────────────
  //  BOOKING OPERATIONS
  // ─────────────────────────────────────────────

  /// Creates a new booking document in Firestore and returns its ID.
  Future<String> createBooking(BookingModel booking) async {
    final docRef = _db.collection('bookings').doc(booking.id);
    await docRef.set(booking.toFirestore());
    return docRef.id;
  }

  /// Returns a real-time stream of active (EN_ROUTE) bookings
  /// targeting a specific hospital.
  Stream<List<BookingModel>> streamActiveBookingsForHospital(
    String hospitalId,
  ) {
    return _db
        .collection('bookings')
        .where('target_hospital_id', isEqualTo: hospitalId)
        .where('status', isEqualTo: 'EN_ROUTE')
        .snapshots()
        .map((snapshot) {
          // Ignore bookings that have been "en route" implausibly long —
          // they're orphans from a driver app that was killed mid-trip and
          // must not hold a hospital's alarm on forever.
          final cutoff = DateTime.now().subtract(staleBookingAge);
          return snapshot.docs
              .map((doc) => BookingModel.fromFirestore(doc))
              .where((b) => b.createdAt.isAfter(cutoff))
              .toList();
        })
        .recoverWith(() => <BookingModel>[],
            logLabel: 'streamActiveBookingsForHospital');
  }

  /// An EN_ROUTE booking older than this is treated as abandoned.
  static const Duration staleBookingAge = Duration(hours: 4);

  /// Marks any of this driver's still-EN_ROUTE bookings as CANCELLED.
  /// Called when the driver app opens: a fresh session has no active trip,
  /// so anything still EN_ROUTE was orphaned by a crash or force-close.
  /// (Client-side stand-in for a scheduled cleanup function, which would
  /// need Firebase's paid plan.)
  Future<void> cancelOrphanedBookingsForDriver(String driverUid) async {
    try {
      final stale = await _db
          .collection('bookings')
          .where('driver_uid', isEqualTo: driverUid)
          .where('status', isEqualTo: 'EN_ROUTE')
          .get();
      for (final doc in stale.docs) {
        await doc.reference.update({'status': 'CANCELLED'});
      }
    } catch (e) {
      debugPrint('cancelOrphanedBookingsForDriver error: $e');
    }
  }

  /// Returns a real-time stream of a driver's booking history (all
  /// statuses), newest first. Keyed on the stable Firebase Auth UID rather
  /// than the human-readable ambulance/vehicle ID.
  Stream<List<BookingModel>> streamBookingsForDriver(
    String driverUid, {
    int limit = 50,
  }) {
    return _db
        .collection('bookings')
        .where('driver_uid', isEqualTo: driverUid)
        .orderBy('created_at', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((doc) => BookingModel.fromFirestore(doc))
              .toList(),
        )
        .recoverWith(() => <BookingModel>[], logLabel: 'streamBookingsForDriver');
  }

  /// Returns a real-time stream of a hospital's full booking history (all
  /// statuses, not just active EN_ROUTE ones), newest first.
  Stream<List<BookingModel>> streamPastBookingsForHospital(
    String hospitalId, {
    int limit = 50,
  }) {
    return _db
        .collection('bookings')
        .where('target_hospital_id', isEqualTo: hospitalId)
        .orderBy('created_at', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((doc) => BookingModel.fromFirestore(doc))
              .toList(),
        )
        .recoverWith(() => <BookingModel>[],
            logLabel: 'streamPastBookingsForHospital');
  }

  /// Updates the ambulance's live coordinates in an existing booking.
  Future<void> updateBookingCoordinates(
    String bookingId,
    double lat,
    double lng,
  ) async {
    await _db.collection('bookings').doc(bookingId).update({
      'current_lat': lat,
      'current_lng': lng,
    });
  }

  /// Updates the status of a booking (e.g., ARRIVED or CANCELLED).
  Future<void> updateBookingStatus(
    String bookingId,
    BookingStatus status,
  ) async {
    await _db.collection('bookings').doc(bookingId).update({
      'status': status.firestoreValue,
    });
  }

  /// Fetches a single booking by document ID.
  Future<BookingModel?> fetchBookingById(String bookingId) async {
    final doc = await _db.collection('bookings').doc(bookingId).get();
    if (!doc.exists) return null;
    return BookingModel.fromFirestore(doc);
  }
}
