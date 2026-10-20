import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../engine/ludo/ludo_models.dart';
import '../../services/online_client.dart';
import '../page_app_bar.dart';
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
    this.avatar,
    this.quote,
    this.liked = false,
    this.gifImageProvider,
    this.onOpenMenu,
  });

  final ChatLine line;

  /// The reader's own name — right-aligns and tints gold.
  final String myName;

  /// Lobby feed: tighter paddings and a smaller GIF, because up to six
  /// bubbles share the column with the composer.
  final bool compact;

  /// Optional id-identicon for a private (non-table) lane: rendered
  /// beside the bubble — left of it when theirs, right when mine — the
  /// way a 1:1 chat shows who spoke. Table chat leaves it null and keeps
  /// the plain seat-colored byline.
  final Widget? avatar;

  /// Optional reply context rendered as a framed strip at the top of the
  /// bubble (the "answered message" card in a 1:1 chat). Table chat
  /// leaves it null; a strip belongs to a thread where quoting is a
  /// feature, not an accident.
  final Widget? quote;

  /// A reaction stamp on the bubble (the liked-heart in a 1:1 chat).
  final bool liked;

  /// Test seam for the GIF bubble's image source. Production leaves it
  /// null so the bubble fetches [line.gif] itself; a widget test injects
  /// a memory-backed provider to drive the loading states without a
  /// network. Any ImageProvider works — the loader only cares about its
  /// chunk events.
  final ImageProvider? gifImageProvider;

  /// Open a menu about this line's author (the table surfaces pass
  /// friend/block/report here). Null — the default — means the line is
  /// inert, which is how the 1:1 friends chat and any other non-table
  /// lane keep the bubble gesture-free.
  final VoidCallback? onOpenMenu;

  @override
  Widget build(BuildContext context) {
    if (onOpenMenu == null) return buildLine(context);
    // A tap or long press opens the author's menu — visible affordance,
    // not a hidden gesture: table chat is where players meet each other,
    // and the menu is how "who said that?" becomes "add / block / report".
    return GestureDetector(
      onTap: onOpenMenu,
      onLongPress: onOpenMenu,
      behavior: HitTestBehavior.translucent,
      child: buildLine(context),
    );
  }

  Widget buildLine(BuildContext context) {
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
        _Header(line: line, accent: accent, fontSize: fontSize, avatar: avatar),
        const SizedBox(height: 3),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (avatar != null && !mine) ...[avatar!, const SizedBox(width: 6)],
            Flexible(
              child: Container(
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
                child: _Content(
                  line: line,
                  compact: compact,
                  accent: accent,
                  mine: mine,
                  quote: quote,
                  liked: liked,
                  gifImageProvider: gifImageProvider,
                ),
              ),
            ),
            if (avatar != null && mine) ...[const SizedBox(width: 6), avatar!],
          ],
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
    this.avatar,
  });

  final ChatLine line;
  final Color accent;
  final double fontSize;
  final Widget? avatar;

  @override
  Widget build(BuildContext context) {
    final fontSize = this.fontSize;
    return Padding(
      // With an avatar beside the bubble the byline already starts
      // indented to line up with the bubble; without one it stays flush.
      padding: EdgeInsets.only(left: avatar == null ? 0 : 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The identicon (private lane) replaces the initial chip: two
          // avatars for one person reads as clutter.
          if (avatar == null)
            Container(
              width: fontSize + 8,
              height: fontSize + 8,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              child: Text(
                line.from.isEmpty
                    ? '?'
                    : line.from.characters.first.toUpperCase(),
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
      ),
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({
    required this.line,
    required this.compact,
    required this.accent,
    this.mine = false,
    this.quote,
    this.liked = false,
    this.gifImageProvider,
  });

  final ChatLine line;
  final bool compact;
  final Color accent;
  final bool mine;
  final Widget? quote;
  final bool liked;
  final ImageProvider? gifImageProvider;

  @override
  Widget build(BuildContext context) {
    final fontSize = compact ? 12.5 : 13.5;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The reply snapshot rides inside the bubble, above the body —
        // the quoted card pattern from every big 1:1 messenger.
        if (quote != null) ...[quote!, const SizedBox(height: 4)],
        if (line.gif != null) ...[
          _GifImage(
            url: line.gif!,
            width: compact ? 150 : 230,
            provider: gifImageProvider,
          ),
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
        // The reaction: a small heart pinned to the bubble's trailing
        // edge (right for my own messages, left for theirs).
        if (liked)
          Align(
            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Icon(
                Icons.favorite,
                size: fontSize + 2,
                color: const Color(0xFFE5607A),
              ),
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
  const _GifImage({required this.url, required this.width, this.provider});

  final String url;
  final double width;

  /// Optional test seam (see [ChatLineView.gifImageProvider]): injects the
  /// image source so a widget test can walk the loader's phases offline.
  final ImageProvider? provider;

  @override
  Widget build(BuildContext context) {
    // A fixed frame, matched to the loading placeholder below: the bubble
    // reserves the same 5:3 crop through every phase, so a GIF cannot
    // punch the bubble open the moment its pixels land (a width-only
    // image sizes to its intrinsic ratio — "loading box is the wrong
    // size", and the corners slid out past the bubble's paint).
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image(
        image: provider ?? NetworkImage(url),
        width: width,
        height: width * 0.6,
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
        // Phases are keyed on the DECODED FRAME, never on chunk progress:
        // between stream resolution and the first fetched bytes, "no
        // progress" fires too, and trusting it there paints the unresolved
        // child — a zero-height shadow bubble (the player's "empty gold
        // strip" while a GIF waits for its CDN). `frameBuilder`'s
        // frame != null is precisely the moment pixels exist: the felt
        // placeholder with its spinner owns everything before that, and
        // the image paints from the first frame to the last.
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (frame == null) {
            // The placeholder must carry the frame's size EXPLICITLY: it
            // replaces the child whole, so any size the Image's width/
            // height props describe belongs to the child being withheld —
            // a sizeless Container here wraps only its spinner and the
            // bubble collapses to a small bar while the CDN is slow.
            return Container(
              width: width,
              height: width * 0.6,
              color: AppColors.felt,
              alignment: Alignment.center,
              child: const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          return child;
        },
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
        showSnackInColumn(context, 'Voice note unavailable');
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
