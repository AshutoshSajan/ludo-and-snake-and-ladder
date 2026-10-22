import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import 'admin_badge.dart';
import 'shared/table_alert.dart';

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
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
      child: child,
    ),
  );
}

/// The toast a page speaks with.
///
/// Historically this was a Material snackbar pinned to the bottom edge, and
/// the playtest called that out twice: "room code copy is showing plain white
/// alert at the bottom, i wanted the good popup ui on the top right of the
/// screen — find all such plain white banners". Every page message now goes
/// through the table's own gold-rimmed card at the top right, the same family
/// as the in-game alerts, so there is one spoken surface in the whole app
/// instead of a second, plainer one on the bottom edge. The function keeps its
/// old name because its callers read as "say this on the page"; the surface it
/// speaks on is [showTableAlert].
void showSnackInColumn(
  BuildContext context,
  String text, {
  IconData icon = Icons.info_outline,
  OverlayState? onOverlay,
}) {
  showTableAlert(context, text, icon: icon, onOverlay: onOverlay);
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
class PageAppBar extends ConsumerWidget implements PreferredSizeWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final canPop = Navigator.of(context).canPop();
    final admin = ref.watch(adminSessionProvider);
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      // No AppBar gutter of our own: the inner Padding below owns the
      // horizontal inset, matching the page bodies exactly.
      titleSpacing: 0,
      title: ContentColumn(
        // Same 16px inset the page bodies use (their ListView padding), so
        // the bar's content starts and ends where the page content does. A
        // full-bleed row previously let trailing badges overhang the cards
        // below by exactly that padding.
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              if (canPop)
                BackButton(onPressed: () => Navigator.of(context).maybePop()),
              // The title takes the slack, so it stays left-aligned with the
              // content instead of drifting to the middle of the bar the way a
              // centred title would on a wide window.
              Expanded(
                child: title is String
                    ? Text(title as String, overflow: TextOverflow.ellipsis)
                    : title as Widget,
              ),
              ...?actions,
              // Visible only while signed in at /admin: every PageAppBar
              // screen then carries the admin identity, and tapping it opens
              // the dashboard. Game views skip this bar, so boards stay clean.
              if (admin != null) AdminBadge(session: admin, compact: true),
            ],
          ),
        ),
      ),
    );
  }
}
