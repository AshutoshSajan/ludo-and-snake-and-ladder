import 'package:flutter/material.dart';

/// The reading-width column every full-screen page is laid out in.
///
/// The home screen uses 520 and the online lobby 460, because both are narrow
/// forms. The pages that show rows, cards or settings need more: below roughly
/// 700 a seat card drops its Human/Bot toggle and difficulty dropdown onto their
/// own lines, and the leaderboard's rank and name start competing for room.
const double kContentMaxWidth = 720;

/// Constrains a page body to [kContentMaxWidth] and centres it.
class ContentColumn extends StatelessWidget {
  const ContentColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Center(child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
            child: child,
          ));
}

/// An AppBar whose leading icon, title and actions sit inside that column.
///
/// Without this the bar spans the viewport while the body does not, so on a
/// 1900px window the back arrow and title sit at the far left and the content
/// they label starts hundreds of pixels further in — a heading that appears to
/// belong to nothing. Wrapping only `title` would not fix it either: the back
/// button would still sit outside the column, leaving the two permanently offset
/// by the leading width.
///
/// The in-game views deliberately do NOT use this. A Ludo board and a 10-seat
/// Snakes grid both want the full width; a fixed column would letterbox the very
/// thing the player is looking at.
class PageAppBar extends StatelessWidget implements PreferredSizeWidget {
  const PageAppBar({
    super.key,
    required this.title,
    this.actions,
    this.backgroundColor,
    this.foregroundColor,
  });

  /// Either a plain string or a composite title. The game views pass a Row when
  /// the player is spectating, which a String-only API could not express.
  final Object title;
  final List<Widget>? actions;

  /// Passed through to [AppBar]. The leaderboard sets a lighter felt than the
  /// default bar, and dropping that to gain the alignment would have been a
  /// silent visual regression rather than a change.
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      // The column's own left edge, not the default 16px gutter. With a back
      // button present that gutter would push the title 16px right of the body
      // content it labels — the exact misalignment this removes.
      titleSpacing: 0,
      title: ContentColumn(
        child: Row(
          children: [
            if (canPop)
              BackButton(onPressed: () => Navigator.of(context).maybePop())
            else
              const SizedBox(width: 16),
            // The title takes the slack, so it stays left-aligned with the
            // content instead of drifting to the middle of the bar the way a
            // centred title would on a wide window.
            Expanded(
              child: title is String
                  ? Text(title as String, overflow: TextOverflow.ellipsis)
                  : title as Widget,
            ),
            ...?actions,
          ],
        ),
      ),
    );
  }
}