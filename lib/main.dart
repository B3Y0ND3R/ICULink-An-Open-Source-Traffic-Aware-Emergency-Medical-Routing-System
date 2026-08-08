import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/auth_gate.dart';
import 'services/notification_service.dart';
import 'theme/app_theme.dart';
import 'firebase_options.dart';

/// Handles FCM messages that arrive while the app is fully backgrounded or
/// terminated. Must be a top-level (or static) function — Dart isolate
/// entry points can't be instance methods — and Firebase must already be
/// initialized inside it, since it may run in a fresh isolate with no
/// prior app state.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait on phones; allow landscape on tablets/web
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0B0D0F),
  ));

  // ── Initialize Firebase
  //
  // NOTE: hospital seeding is intentionally NOT triggered here anymore.
  // FirebaseService.seedInitialHospitals() ran unauthenticated at every app
  // launch, which is incompatible with firestore.rules once deployed
  // (reads require an authenticated user, and hospital document creation is
  // denied entirely from the client by design — see firestore.rules). It's
  // now a one-time manual/admin operation: call it once yourself (e.g. from
  // a debug console or a short-lived script) before rules are enforced, or
  // add hospital documents directly via the Firebase Console.
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    await NotificationService.instance.initialize();
  } catch (e) {
    debugPrint('Firebase init failed: $e');
  }

  runApp(const ICULinkApp());
}

class ICULinkApp extends StatelessWidget {
  const ICULinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ICULink – Emergency Medical Routing',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const AuthGate(),
    );
  }
}
