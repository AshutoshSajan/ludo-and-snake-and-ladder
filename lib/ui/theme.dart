import 'package:flutter/material.dart';

import '../engine/ludo/ludo_models.dart';

/// "The Green Room" design tokens, in the club's old gold-and-green livery.
///
/// One room, one material: deep green felt for every surface, warm ivory type
/// and a single brass accent. There is deliberately no paper-white layer in
/// this theme — cards are raised green felt, separated by hairline brass rules,
/// so the room stays a room even on a bright monitor.
class AppColors {
  AppColors._();

  // ---------------------------------------------------------------- felt
  /// The room behind every screen.
  static const felt = Color(0xFF123524);
  static const feltDeep = Color(0xFF0A2015);
  static const feltLight = Color(0xFF1B4A33);
  static const feltGlow = Color(0xFF21573D);

  // ------------------------------------------------------------- surfaces
  /// A card laid on the felt: green, not paper.
  static const surface = Color(0xFF1B4A33);
  static const surfaceRaised = Color(0xFF23573D);
  static const surfaceDeep = Color(0xFF153F2C);

  /// The recessed fill inside a form field.
  static const input = Color(0xFF0F2E20);

  // ------------------------------------------------------------------ type
  static const ivory = Color(0xFFF5EFE0);
  static const textPrimary = ivory;
  static const textSecondary = Color(0xFFD6D0BE);
  static const textMuted = Color(0xFFB5B3A2);

  /// Ink for marks printed on gold or on an ivory board. Never use this for
  /// type on the felt — use [textPrimary].
  static const darkInk = Color(0xFF26221A);
  static const darkInkSoft = Color(0xFF574B2C);

  // ----------------------------------------------------------------- gold
  static const gold = Color(0xFFD9A441);
  static const brass = Color(0xFFC29232);
  static const brassDeep = Color(0xFF8B651D);

  // -------------------------------------------------------------- accents
  static const danger = Color(0xFFD46A5E);
  static const claret = Color(0xFF7B2F2F);
  static const sage = Color(0xFF8FAF91);

  // Back-compat aliases. "Paper" is gone as a surface; these names now carry
  // the ivory type and hairline rules that used to live on it.
  static const paper = ivory;
  static const paperLight = Color(0xFFFCF7EC);
  static const paperDeep = textSecondary;
  static const paperEdge = Color(0x66D9A441);
  static const ivoryDark = textSecondary;

  // Ink aliases kept for the board painters, which still print dark lines on
  // an ivory board.
  static const ink = darkInk;
  static const inkSoft = darkInkSoft;
  static const inkFaint = Color(0xFF8B8068);

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

/// The type scale is the same on every surface; only the colours change.
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

