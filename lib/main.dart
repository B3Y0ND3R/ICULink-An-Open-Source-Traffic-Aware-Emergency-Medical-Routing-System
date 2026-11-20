import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
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

  // Portrait plus both landscape orientations (tablets / web ER panel)
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
  // Hospitals are created in-app by staff (Add Hospital) or directly in the
  // Firebase Console; there is no client-side seeding, because firestore.rules
  // only lets a signed-in user create a hospital that lists themselves as
  // its owner.
  var firebaseReady = false;
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    firebaseReady = true;
  } catch (e) {
    debugPrint('Firebase init failed: $e');
  }

  if (!firebaseReady) {
    // Every screen needs Firebase Auth/Firestore — show a clear message
    // instead of crashing into a red error screen.
    runApp(const _StartupErrorApp());
    return;
  }

  // Push notifications are best-effort; the app is fully usable without.
  try {
    if (!kIsWeb) {
      FirebaseMessaging.onBackgroundMessage(
          _firebaseMessagingBackgroundHandler);
    }
    await NotificationService.instance.initialize();
  } catch (e) {
    debugPrint('Notification setup failed: $e');
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

class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'ICULink could not connect to its backend. '
              'Check your internet connection and restart the app.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
