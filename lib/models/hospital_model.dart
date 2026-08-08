import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents a hospital with real-time ICU and ventilator data.
class HospitalModel {
  final String id;
  final String name;
  final double lat;
  final double lng;
  final int vacantIcuBeds;
  final int availableVentilators;
  final String contact;
  final List<String> ownerUids;
  final bool archived;

  const HospitalModel({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.vacantIcuBeds,
    required this.availableVentilators,
    required this.contact,
    this.ownerUids = const [],
    this.archived = false,
  });

  /// Deserialize from a Firestore [DocumentSnapshot].
  factory HospitalModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return HospitalModel(
      id: doc.id,
      name: data['name'] as String? ?? 'Unknown Hospital',
      lat: (data['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (data['lng'] as num?)?.toDouble() ?? 0.0,
      vacantIcuBeds: (data['vacant_icu_beds'] as num?)?.toInt() ?? 0,
      availableVentilators:
          (data['available_ventilators'] as num?)?.toInt() ?? 0,
      contact: data['contact'] as String? ?? '',
      ownerUids: (data['owner_uids'] as List?)?.cast<String>() ?? const [],
      archived: data['archived'] as bool? ?? false,
    );
  }

  /// Serialize to a [Map] for Firestore writes.
  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'lat': lat,
      'lng': lng,
      'vacant_icu_beds': vacantIcuBeds,
      'available_ventilators': availableVentilators,
      'contact': contact,
      'owner_uids': ownerUids,
      'archived': archived,
    };
  }

  /// Create a copy with modified fields.
  HospitalModel copyWith({
    String? id,
    String? name,
    double? lat,
    double? lng,
    int? vacantIcuBeds,
    int? availableVentilators,
    String? contact,
    List<String>? ownerUids,
    bool? archived,
  }) {
    return HospitalModel(
      id: id ?? this.id,
      name: name ?? this.name,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      vacantIcuBeds: vacantIcuBeds ?? this.vacantIcuBeds,
      availableVentilators: availableVentilators ?? this.availableVentilators,
      contact: contact ?? this.contact,
      ownerUids: ownerUids ?? this.ownerUids,
      archived: archived ?? this.archived,
    );
  }

  @override
  String toString() =>
      'HospitalModel(id: $id, name: $name, beds: $vacantIcuBeds)';
}
