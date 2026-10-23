import 'package:flutter/material.dart';

import '../services/sound_service.dart';
import '../ui/club_widgets.dart';
import '../ui/theme.dart';

/// The club's wordmark: a painted die, the room's name and one warm line.
class ClubHeader extends StatelessWidget {
  const ClubHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // A painted die, not a glyph. This was Text('🎲'), and it rendered
            // as a tofu box inside the packaged add-on: only Roboto,
            // MaterialIcons and CupertinoIcons are bundled, and Roboto carries
            // no emoji, so there is no fallback to find one. Painting it also
            // matches the popup's CSS die.
            Container(
              width: 64,
              height: 64,
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: AppColors.paper,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: AppColors.gold.withValues(alpha: 0.72),
                  width: 1.4,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.feltDeep.withValues(alpha: 0.40),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const CustomPaint(painter: _DiePainter()),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'THE GREEN ROOM',
                    style: TextStyle(
                      fontFamily: AppFonts.body,
                      color: AppColors.gold.withValues(alpha: 0.95),
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Game Club',
                    style: theme.textTheme.displaySmall?.copyWith(
                      color: AppColors.paper,
                      fontSize: 38,
                      height: 1,
                      letterSpacing: -0.8,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Ludo & Snakes and Ladders, played around one table.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppColors.paperDeep.withValues(alpha: 0.78),
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Container(
              width: 28,
              height: 1,
              color: AppColors.gold.withValues(alpha: 0.55),
            ),
            const SizedBox(width: 10),
            Text(
              'CHOOSE YOUR TABLE',
              style: TextStyle(
                fontFamily: AppFonts.body,
                color: AppColors.gold.withValues(alpha: 0.82),
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.8,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The four-pip die above the "Game Club" wordmark.
///
/// Drawn rather than typed, because a glyph needs a font and the packaged
/// add-on bundles only Roboto, which has no die. Same shape as the CSS die in
/// `extension/popup.html`: an ivory rounded square with a gold border and four
/// pips, two red and two blue, so the header and the popup read as one mark.
class _DiePainter extends CustomPainter {
  const _DiePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final body = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(w * 0.22),
    );
    canvas.drawRRect(body, Paint()..color = AppColors.paperLight);
    canvas.drawRRect(
      body,
      Paint()
        ..color = AppColors.gold
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.055,
    );

    // Pips on a 2x2 grid: red top-left and bottom-right, blue the others.
    // Laid out from the centre so the spacing holds at any size.
    final r = w * 0.082;
    final dx = w * 0.27;
    final dy = h * 0.27;
    void pip(double x, double y, Color c) =>
        canvas.drawCircle(Offset(x, y), r, Paint()..color = c);

    pip(dx, dy, const Color(0xffb3372f));
    pip(w - dx, dy, const Color(0xff2f5fb3));
    pip(dx, h - dy, const Color(0xff2f5fb3));
    pip(w - dx, h - dy, const Color(0xffb3372f));
  }

  @override
  bool shouldRepaint(_DiePainter oldDelegate) => false;
}

/// One table on the menu: a painted board, its name, and the promise the room
/// makes. Paper on felt, with the board recessed into its own dark frame.
class GameCard extends StatelessWidget {
  const GameCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.preview,
    required this.onTap,
    this.eyebrow,
    this.meta = const [],
  });

  final String title;
  final String subtitle;
  final Widget preview;
  final VoidCallback onTap;
  final String? eyebrow;
  final List<String> meta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClubCard(
      accent: true,
      padding: EdgeInsets.zero,
      onTap: () {
        Haptics.light();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Row(
          children: [
            Container(
              width: 104,
              height: 104,
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.feltLight, AppColors.feltDeep],
                ),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(
                  color: AppColors.gold.withValues(alpha: 0.28),
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.feltDeep.withValues(alpha: 0.32),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: FittedBox(child: preview),
              ),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (eyebrow != null)
                        Text(
                          eyebrow!.toUpperCase(),
                          style: TextStyle(
                            fontFamily: AppFonts.body,
                            color: AppColors.brassDeep,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.4,
                          ),
                        ),
                      const Spacer(),
                      Icon(
                        Icons.north_east,
                        size: 15,
                        color: AppColors.ink.withValues(alpha: 0.34),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    title,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: AppColors.ink,
                      fontSize: 24,
                      height: 1.05,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.inkSoft,
                      height: 1.4,
                      fontSize: 12,
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 9),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final m in meta)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.paperDeep.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: AppColors.ink.withValues(alpha: 0.08),
                              ),
                            ),
                            child: Text(
                              m,
                              style: const TextStyle(
                                fontFamily: AppFonts.body,
                                color: AppColors.inkSoft,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One of the club's side doors: a paper tile with a brass seal, a name and a
/// one-line reason to open it.
class ClubDoor extends StatelessWidget {
  const ClubDoor({
    super.key,
    required this.icon,
    required this.label,
    required this.detail,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final String detail;
  final VoidCallback onTap;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClubCard(
      padding: const EdgeInsets.fromLTRB(12, 13, 12, 13),
      radius: 16,
      onTap: () {
        Haptics.light();
        onTap();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClubSeal(icon: icon, size: 34),
              const Spacer(),
              ?badge,
            ],
          ),
          const SizedBox(height: 11),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              color: AppColors.ink,
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.inkFaint,
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
