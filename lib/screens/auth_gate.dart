import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../models/user_profile_model.dart';
import '../services/auth_service.dart';
import 'ambulance_screen.dart';
import 'hospital_screen.dart';
import 'auth/login_screen.dart';
import 'role_selection_screen.dart';

/// Root widget: routes between the login screen, one-time role selection,
/// and the correct driver/staff home screen based on Firebase Auth state
/// and the presence/role of a `users/{uid}` profile document.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: AuthService.instance.authStateChanges(),
      builder: (context, authSnapshot) {
        if (authSnapshot.connectionState == ConnectionState.waiting) {
          return const _SplashScreen();
        }

        final user = authSnapshot.data;
        if (user == null) {
          return const LoginScreen();
        }

        return StreamBuilder<UserProfileModel?>(
          stream: AuthService.instance.streamCurrentUserProfile(),
          builder: (context, profileSnapshot) {
            if (profileSnapshot.connectionState == ConnectionState.waiting) {
              return const _SplashScreen();
            }

            final profile = profileSnapshot.data;
            if (profile == null) {
              // Signed in, but hasn't finished registration yet.
              return const RoleSelectionScreen();
            }

            return profile.role == UserRole.driver
                ? const AmbulanceScreen()
                : const HospitalScreen();
          },
        );
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF050A18),
      body: Center(
        child: CircularProgressIndicator(color: Color(0xFFFF1744)),
      ),
    );
  }
}
