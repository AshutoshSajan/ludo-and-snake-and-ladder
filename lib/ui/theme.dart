import 'package:flutter/material.dart';

import '../engine/ludo/ludo_models.dart';

/// "Tabletop club" design tokens: deep felt table, ivory boards, lacquered
/// quadrant colors.
class AppColors {
  AppColors._();

  static const felt = Color(0xFF123524); // deep felt green
  static const feltLight = Color(0xFF1B4A33);
  static const ivory = Color(0xFFF5EFE0);
  static const ivoryDark = Color(0xFFE5DCC3);
  static const ink = Color(0xFF26221A);
  static const gold = Color(0xFFD9A441);
  static const danger = Color(0xFFB3382E);

  static const ludoRed = Color(0xFFC0392B);
  static const ludoGreen = Color(0xFF1E8449);
  static const ludoYellow = Color(0xFFD4A017);
  static const ludoBlue = Color(0xFF2860A8);

  static Color ludo(LudoColor c) => switch (c) {
        LudoColor.red => ludoRed,
        LudoColor.green => ludoGreen,
        LudoColor.yellow => ludoYellow,
        LudoColor.blue => ludoBlue,
      };

  /// The 10 pawn colors for Snakes & Ladders (up to 10 players).
  static const snakesColors = [
    Color(0xFFC0392B), Color(0xFF2860A8), Color(0xFF1E8449),
    Color(0xFFD4A017), Color(0xFF7D3C98), Color(0xFFE67E22),
    Color(0xFF16A085), Color(0xFF2C3E50), Color(0xFFD81B60),
    Color(0xFF6D4C41),
  ];
}

class AppTheme {
  AppTheme._();

  static ThemeData dark() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.gold,
        onPrimary: AppColors.ink,
        secondary: AppColors.gold,
        surface: AppColors.felt,
        onSurface: AppColors.ivory,
        error: AppColors.danger,
      ),
      scaffoldBackgroundColor: AppColors.felt,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: AppColors.ivory,
        displayColor: AppColors.ivory,
      ),
      cardTheme: CardThemeData(
        color: AppColors.feltLight,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.gold,
          foregroundColor: AppColors.ink,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ivory,
          side: const BorderSide(color: AppColors.gold),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.feltLight,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AppColors.ivory,
        contentTextStyle: TextStyle(color: AppColors.ink),
      ),
    );
  }
}
