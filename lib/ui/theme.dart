import 'package:flutter/material.dart';

import '../engine/ludo/ludo_models.dart';

/// "The Green Room" design tokens.
///
/// One room, two surfaces: deep green felt for the table itself, and warm
/// cream paper for everything laid on it — menus, score sheets, rule books and
/// forms. Brass is the one metal in the room, used for selection, scores and
/// the small rules that keep the paper feeling printed rather than floating.
class AppColors {
  AppColors._();

  // ---------------------------------------------------------------- felt
  /// The room behind every screen. Deeper than the old tabletop green so the
  /// paper surfaces carry the light, the way they do in a real club room.
  static const felt = Color(0xFF0C1F17);
  static const feltDeep = Color(0xFF07140E);
  static const feltLight = Color(0xFF173A2A);
  static const feltGlow = Color(0xFF21503A);

  // --------------------------------------------------------------- paper
  static const paper = Color(0xFFF6EEDD);
  static const paperLight = Color(0xFFFCF7EC);
  static const paperDeep = Color(0xFFE9DDC5);
  static const paperEdge = Color(0xFFD6C7A9);

  // ------------------------------------------------------------------ ink
  static const ink = Color(0xFF1B2A21);
  static const inkSoft = Color(0xFF526055);
  static const inkFaint = Color(0xFF7D887D);

  // ---------------------------------------------------------------- brass
  static const gold = Color(0xFFD7B45D);
  static const brass = Color(0xFFBC9138);
  static const brassDeep = Color(0xFF856221);

  // -------------------------------------------------------------- accents
  static const danger = Color(0xFFB2473B);
  static const claret = Color(0xFF7B2F2F);
  static const sage = Color(0xFF7F9A80);

  // Back-compat aliases: the board painters and older screens speak in ivory.
  static const ivory = paper;
  static const ivoryDark = paperDeep;

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
    Color(0xFFC0392B),
    Color(0xFF2860A8),
    Color(0xFF1E8449),
    Color(0xFFD4A017),
    Color(0xFF7D3C98),
    Color(0xFFE67E22),
    Color(0xFF16A085),
    Color(0xFF2C3E50),
    Color(0xFFD81B60),
    Color(0xFF6D4C41),
  ];
}

class AppFonts {
  AppFonts._();

  static const display = 'Fraunces';
  static const body = 'Manrope';
}

/// The type scale is the same on felt and on paper; only the colours change.
/// Headings are Fraunces, body and controls Manrope, so a score and a sentence
/// never compete for the same voice.
TextTheme _typeScale(Color primary, Color secondary) {
  TextStyle display(double size, FontWeight weight) => TextStyle(
    fontFamily: AppFonts.display,
    fontSize: size,
    fontWeight: weight,
    height: 1.06,
    letterSpacing: -0.4,
    color: primary,
  );
  TextStyle sans(double size, FontWeight weight, {double height = 1.45}) =>
      TextStyle(
        fontFamily: AppFonts.body,
        fontSize: size,
        fontWeight: weight,
        height: height,
        color: primary,
      );

  return TextTheme(
    displayLarge: display(60, FontWeight.w600),
    displayMedium: display(46, FontWeight.w600),
    displaySmall: display(36, FontWeight.w600),
    headlineLarge: display(31, FontWeight.w600),
    headlineMedium: display(26, FontWeight.w600),
    headlineSmall: display(22, FontWeight.w600),
    titleLarge: display(20, FontWeight.w600),
    titleMedium: sans(16, FontWeight.w700, height: 1.3),
    titleSmall: sans(14, FontWeight.w700, height: 1.3),
    bodyLarge: sans(16, FontWeight.w400, height: 1.55),
    bodyMedium: sans(14, FontWeight.w400),
    bodySmall: sans(12, FontWeight.w400),
    labelLarge: sans(14, FontWeight.w800, height: 1.2),
    labelMedium: sans(12, FontWeight.w700, height: 1.2),
    labelSmall: TextStyle(
      fontFamily: AppFonts.body,
      fontSize: 10.5,
      fontWeight: FontWeight.w800,
      height: 1.2,
      letterSpacing: 1.5,
      color: secondary,
    ),
  );
}

