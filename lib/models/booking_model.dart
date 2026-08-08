import 'package:cloud_firestore/cloud_firestore.dart';

/// Enum for the lifecycle status of an ambulance booking.
enum BookingStatus {
  enRoute,
  arrived,
  cancelled,
}

extension BookingStatusExtension on BookingStatus {
  /// Returns the Firestore string representation.
  String get firestoreValue {
    switch (this) {
      case BookingStatus.enRoute:
        return 'EN_ROUTE';
      case BookingStatus.arrived:
        return 'ARRIVED';
      case BookingStatus.cancelled:
        return 'CANCELLED';
    }
  }

  /// Returns a human-readable label.
  String get label {
    switch (this) {
      case BookingStatus.enRoute:
        return 'En Route';
      case BookingStatus.arrived:
        return 'Arrived';
      case BookingStatus.cancelled:
        return 'Cancelled';
    }
  }

  static BookingStatus fromString(String value) {
    switch (value.toUpperCase()) {
      case 'EN_ROUTE':
        return BookingStatus.enRoute;
      case 'ARRIVED':
        return BookingStatus.arrived;
      case 'CANCELLED':
        return BookingStatus.cancelled;
      default:
        return BookingStatus.enRoute;
    }
  }
}

/// Represents an active ambulance-to-hospital booking record.
class BookingModel {
  final String id;
  final String ambulanceId;
  final String driverUid;
  final double currentLat;
  final double currentLng;
  final String targetHospitalId;
  final String targetHospitalName;
  final BookingStatus status;
  final DateTime createdAt;

  const BookingModel({
    required this.id,
    required this.ambulanceId,
    required this.driverUid,
    required this.currentLat,
    required this.currentLng,
    required this.targetHospitalId,
    this.targetHospitalName = '',
    required this.status,
    required this.createdAt,
  });

  /// Deserialize from a Firestore [DocumentSnapshot].
  factory BookingModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final ts = data['created_at'];
    DateTime createdAt = DateTime.now();
    if (ts is Timestamp) {
      createdAt = ts.toDate();
    }
    return BookingModel(
      id: doc.id,
      ambulanceId: data['ambulance_id'] as String? ?? '',
      driverUid: data['driver_uid'] as String? ?? '',
      currentLat: (data['current_lat'] as num?)?.toDouble() ?? 0.0,
      currentLng: (data['current_lng'] as num?)?.toDouble() ?? 0.0,
      targetHospitalId: data['target_hospital_id'] as String? ?? '',
      targetHospitalName: data['target_hospital_name'] as String? ?? '',
      status: BookingStatusExtension.fromString(
        data['status'] as String? ?? 'EN_ROUTE',
      ),
      createdAt: createdAt,
    );
  }

  /// Serialize to a [Map] for Firestore writes.
  Map<String, dynamic> toFirestore() {
    return {
      'ambulance_id': ambulanceId,
      'driver_uid': driverUid,
      'current_lat': currentLat,
      'current_lng': currentLng,
      'target_hospital_id': targetHospitalId,
      'target_hospital_name': targetHospitalName,
      'status': status.firestoreValue,
      'created_at': Timestamp.fromDate(createdAt),
    };
  }

  /// Create a copy with updated coordinates or status.
  BookingModel copyWith({
    String? id,
    String? ambulanceId,
    String? driverUid,
    double? currentLat,
    double? currentLng,
    String? targetHospitalId,
    String? targetHospitalName,
    BookingStatus? status,
    DateTime? createdAt,
  }) {
    return BookingModel(
      id: id ?? this.id,
      ambulanceId: ambulanceId ?? this.ambulanceId,
      driverUid: driverUid ?? this.driverUid,
      currentLat: currentLat ?? this.currentLat,
      currentLng: currentLng ?? this.currentLng,
      targetHospitalId: targetHospitalId ?? this.targetHospitalId,
      targetHospitalName: targetHospitalName ?? this.targetHospitalName,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  String toString() =>
      'BookingModel(id: $id, ambulance: $ambulanceId, status: ${status.label})';
}
