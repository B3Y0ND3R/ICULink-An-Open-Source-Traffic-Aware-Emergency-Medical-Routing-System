import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens for ICULink. One restrained accent (red — semantically
/// correct for an emergency app), a neutral near-black surface stack rather
/// than a tinted "futuristic dashboard" navy, and a single 8px-multiple
/// spacing/radius system used everywhere. Availability status (green) is a
/// functional signal, not a decorative accent — it only ever appears on bed
/// counts and status dots.
class AppColors {
  AppColors._();

  static const background = Color(0xFF0B0D0F);
  static const surface = Color(0xFF16181B);
  static const surfaceRaised = Color(0xFF1C1F23);
  static const border = Color(0xFF26282C);
  static const borderStrong = Color(0xFF34373C);

  static const accent = Color(0xFFE5484D);
  static const accentSubtle = Color(0x1FE5484D);

  static const success = Color(0xFF30A46C);
  static const successSubtle = Color(0x1F30A46C);

  static const textPrimary = Color(0xFFF3F4F6);
  static const textSecondary = Color(0xFF9B9DA3);
  static const textTertiary = Color(0xFF5C5F66);

  /// Reserved for the alarm overlay only — the one place a saturated,
  /// high-intensity red is actually earned (a real incoming-emergency
  /// alert), not decoration.
  static const alarm = Color(0xFFFF3B3B);
}

/// 8pt spacing scale. Use these instead of arbitrary padding values.
class AppSpacing {
  AppSpacing._();

  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

/// Two radii, used everywhere. Small for controls, medium for cards/sheets.
class AppRadius {
  AppRadius._();

  static const sm = 8.0;
  static const md = 12.0;
}

/// One elevation shadow — subtle, neutral, no color, no glow.
class AppShadow {
  AppShadow._();

  static const card = [
    BoxShadow(color: Color(0x66000000), blurRadius: 8, offset: Offset(0, 2)),
  ];
}

ThemeData buildAppTheme() {
  final base = ThemeData.dark();
  final textTheme = GoogleFonts.interTextTheme(base.textTheme).apply(
    bodyColor: AppColors.textPrimary,
    displayColor: AppColors.textPrimary,
  );

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.accent,
      secondary: AppColors.accent,
      surface: AppColors.surface,
      error: AppColors.accent,
    ),
    textTheme: textTheme.copyWith(
      headlineMedium: textTheme.headlineMedium?.copyWith(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
      ),
      titleLarge: textTheme.titleLarge?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      titleMedium: textTheme.titleMedium?.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: textTheme.bodyLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w400),
      bodyMedium: textTheme.bodyMedium?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: AppColors.textSecondary,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: AppColors.accent.withValues(alpha: 0.4),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: AppSpacing.lg),
        textStyle: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        textStyle: GoogleFonts.inter(fontWeight: FontWeight.w500, fontSize: 14),
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: const BorderSide(color: AppColors.border),
      ),
      elevation: 0,
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: 1,
      space: 1,
    ),
    iconTheme: const IconThemeData(color: AppColors.textSecondary, size: 20),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 14),
      labelStyle: GoogleFonts.inter(color: AppColors.textTertiary, fontSize: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: const BorderSide(color: AppColors.borderStrong, width: 1.5),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surfaceRaised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.surfaceRaised,
      contentTextStyle: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
