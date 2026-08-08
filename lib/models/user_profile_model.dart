import 'package:cloud_firestore/cloud_firestore.dart';

/// Enum for the two account roles ICULink supports.
enum UserRole {
  driver,
  hospitalStaff,
}

extension UserRoleExtension on UserRole {
  /// Returns the Firestore string representation.
  String get firestoreValue {
    switch (this) {
      case UserRole.driver:
        return 'DRIVER';
      case UserRole.hospitalStaff:
        return 'HOSPITAL_STAFF';
    }
  }

  static UserRole fromString(String value) {
    switch (value.toUpperCase()) {
      case 'DRIVER':
        return UserRole.driver;
      case 'HOSPITAL_STAFF':
        return UserRole.hospitalStaff;
      default:
        return UserRole.driver;
    }
  }
}

/// Represents a registered driver or hospital-staff account, keyed by the
/// Firebase Auth UID. Stored in the `users` Firestore collection.
class UserProfileModel {
  final String uid;
  final UserRole role;
  final String name;
  final String? vehicleId;
  final List<String> hospitalIds;
  final String? email;
  final String? phone;
  final List<String> fcmTokens;
  final DateTime createdAt;

  const UserProfileModel({
    required this.uid,
    required this.role,
    required this.name,
    this.vehicleId,
    this.hospitalIds = const [],
    this.email,
    this.phone,
    this.fcmTokens = const [],
    required this.createdAt,
  });

  /// Deserialize from a Firestore [DocumentSnapshot].
  factory UserProfileModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final ts = data['created_at'];
    DateTime createdAt = DateTime.now();
    if (ts is Timestamp) {
      createdAt = ts.toDate();
    }
    return UserProfileModel(
      uid: doc.id,
      role: UserRoleExtension.fromString(data['role'] as String? ?? 'DRIVER'),
      name: data['name'] as String? ?? '',
      vehicleId: data['vehicle_id'] as String?,
      hospitalIds: (data['hospital_ids'] as List?)?.cast<String>() ?? const [],
      email: data['email'] as String?,
      phone: data['phone'] as String?,
      fcmTokens: (data['fcm_tokens'] as List?)?.cast<String>() ?? const [],
      createdAt: createdAt,
    );
  }

  /// Serialize to a [Map] for Firestore writes.
  Map<String, dynamic> toFirestore() {
    return {
      'role': role.firestoreValue,
      'name': name,
      'vehicle_id': vehicleId,
      'hospital_ids': hospitalIds,
      'email': email,
      'phone': phone,
      'fcm_tokens': fcmTokens,
      'created_at': Timestamp.fromDate(createdAt),
    };
  }

  UserProfileModel copyWith({
    String? uid,
    UserRole? role,
    String? name,
    String? vehicleId,
    List<String>? hospitalIds,
    String? email,
    String? phone,
    List<String>? fcmTokens,
    DateTime? createdAt,
  }) {
    return UserProfileModel(
      uid: uid ?? this.uid,
      role: role ?? this.role,
      name: name ?? this.name,
      vehicleId: vehicleId ?? this.vehicleId,
      hospitalIds: hospitalIds ?? this.hospitalIds,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      fcmTokens: fcmTokens ?? this.fcmTokens,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  String toString() =>
      'UserProfileModel(uid: $uid, role: ${role.firestoreValue}, name: $name)';
}
