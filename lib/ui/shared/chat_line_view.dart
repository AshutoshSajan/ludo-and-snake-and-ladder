import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../engine/ludo/ludo_models.dart';
import '../../services/online_client.dart';
import '../theme.dart';

/// One table-chat line as a **bubble**: seat-colored avatar, name and
/// time, then the content — a sentence, a GIF card, a voice-note pill, or
/// any mix of the three. Own messages sit on the right and wear the
/// table's gold; everyone else's sit left with their seat color.
///
/// Shared by the lobby's inline feed and the in-game chat sheet so the
/// two surfaces cannot drift: they used to render `from: text` by hand,
/// which is how the plain look got stuck. [myName] decides alignment;
/// '' (or an unknown sender) means "someone else's", the safe default
/// for a spectator watching a table.
class ChatLineView extends StatelessWidget {
  const ChatLineView({
    super.key,
    required this.line,
    this.myName = '',
    this.compact = false,
  });

  final ChatLine line;

  /// The reader's own name — right-aligns and tints gold.
  final String myName;

  /// Lobby feed: tighter paddings and a smaller GIF, because up to six
  /// bubbles share the column with the composer.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final mine = line.from == myName && myName.isNotEmpty;
    final accent = line.color == null
        ? AppColors.gold
        : AppColors.ludo(line.color!);
    final fontSize = compact ? 12.5 : 13.5;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        _Header(line: line, accent: accent, fontSize: fontSize),
        const SizedBox(height: 3),
        Container(
          constraints: BoxConstraints(maxWidth: compact ? 240 : 320),
          padding: (line.gif != null || line.note != null)
              ? EdgeInsets.all(compact ? 5 : 7)
              : EdgeInsets.symmetric(
                  horizontal: compact ? 11 : 13,
                  vertical: compact ? 7 : 9,
                ),
          decoration: BoxDecoration(
            color: mine
                ? AppColors.gold.withValues(alpha: 0.16)
                : Colors.white.withValues(alpha: 0.08),
            // A hair of border keeps the tint readable over any felt.
            border: Border.all(
              width: 1,
              color: mine
                  ? AppColors.gold.withValues(alpha: 0.5)
                  : Colors.white.withValues(alpha: 0.16),
            ),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(15),
              topRight: const Radius.circular(15),
              bottomLeft: Radius.circular(mine ? 15 : 4),
              bottomRight: Radius.circular(mine ? 4 : 15),
            ),
          ),
          child: _Content(line: line, compact: compact, accent: accent),
        ),
      ],
    );
  }
}

/// The byline: seat-colored initial chip, the player's name, and the
/// wall-clock minute the line arrived (fresh since a chat lives one
/// session; no dates needed, nothing grows into scroll archaeology).
class _Header extends StatelessWidget {
  const _Header({
    required this.line,
    required this.accent,
    required this.fontSize,
  });

  final ChatLine line;
  final Color accent;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final initial = line.from.isEmpty
        ? '?'
        : line.from.characters.first.toUpperCase();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: fontSize + 8,
          height: fontSize + 8,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          child: Text(
            initial,
            style: TextStyle(
              // The yellow seat's ink is dark for legibility on yellow.
              color: line.color == LudoColor.yellow
                  ? AppColors.ink
                  : AppColors.ivory,
              fontSize: (fontSize - 3).clamp(9, 12),
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          line.from,
          style: TextStyle(
            color: AppColors.ivory.withValues(alpha: 0.85),
            fontSize: fontSize - 1.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (line.at != null) ...[
          const SizedBox(width: 7),
          Text(
            line.clock,
            style: TextStyle(
              color: AppColors.ivory.withValues(alpha: 0.4),
              fontSize: fontSize - 4,
            ),
          ),
        ],
      ],
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({
    required this.line,
    required this.compact,
    required this.accent,
  });

  final ChatLine line;
  final bool compact;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final fontSize = compact ? 12.5 : 13.5;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (line.gif != null) ...[
          _GifImage(url: line.gif!, width: compact ? 150 : 230),
          if (line.note != null || line.text.isNotEmpty)
            const SizedBox(height: 5),
        ],
        if (line.note != null) ...[
          VoicePill(
            note: line.note!,
            accent: accent,
            width: compact ? 150 : 190,
          ),
          if (line.text.isNotEmpty) const SizedBox(height: 5),
        ],
        if (line.text.isNotEmpty)
          Text(
            line.text,
            style: TextStyle(
              color: AppColors.ivory.withValues(alpha: 0.95),
              fontSize: fontSize,
              height: 1.35,
            ),
          ),
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
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        url,
        width: width,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: width,
          height: width * 0.5,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          color: AppColors.felt,
          alignment: Alignment.center,
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

/// A voice note playable right where it was said: a circular play/pause
/// button in the sender's seat color, the clip's length, and a trail
/// reading how far the playback is. One [AudioPlayer] per pill, born on
/// first play — a table is four people and their phones, not a streaming
/// service, and late minutes of audio are cheaper held than sought.
class VoicePill extends StatefulWidget {
  const VoicePill({
    super.key,
    required this.note,
    required this.accent,
    this.width = 190,
  });

  final VoiceNote note;
  final Color accent;
  final double width;

  @override
  State<VoicePill> createState() => _VoicePillState();
}

class _VoicePillState extends State<VoicePill> {
  AudioPlayer? _player;
  bool _playing = false;
  bool _loaded = false;
  double _trail = 0;

  Future<void> _toggle() async {
    final player = _player ??= _spawnPlayer();
    try {
      if (_playing) {
        await player.pause();
        return;
      }
      if (!_loaded) {
        await player.setSource(UrlSource(widget.note.url));
        await player.seek(Duration.zero);
        _loaded = true;
      }
      await player.resume();
    } catch (_) {
      // A dead link (the store's TTL passed, or the room's instance
      // restarted) degrades exactly like a dead GIF would: a note, not
      // a crash and not a spinner that never leaves.
      if (mounted) {
        setState(() {
          _playing = false;
          _loaded = false;
        });
      }
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('Voice note unavailable')),
          );
      }
    }
  }

  AudioPlayer _spawnPlayer() {
    final player = AudioPlayer();
    player.onPositionChanged.listen((p) {
      final total = widget.note.durMs;
      if (total <= 0 || !mounted) return;
      setState(() => _trail = (p.inMilliseconds / total).clamp(0.0, 1.0));
    });
    player.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      setState(() {
        _playing = s == PlayerState.playing;
        // Completed (or stopped) — rearm the bar for a re-listen.
        if (s == PlayerState.completed) {
          _trail = 0;
          _loaded = false;
        }
      });
    });
    return player;
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trailColor = widget.accent;
    final buttonFg = widget.accent == AppColors.ludoYellow
        ? AppColors.ink
        : AppColors.ivory;
    return SizedBox(
      width: widget.width,
      child: Row(
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton.filled(
              padding: EdgeInsets.zero,
              iconSize: 16,
              icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
              tooltip: _playing ? 'Pause' : 'Play voice note',
              style: IconButton.styleFrom(
                backgroundColor: trailColor,
                foregroundColor: buttonFg,
              ),
              onPressed: _toggle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            widget.note.clock,
            style: const TextStyle(
              color: AppColors.ivory,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: LinearProgressIndicator(
              value: widget.note.durMs > 0 ? _trail : null,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
              backgroundColor: Colors.white.withValues(alpha: 0.18),
              color: trailColor,
            ),
          ),
        ],
      ),
    );
  }
}
