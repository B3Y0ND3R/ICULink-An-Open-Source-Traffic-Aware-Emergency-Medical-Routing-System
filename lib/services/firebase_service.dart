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

  /// Writes a complete hospital document (for seeding initial data).
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

  /// Admin utility: links a hospital-staff account to a hospital. Writes
  /// both directions of the relationship — the hospital's `owner_uids`
  /// (used by the update-authorization rule) and the staff member's
  /// `users/{uid}.hospital_ids` (used by the bookings read-authorization
  /// rule, kept as a single-document check rather than a cross-document
  /// lookup). Hospital-to-staff linking is manual for now — run this once
  /// per staff member after they register.
  Future<void> assignHospitalOwner(String hospitalId, String uid) async {
    final batch = _db.batch();
    batch.update(_db.collection('hospitals').doc(hospitalId), {
      'owner_uids': FieldValue.arrayUnion([uid]),
    });
    batch.update(_db.collection('users').doc(uid), {
      'hospital_ids': FieldValue.arrayUnion([hospitalId]),
    });
    await batch.commit();
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
        .map(
          (snapshot) => snapshot.docs
              .map((doc) => BookingModel.fromFirestore(doc))
              .toList(),
        )
        .recoverWith(() => <BookingModel>[],
            logLabel: 'streamActiveBookingsForHospital');
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

  // ─────────────────────────────────────────────
  //  DATA SEEDING (call once on first run)
  // ─────────────────────────────────────────────

  /// Seeds the Firestore database with a curated list of Dhaka & Chittagong
  /// hospitals so the app is functional immediately after setup.
  Future<void> seedInitialHospitals() async {
    try {
      final existing = await _db.collection('hospitals').limit(1).get();
      if (existing.docs.isNotEmpty) return; // already seeded

    final hospitals = [
      HospitalModel(
        id: 'dmch_01',
        name: 'Dhaka Medical College Hospital',
        lat: 23.7259,
        lng: 90.3972,
        vacantIcuBeds: 4,
        availableVentilators: 3,
        contact: '+8801700000001',
      ),
      HospitalModel(
        id: 'bsmmu_02',
        name: 'Bangabandhu Sheikh Mujib Medical University',
        lat: 23.7340,
        lng: 90.3966,
        vacantIcuBeds: 6,
        availableVentilators: 4,
        contact: '+8801700000002',
      ),
      HospitalModel(
        id: 'nhf_03',
        name: 'National Heart Foundation Hospital',
        lat: 23.7922,
        lng: 90.3711,
        vacantIcuBeds: 2,
        availableVentilators: 1,
        contact: '+8801700000003',
      ),
      HospitalModel(
        id: 'square_04',
        name: 'Square Hospital',
        lat: 23.7518,
        lng: 90.3746,
        vacantIcuBeds: 5,
        availableVentilators: 3,
        contact: '+8801700000004',
      ),
      HospitalModel(
        id: 'ibn_05',
        name: 'Ibn Sina Hospital Dhanmondi',
        lat: 23.7438,
        lng: 90.3703,
        vacantIcuBeds: 3,
        availableVentilators: 2,
        contact: '+8801700000005',
      ),
      HospitalModel(
        id: 'cmch_06',
        name: 'Chittagong Medical College Hospital',
        lat: 22.3569,
        lng: 91.8317,
        vacantIcuBeds: 7,
        availableVentilators: 5,
        contact: '+8801700000006',
      ),
      HospitalModel(
        id: 'parkview_07',
        name: 'Parkview Hospital Chittagong',
        lat: 22.3750,
        lng: 91.8290,
        vacantIcuBeds: 3,
        availableVentilators: 2,
        contact: '+8801700000007',
      ),
      HospitalModel(
        id: 'popular_08',
        name: 'Popular Medical Centre Dhaka',
        lat: 23.7460,
        lng: 90.3820,
        vacantIcuBeds: 0,
        availableVentilators: 0,
        contact: '+8801700000008',
      ),
    ];

      final batch = _db.batch();
      for (final h in hospitals) {
        batch.set(_db.collection('hospitals').doc(h.id), h.toFirestore());
      }
      await batch.commit();
      debugPrint('Firestore: Seeded ${hospitals.length} hospitals successfully.');
    } catch (e) {
      debugPrint('seedInitialHospitals error (enable Cloud Firestore API): $e');
    }
  }
}
