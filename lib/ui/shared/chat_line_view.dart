import 'package:flutter/material.dart';

import '../../services/online_client.dart';
import '../theme.dart';

/// One table-chat line — a sentence, an inline GIF, or a GIF plus caption.
///
/// Shared by the lobby's inline feed and the in-game chat sheet so the two
/// surfaces cannot drift: both used to render `from: text` by hand, which is
/// exactly where GIF support would have been added twice. [compact] is the
/// lobby variant (smaller type, tighter image); the sheet uses the reading
/// size.
class ChatLineView extends StatelessWidget {
  const ChatLineView({
    super.key,
    required this.line,
    this.compact = false,
  });

  final ChatLine line;

  /// Lobby feed: the image leads with less vertical room because up to six
  /// lines sit above the composer.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final fontSize = compact ? 13.0 : 14.0;
    final nameStyle = TextStyle(
      fontWeight: FontWeight.w700,
      color: AppColors.gold,
      fontSize: fontSize,
    );

    // Text-only keeps the single-line look the chat always had.
    if (line.gif == null) {
      return Text.rich(
        TextSpan(
          style: TextStyle(color: AppColors.ivory, fontSize: fontSize),
          children: [
            TextSpan(text: '${line.from}: ', style: nameStyle),
            TextSpan(text: line.text),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            style: TextStyle(color: AppColors.ivory, fontSize: fontSize),
            children: [
              TextSpan(text: line.from, style: nameStyle),
              if (line.text.isEmpty)
                TextSpan(
                  text: ' sent a GIF',
                  style: TextStyle(
                    color: AppColors.ivory.withValues(alpha: 0.7),
                    fontSize: fontSize,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        _GifImage(url: line.gif!, width: compact ? 160 : 240),
        if (line.text.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            line.text,
            style: TextStyle(color: AppColors.ivory, fontSize: fontSize),
          ),
        ],
      ],
    );
  }
}

/// An inline GIF in the chat feed. Network images that fail (expired CDN
/// link, no connectivity) degrade to a small note rather than an empty gap:
/// a dead GIF should read as "gone", not as "the chat is broken".
class _GifImage extends StatelessWidget {
  const _GifImage({required this.url, required this.width});

  final String url;
  final double width;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        url,
        width: width,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: width,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          color: AppColors.felt,
          child: Text(
            'GIF unavailable',
            style: TextStyle(
              color: AppColors.ivory.withValues(alpha: 0.6),
              fontSize: 12,
            ),
          ),
        ),
        loadingBuilder: (context, child, progress) => Container(
          width: width,
          height: width * 0.6,
          color: AppColors.felt,
          alignment: Alignment.center,
          child: progress == null
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : child,
        ),
      ),
    );
  }
}