class AppTheme {
  AppTheme._();

  /// The room: deep felt, cream type, brass controls.
  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: AppColors.gold,
      onPrimary: AppColors.ink,
      primaryContainer: AppColors.brassDeep,
      onPrimaryContainer: AppColors.paperLight,
      secondary: AppColors.paperDeep,
      onSecondary: AppColors.ink,
      tertiary: AppColors.sage,
      onTertiary: AppColors.ink,
      surface: AppColors.felt,
      onSurface: AppColors.paper,
      surfaceContainerHighest: AppColors.feltLight,
      onSurfaceVariant: AppColors.paperDeep,
      outline: AppColors.brass,
      outlineVariant: Color(0x55D7B45D),
      error: AppColors.danger,
      onError: Colors.white,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      fontFamily: AppFonts.body,
      scaffoldBackgroundColor: AppColors.felt,
      canvasColor: AppColors.felt,
      splashColor: AppColors.gold.withValues(alpha: 0.12),
      highlightColor: AppColors.gold.withValues(alpha: 0.06),
    );

    return base.copyWith(
      textTheme: _typeScale(AppColors.paper, AppColors.gold),
      primaryTextTheme: _typeScale(AppColors.ink, AppColors.brassDeep),
      iconTheme: const IconThemeData(color: AppColors.paper, size: 22),
      dividerTheme: DividerThemeData(
        color: AppColors.paper.withValues(alpha: 0.12),
        thickness: 1,
        space: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.felt,
        foregroundColor: AppColors.paper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 64,
        iconTheme: const IconThemeData(color: AppColors.paper, size: 22),
        actionsIconTheme: const IconThemeData(color: AppColors.paper, size: 22),
        titleTextStyle: const TextStyle(
          fontFamily: AppFonts.display,
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
          color: AppColors.paper,
        ),
        shape: Border(
          bottom: BorderSide(color: AppColors.gold.withValues(alpha: 0.22)),
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.feltLight,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: AppColors.paper.withValues(alpha: 0.10)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.gold,
          foregroundColor: AppColors.ink,
          disabledBackgroundColor: AppColors.paper.withValues(alpha: 0.12),
          disabledForegroundColor: AppColors.paper.withValues(alpha: 0.38),
          elevation: 0,
          minimumSize: const Size(44, 48),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          textStyle: const TextStyle(
            fontFamily: AppFonts.body,
            fontSize: 14,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.paper,
          backgroundColor: AppColors.paper.withValues(alpha: 0.035),
          side: BorderSide(color: AppColors.gold.withValues(alpha: 0.55)),
          minimumSize: const Size(44, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          textStyle: const TextStyle(
            fontFamily: AppFonts.body,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.gold,
          minimumSize: const Size(44, 44),
          textStyle: const TextStyle(
            fontFamily: AppFonts.body,
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: AppColors.paper,
          minimumSize: const Size(44, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.feltLight,
        selectedColor: AppColors.gold,
        disabledColor: AppColors.feltLight,
        side: BorderSide(color: AppColors.paper.withValues(alpha: 0.16)),
        shape: const StadiumBorder(),
        labelStyle: const TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.paper,
        ),
        secondaryLabelStyle: const TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: AppColors.ink,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        showCheckmark: false,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? AppColors.ink
                : AppColors.paper,
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? AppColors.gold
                : AppColors.paper.withValues(alpha: 0.04),
          ),
          side: WidgetStatePropertyAll(
            BorderSide(color: AppColors.gold.withValues(alpha: 0.42)),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontFamily: AppFonts.body,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.paperLight,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        labelStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.inkSoft,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
        floatingLabelStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.brassDeep,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
        hintStyle: TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.inkFaint.withValues(alpha: 0.8),
          fontSize: 13.5,
        ),
        errorStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.danger,
          fontSize: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.paperEdge),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.paperEdge),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.brass, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.danger, width: 1.6),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.gold
              : AppColors.paper,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.gold.withValues(alpha: 0.38)
              : AppColors.paper.withValues(alpha: 0.12),
        ),
        trackOutlineColor: WidgetStatePropertyAll(
          AppColors.paper.withValues(alpha: 0.20),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.gold,
        linearTrackColor: Color(0x33F6EEDD),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.paper,
        contentTextStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.ink,
          fontWeight: FontWeight.w600,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.feltLight,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: AppColors.gold.withValues(alpha: 0.30)),
        ),
        titleTextStyle: const TextStyle(
          fontFamily: AppFonts.display,
          fontSize: 23,
          fontWeight: FontWeight.w600,
          color: AppColors.paper,
        ),
        contentTextStyle: TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 14.5,
          height: 1.5,
          color: AppColors.paper.withValues(alpha: 0.82),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.feltLight,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.gold,
        textColor: AppColors.paper,
        minVerticalPadding: 10,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.paper,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.ink,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          AppColors.paper.withValues(alpha: 0.26),
        ),
        radius: const Radius.circular(99),
        thickness: const WidgetStatePropertyAll(6),
      ),
    );
  }

  /// A sheet of club paper. Used by [ClubCard] to give its subtree a light,
  /// ink-based material theme, so defaults inside a paper card never inherit
  /// the room's cream-on-felt colours.
  static ThemeData paper() {
    const scheme = ColorScheme.light(
      primary: AppColors.brassDeep,
      onPrimary: AppColors.paperLight,
      secondary: AppColors.claret,
      onSecondary: AppColors.paperLight,
      surface: AppColors.paper,
      onSurface: AppColors.ink,
      surfaceContainerHighest: AppColors.paperDeep,
      onSurfaceVariant: AppColors.inkSoft,
      outline: AppColors.paperEdge,
      error: AppColors.claret,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      fontFamily: AppFonts.body,
      scaffoldBackgroundColor: AppColors.paper,
      canvasColor: AppColors.paper,
    );
    return base.copyWith(
      textTheme: _typeScale(AppColors.ink, AppColors.brassDeep),
      primaryTextTheme: _typeScale(AppColors.paperLight, AppColors.gold),
      iconTheme: const IconThemeData(color: AppColors.inkSoft, size: 22),
      dividerTheme: DividerThemeData(
        color: AppColors.ink.withValues(alpha: 0.10),
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.ink,
          foregroundColor: AppColors.paperLight,
          disabledBackgroundColor: AppColors.ink.withValues(alpha: 0.12),
          disabledForegroundColor: AppColors.ink.withValues(alpha: 0.38),
          elevation: 0,
          minimumSize: const Size(44, 48),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          textStyle: const TextStyle(
            fontFamily: AppFonts.body,
            fontSize: 14,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink,
          side: BorderSide(color: AppColors.ink.withValues(alpha: 0.28)),
          minimumSize: const Size(44, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          textStyle: const TextStyle(
            fontFamily: AppFonts.body,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.brassDeep,
          minimumSize: const Size(44, 44),
          textStyle: const TextStyle(
            fontFamily: AppFonts.body,
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.paperDeep,
        selectedColor: AppColors.gold,
        side: BorderSide(color: AppColors.ink.withValues(alpha: 0.12)),
        shape: const StadiumBorder(),
        labelStyle: const TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.ink,
        ),
        secondaryLabelStyle: const TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: AppColors.ink,
        ),
        showCheckmark: false,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? AppColors.ink
                : AppColors.inkSoft,
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? AppColors.gold
                : AppColors.paperLight,
          ),
          side: WidgetStatePropertyAll(
            BorderSide(color: AppColors.ink.withValues(alpha: 0.16)),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontFamily: AppFonts.body,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.paperLight,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        labelStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.inkSoft,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
        floatingLabelStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.brassDeep,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
        hintStyle: TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.inkFaint.withValues(alpha: 0.72),
          fontSize: 13.5,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.paperEdge),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.paperEdge),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.brass, width: 1.6),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.brassDeep
              : AppColors.paperLight,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.gold.withValues(alpha: 0.55)
              : AppColors.ink.withValues(alpha: 0.12),
        ),
        trackOutlineColor: WidgetStatePropertyAll(
          AppColors.ink.withValues(alpha: 0.14),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.brassDeep,
        linearTrackColor: Color(0x221B2A21),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.ink,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.paper,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