  /// The room: deep felt, ivory type, brass controls.
  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: AppColors.gold,
      onPrimary: AppColors.darkInk,
      primaryContainer: AppColors.brassDeep,
      onPrimaryContainer: AppColors.ivory,
      secondary: AppColors.gold,
      onSecondary: AppColors.darkInk,
      tertiary: AppColors.sage,
      onTertiary: AppColors.darkInk,
      surface: AppColors.felt,
      onSurface: AppColors.ivory,
      surfaceContainerHighest: AppColors.surfaceRaised,
      onSurfaceVariant: AppColors.paperDeep,
      outline: AppColors.brass,
      outlineVariant: Color(0x55D9A441),
      error: AppColors.danger,
      onError: AppColors.ivory,
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
      textTheme: _typeScale(AppColors.textPrimary, AppColors.gold),
      primaryTextTheme: _typeScale(AppColors.darkInk, AppColors.darkInkSoft),
      iconTheme: const IconThemeData(color: AppColors.ivory, size: 22),
      dividerTheme: DividerThemeData(
        color: AppColors.ivory.withValues(alpha: 0.12),
        thickness: 1,
        space: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.felt,
        foregroundColor: AppColors.ivory,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 64,
        iconTheme: const IconThemeData(color: AppColors.ivory, size: 22),
        actionsIconTheme: const IconThemeData(color: AppColors.ivory, size: 22),
        titleTextStyle: const TextStyle(
          fontFamily: AppFonts.display,
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
          color: AppColors.ivory,
        ),
        shape: Border(
          bottom: BorderSide(color: AppColors.gold.withValues(alpha: 0.22)),
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: AppColors.gold.withValues(alpha: 0.22)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.gold,
          foregroundColor: AppColors.darkInk,
          disabledBackgroundColor: AppColors.ivory.withValues(alpha: 0.10),
          disabledForegroundColor: AppColors.ivory.withValues(alpha: 0.38),
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
          foregroundColor: AppColors.ivory,
          backgroundColor: AppColors.surfaceRaised.withValues(alpha: 0.35),
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
          foregroundColor: AppColors.ivory,
          minimumSize: const Size(44, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.gold,
        foregroundColor: AppColors.darkInk,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surfaceRaised,
        selectedColor: AppColors.gold,
        disabledColor: AppColors.surfaceDeep,
        side: BorderSide(color: AppColors.gold.withValues(alpha: 0.28)),
        shape: const StadiumBorder(),
        labelStyle: const TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.ivory,
        ),
        secondaryLabelStyle: const TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: AppColors.darkInk,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        showCheckmark: false,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? AppColors.darkInk
                : AppColors.ivory,
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? AppColors.gold
                : AppColors.surfaceRaised.withValues(alpha: 0.45),
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
        fillColor: AppColors.input,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        labelStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.textSecondary,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
        floatingLabelStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.gold,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
        hintStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.textMuted,
          fontSize: 13.5,
        ),
        helperStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.textMuted,
          fontSize: 12,
        ),
        counterStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.textMuted,
          fontSize: 11,
        ),
        errorStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.danger,
          fontSize: 12,
        ),
        prefixIconColor: AppColors.textSecondary,
        suffixIconColor: AppColors.textSecondary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.gold.withValues(alpha: 0.28)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.gold.withValues(alpha: 0.28)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.gold, width: 1.6),
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
              ? AppColors.darkInk
              : AppColors.paperLight,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.gold.withValues(alpha: 0.55)
              : AppColors.ivory.withValues(alpha: 0.12),
        ),
        trackOutlineColor: WidgetStatePropertyAll(
          AppColors.ivory.withValues(alpha: 0.20),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.gold
              : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(AppColors.darkInk),
        side: BorderSide(color: AppColors.gold.withValues(alpha: 0.55)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.gold
              : AppColors.textSecondary,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.gold,
        linearTrackColor: Color(0x33F5EFE0),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.gold,
        contentTextStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.darkInk,
          fontWeight: FontWeight.w700,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: AppColors.gold.withValues(alpha: 0.30)),
        ),
        titleTextStyle: const TextStyle(
          fontFamily: AppFonts.display,
          fontSize: 23,
          fontWeight: FontWeight.w600,
          color: AppColors.ivory,
        ),
        contentTextStyle: const TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 14.5,
          height: 1.5,
          color: AppColors.textSecondary,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.gold,
        textColor: AppColors.ivory,
        minVerticalPadding: 10,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        textStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.ivory,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: AppColors.gold.withValues(alpha: 0.28)),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.ivory,
        ),
        menuStyle: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(
            AppColors.surfaceRaised,
          ),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: AppColors.gold.withValues(alpha: 0.28)),
            ),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.feltDeep,
        indicatorColor: AppColors.gold,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? AppColors.darkInk
                : AppColors.textSecondary,
            size: 22,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontFamily: AppFonts.body,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: states.contains(WidgetState.selected)
                ? AppColors.gold
                : AppColors.textSecondary,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: AppColors.feltDeep,
        indicatorColor: AppColors.gold,
        selectedIconTheme: const IconThemeData(color: AppColors.darkInk),
        unselectedIconTheme: const IconThemeData(
          color: AppColors.textSecondary,
        ),
        selectedLabelTextStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.gold,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.gold.withValues(alpha: 0.28)),
        ),
        textStyle: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.ivory,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          AppColors.gold.withValues(alpha: 0.34),
        ),
        radius: const Radius.circular(99),
        thickness: const WidgetStatePropertyAll(6),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: AppColors.gold,
        selectionColor: AppColors.gold.withValues(alpha: 0.30),
        selectionHandleColor: AppColors.gold,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: AppColors.gold,
        thumbColor: AppColors.gold,
        inactiveTrackColor: AppColors.ivory.withValues(alpha: 0.12),
      ),
    );
  }
}
