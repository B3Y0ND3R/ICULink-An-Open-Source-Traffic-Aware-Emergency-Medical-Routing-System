import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_profile_model.dart';
import '../utils/stream_extensions.dart';

/// Central authentication service handling Firebase Auth sign-in (email and
/// phone) and the `users` Firestore profile that accompanies each account.
class AuthService {
  AuthService._internal();
  static final AuthService instance = AuthService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Stream of the current Firebase Auth user; null when signed out.
  Stream<User?> authStateChanges() => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  // ─────────────────────────────────────────────
  //  EMAIL / PASSWORD
  // ─────────────────────────────────────────────

  Future<UserCredential> signUpWithEmail(String email, String password) {
    return _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
  }

  Future<UserCredential> signInWithEmail(String email, String password) {
    return _auth.signInWithEmailAndPassword(email: email, password: password);
  }

  // ─────────────────────────────────────────────
  //  PHONE / OTP
  // ─────────────────────────────────────────────

  /// Starts phone verification. [onCodeSent] receives the verification ID to
  /// pass back into [confirmPhoneCode] once the user enters the OTP.
  Future<void> startPhoneSignIn({
    required String phoneNumber,
    required void Function(String verificationId) onCodeSent,
    required void Function(FirebaseAuthException e) onError,
    void Function(UserCredential credential)? onAutoVerified,
  }) async {
    await _auth.verifyPhoneNumber(
      phoneNumber: phoneNumber,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (PhoneAuthCredential credential) async {
        try {
          final result = await _auth.signInWithCredential(credential);
          onAutoVerified?.call(result);
        } on FirebaseAuthException catch (e) {
          onError(e);
        }
      },
      verificationFailed: onError,
      codeSent: (String verificationId, int? resendToken) {
        onCodeSent(verificationId);
      },
      codeAutoRetrievalTimeout: (String verificationId) {
        onCodeSent(verificationId);
      },
    );
  }

  Future<UserCredential> confirmPhoneCode({
    required String verificationId,
    required String smsCode,
  }) {
    final credential = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: smsCode,
    );
    return _auth.signInWithCredential(credential);
  }

  // ─────────────────────────────────────────────
  //  SESSION
  // ─────────────────────────────────────────────

  Future<void> signOut() => _auth.signOut();

  // ─────────────────────────────────────────────
  //  PROFILE (users/{uid})
  // ─────────────────────────────────────────────

  /// Fetches the current user's profile, or null if they haven't completed
  /// registration (no `users/{uid}` document yet).
  Future<UserProfileModel?> fetchCurrentUserProfile() async {
    final uid = currentUser?.uid;
    if (uid == null) return null;
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    return UserProfileModel.fromFirestore(doc);
  }

  Stream<UserProfileModel?> streamCurrentUserProfile() {
    final uid = currentUser?.uid;
    if (uid == null) return Stream.value(null);
    return _db
        .collection('users')
        .doc(uid)
        .snapshots()
        .map((doc) => doc.exists ? UserProfileModel.fromFirestore(doc) : null)
        .recoverWith(() => null, logLabel: 'streamCurrentUserProfile');
  }

  Future<void> createDriverProfile({
    required String name,
    required String vehicleId,
  }) async {
    final user = currentUser;
    if (user == null) throw StateError('No signed-in user');
    final profile = UserProfileModel(
      uid: user.uid,
      role: UserRole.driver,
      name: name,
      vehicleId: vehicleId,
      email: user.email,
      phone: user.phoneNumber,
      createdAt: DateTime.now(),
    );
    await _db.collection('users').doc(user.uid).set(profile.toFirestore());
  }

  Future<void> createStaffProfile({required String name}) async {
    final user = currentUser;
    if (user == null) throw StateError('No signed-in user');
    final profile = UserProfileModel(
      uid: user.uid,
      role: UserRole.hospitalStaff,
      name: name,
      email: user.email,
      phone: user.phoneNumber,
      createdAt: DateTime.now(),
    );
    await _db.collection('users').doc(user.uid).set(profile.toFirestore());
  }
}
