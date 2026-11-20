import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'auth_service.dart';

/// Handles push-notification permission, foreground display, and FCM token
/// registration. Actual sending happens server-side (a Cloud Function
/// triggered on new/updated `bookings` documents — see functions/index.js);
/// this service only manages the client side: requesting permission,
/// keeping this device's token current on the signed-in user's profile,
/// and showing a heads-up notification while the app is in the foreground
/// (bare FCM messages don't auto-display one on Android while foregrounded).
class NotificationService {
  NotificationService._internal();
  static final NotificationService instance = NotificationService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static const _channel = AndroidNotificationChannel(
    'iculink_bookings',
    'Incoming Ambulances',
    description: 'Alerts when an ambulance is dispatched to your hospital.',
    importance: Importance.max,
  );

  bool _initialized = false;
  StreamSubscription<String>? _tokenRefreshSub;

  /// One-time setup: request permission, create the Android notification
  /// channel, and wire up the foreground message listener. Safe to call
  /// multiple times — only runs once.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    await _messaging.requestPermission(alert: true, badge: true, sound: true);

    // flutter_local_notifications has no web implementation; on web the
    // browser's own FCM handling is used instead.
    if (kIsWeb) return;

    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);

    await _localNotifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );

    FirebaseMessaging.onMessage.listen(_showForegroundNotification);
  }

  void _showForegroundNotification(RemoteMessage message) {
    final notification = message.notification;
    if (notification == null) return;
    _localNotifications.show(
      notification.hashCode,
      notification.title,
      notification.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
    );
  }

  /// Fetches this device's current FCM token and adds it to the signed-in
  /// user's `fcm_tokens` array (a device may have multiple tokens over
  /// time, e.g. after a reinstall — arrayUnion avoids duplicates without
  /// clobbering tokens from other devices the same account is signed into).
  /// Also re-registers automatically whenever the token rotates.
  Future<void> registerTokenForCurrentUser() async {
    final uid = AuthService.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      final token = await _messaging.getToken();
      if (token != null) {
        await _addToken(uid, token);
      }
    } catch (e) {
      debugPrint('registerTokenForCurrentUser error: $e');
    }

    // Replace (not stack) the refresh listener — this method runs every time
    // the staff dashboard mounts.
    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = _messaging.onTokenRefresh.listen((newToken) async {
      final currentUid = AuthService.instance.currentUser?.uid;
      if (currentUid == null) return;
      try {
        await _addToken(currentUid, newToken);
      } catch (e) {
        debugPrint('onTokenRefresh error: $e');
      }
    });
  }

  Future<void> _addToken(String uid, String token) async {
    await _db.collection('users').doc(uid).update({
      'fcm_tokens': FieldValue.arrayUnion([token]),
    });
  }
}
