import 'package:flutter/material.dart';

import '../services/sound_service.dart';
import '../ui/theme.dart';

/// Big "Game Club" header.
class ClubHeader extends StatelessWidget {
  const ClubHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // A painted die, not a glyph. This was Text('🎲'), and it rendered as a
        // tofu box inside the packaged add-on: only Roboto, MaterialIcons and
        // CupertinoIcons are bundled, and Roboto carries no emoji, so there is
        // no fallback to find one. The web build got away with it because the
        // browser substitutes a system emoji font; an extension page cannot.
        //
        // Painting it removes the font dependency rather than papering over it,
        // and it matches how extension/popup.html draws its die in CSS.
        const SizedBox(
          width: 46,
          height: 46,
          child: CustomPaint(painter: _DiePainter()),
        ),
        const SizedBox(height: 6),
        Text(
          'Game Club',
          style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: AppColors.gold,
                letterSpacing: 1.2,
              ),
        ),
        const Text(
          'Tabletop classics, local & cozy',
          style: TextStyle(color: Colors.white70),
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
    canvas.drawRRect(body, Paint()..color = AppColors.ivory);
    canvas.drawRRect(
      body,
      Paint()
        ..color = AppColors.gold
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.075,
    );

    // Pips on a 2x2 grid: red top-left and bottom-right, blue the others.
    // Laid out from the centre so the spacing holds at any size.
    final r = w * 0.088;
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

/// Selectable game card with a painted board preview.
class GameCard extends StatelessWidget {
  const GameCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.preview,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final Widget preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Haptics.light();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(color: Colors.black38, blurRadius: 8),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                      width: 96, height: 96, child: FittedBox(child: preview)),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13)),
                    const SizedBox(height: 10),
                    // The arrow was a literal '→' typed into the label. It
                    // rendered as a tofu box in the packaged add-on for the same
                    // reason the die did - the glyph is not in the bundled
                    // fonts. A Material icon always renders, because
                    // MaterialIcons is bundled and asserted by the build script.
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Play now',
                            style: TextStyle(
                                color: AppColors.gold,
                                fontWeight: FontWeight.w700,
                                fontSize: 13)),
                        const SizedBox(width: 4),
                        const Icon(Icons.arrow_forward,
                            size: 14, color: AppColors.gold),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
