import 'package:flutter_test/flutter_test.dart';
import 'package:iculink/models/booking_model.dart';
import 'package:iculink/models/hospital_model.dart';
import 'package:iculink/models/user_profile_model.dart';

void main() {
  group('BookingStatus', () {
    test('round-trips through its Firestore string', () {
      for (final status in BookingStatus.values) {
        expect(
          BookingStatusExtension.fromString(status.firestoreValue),
          status,
        );
      }
    });

    test('parsing is case-insensitive and defaults to enRoute', () {
      expect(BookingStatusExtension.fromString('arrived'), BookingStatus.arrived);
      expect(BookingStatusExtension.fromString('nonsense'), BookingStatus.enRoute);
    });
  });

  group('HospitalModel', () {
    const hospital = HospitalModel(
      id: 'h1',
      name: 'Test Hospital',
      lat: 23.7,
      lng: 90.4,
      vacantIcuBeds: 3,
      availableVentilators: 2,
      contact: '+8801700000000',
      ownerUids: ['u1'],
    );

    test('serializes every field the Firestore rules validate', () {
      final map = hospital.toFirestore();
      expect(map['name'], 'Test Hospital');
      expect(map['vacant_icu_beds'], 3);
      expect(map['available_ventilators'], 2);
      expect(map['owner_uids'], ['u1']);
      expect(map['archived'], false);
    });

    test('copyWith changes only the given fields', () {
      final updated = hospital.copyWith(vacantIcuBeds: 0, archived: true);
      expect(updated.vacantIcuBeds, 0);
      expect(updated.archived, true);
      expect(updated.name, hospital.name);
      expect(updated.ownerUids, hospital.ownerUids);
    });
  });

  group('UserProfileModel', () {
    test('role strings round-trip and unknown values default to driver', () {
      for (final role in UserRole.values) {
        expect(UserRoleExtension.fromString(role.firestoreValue), role);
      }
      expect(UserRoleExtension.fromString('???'), UserRole.driver);
    });

    test('toFirestore writes the role string the rules check for', () {
      final profile = UserProfileModel(
        uid: 'u1',
        role: UserRole.hospitalStaff,
        name: 'Staff',
        createdAt: DateTime(2026),
      );
      expect(profile.toFirestore()['role'], 'HOSPITAL_STAFF');
      expect(profile.toFirestore().containsKey('hospital_ids'), false);
    });
  });
}
