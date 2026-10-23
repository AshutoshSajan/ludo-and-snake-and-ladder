import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// The room itself: a deep felt gradient with the quiet tooth of a real table.
///
/// Painted rather than imaged so it scales to any window and adds no asset to
/// the web bundle. The speckle is deliberately faint — it should be felt more
/// than seen, and it must never compete with a board on top of it.
class ClubBackground extends StatelessWidget {
  const ClubBackground({super.key, required this.child, this.vignette = true});

  final Widget child;
  final bool vignette;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.42),
          radius: 1.35,
          colors: [AppColors.feltGlow, AppColors.felt],
          stops: [0, 0.72],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: CustomPaint(painter: _FeltPainter(vignette: vignette)),
          ),
          child,
        ],
      ),
    );
  }
}

class _FeltPainter extends CustomPainter {
  const _FeltPainter({required this.vignette});

  final bool vignette;

  @override
  void paint(Canvas canvas, Size size) {
    // A deterministic speckle. The same table every launch, no random repaint
    // and no per-frame allocation.
    final random = math.Random(1908);
    final speck = Paint();
    for (var i = 0; i < 460; i++) {
      final dx = random.nextDouble() * size.width;
      final dy = random.nextDouble() * size.height;
      final light = random.nextBool();
      speck.color = (light ? Colors.white : Colors.black).withValues(
        alpha: light ? 0.018 : 0.022,
      );
      canvas.drawCircle(Offset(dx, dy), random.nextDouble() * 1.2 + 0.3, speck);
    }
    if (!vignette) return;
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 0.88,
          colors: [
            Colors.transparent,
            AppColors.feltDeep.withValues(alpha: 0.42),
          ],
          stops: const [0.55, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_FeltPainter oldDelegate) =>
      oldDelegate.vignette != vignette;
}

/// A sheet of club paper laid on the felt.
///
/// Every menu surface is one of these: a warm ground, a hairline brass edge
/// and a soft drop shadow. Wrapping its subtree in [AppTheme.paper] is what
/// makes ordinary Material widgets — switches, fields, segmented controls —
/// inherit ink-on-paper rather than cream-on-felt, so a screen can be assembled
/// from stock parts and still belong in the room.
class ClubCard extends StatelessWidget {
  const ClubCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.accent = false,
    this.radius = 20,
    this.background = AppColors.paper,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  /// A fine brass rule along the top edge, for the one card on a screen that
  /// should read as the menu's headline.
  final bool accent;
  final double radius;
  final Color background;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    final body = Stack(
      children: [
        if (accent)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Container(
              height: 3,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.brassDeep,
                    AppColors.gold,
                    AppColors.brassDeep,
                  ],
                ),
              ),
            ),
          ),
        Padding(
          padding: padding,
          child: onTap == null ? child : InkWell(onTap: onTap, child: child),
        ),
      ],
    );

    // A real [Card] rather than a decorated box: it keeps the club's paper
    // surfaces in the same widget family as every older card in the app, and
    // it gives the Material layer that an InkWell needs for its ripple.
    final paper = Theme(
      data: AppTheme.paper(),
      child: DefaultTextStyle.merge(
        style: const TextStyle(
          fontFamily: AppFonts.body,
          color: AppColors.ink,
          fontSize: 14,
          height: 1.45,
        ),
        child: Card(
          color: background,
          surfaceTintColor: Colors.transparent,
          elevation: 8,
          shadowColor: AppColors.feltDeep.withValues(alpha: 0.45),
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: shape,
            side: BorderSide(
              color: borderColor ?? AppColors.paperEdge.withValues(alpha: 0.9),
            ),
          ),
          child: body,
        ),
      ),
    );

    return paper;
  }
}

/// A small brass seal for a section's icon: the club's version of a crest.
class ClubSeal extends StatelessWidget {
  const ClubSeal({
    super.key,
    required this.icon,
    this.size = 44,
    this.onPaper = true,
  });

  final IconData icon;
  final double size;
  final bool onPaper;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: onPaper
            ? AppColors.paperDeep.withValues(alpha: 0.72)
            : AppColors.gold.withValues(alpha: 0.12),
        border: Border.all(
          color: AppColors.brass.withValues(alpha: 0.55),
          width: 1.2,
        ),
      ),
      child: Icon(
        icon,
        size: size * 0.48,
        color: onPaper ? AppColors.brassDeep : AppColors.gold,
      ),
    );
  }
}

/// The eyebrow, title and one-line invitation at the top of a paper page.
class ClubPageHeader extends StatelessWidget {
  const ClubPageHeader({
    super.key,
    required this.title,
    this.eyebrow,
    this.subtitle,
    this.icon,
    this.trailing,
    this.titleColor,
    this.subtitleColor,
  });

  final String title;
  final String? eyebrow;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final Color? titleColor;
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onPaper = theme.brightness == Brightness.light;
    final ink = titleColor ?? (onPaper ? AppColors.ink : AppColors.paper);
    final soft =
        subtitleColor ?? (onPaper ? AppColors.inkSoft : AppColors.paperDeep);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (eyebrow != null) ...[
          Text(
            eyebrow!.toUpperCase(),
            style: TextStyle(
              fontFamily: AppFonts.body,
              color: onPaper ? AppColors.brassDeep : AppColors.gold,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.8,
            ),
          ),
          const SizedBox(height: 6),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (icon != null) ...[
              ClubSeal(icon: icon!, onPaper: onPaper),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: ink,
                  height: 1.08,
                ),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 7),
          Text(
            subtitle!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: soft,
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }
}

/// An uppercase caption followed by a hairline, so sections read as chapters
/// in a printed programme rather than as another card header.
class ClubSectionLabel extends StatelessWidget {
  const ClubSectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        children: [
          Text(
            text.toUpperCase(),
            style: TextStyle(
              fontFamily: AppFonts.body,
              color: accent,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.7,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 1,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.13),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
  }
}

/// A number set in Fraunces with a small Manrope caption: the score-sheet atom.
class ClubStat extends StatelessWidget {
  const ClubStat({
    super.key,
    required this.value,
    required this.label,
    this.accent,
    this.alignment = CrossAxisAlignment.center,
  });

  final String value;
  final String label;
  final Color? accent;
  final CrossAxisAlignment alignment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onPaper = theme.brightness == Brightness.light;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignment,
      children: [
        Text(
          value,
          style: theme.textTheme.headlineSmall?.copyWith(
            color: accent ?? theme.colorScheme.onSurface,
            height: 1,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontFamily: AppFonts.body,
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            color: onPaper ? AppColors.inkFaint : AppColors.paperDeep,
          ),
        ),
      ],
    );
  }
}

/// A selectable paper pill used for game filters and table sizes.
class ClubPill extends StatelessWidget {
  const ClubPill({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onPaper = theme.brightness == Brightness.light;
    final bg = selected
        ? AppColors.gold
        : (onPaper ? AppColors.paperLight : AppColors.feltLight);
    final fg = selected
        ? AppColors.ink
        : (onPaper ? AppColors.inkSoft : AppColors.paper);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? AppColors.brassDeep.withValues(alpha: 0.42)
                  : theme.colorScheme.onSurface.withValues(alpha: 0.14),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontFamily: AppFonts.body,
                  color: fg,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A quiet line of copy with an icon, used for the one instruction a page owes
/// the player ("tap to copy", "share this code").
class ClubNote extends StatelessWidget {
  const ClubNote(this.text, {super.key, this.icon = Icons.info_outline});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onPaper = theme.brightness == Brightness.light;
    final color = onPaper ? AppColors.inkSoft : AppColors.paperDeep;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}
