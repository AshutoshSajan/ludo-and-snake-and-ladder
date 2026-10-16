import 'package:flutter/material.dart';

import '../providers/app_providers.dart';
import '../screens/admin/admin_dashboard_screen.dart';
import '../services/admin_client.dart';
import 'theme.dart';

/// The signed-in admin identity chip: shield + email, tapping opens the
/// dashboard. One widget for every surface (home body, app bars) so the
/// badge cannot drift out of the layout again — it previously lived as two
/// hand-rolled containers with different borders (one raw material amber),
/// no fill, and duplicated dashboard navigation.
///
/// [compact] is the app-bar trailing slot: smaller padding/type and a
/// capped email width with ellipsis. The full variant shows `Admin · email`.
class AdminBadge extends StatelessWidget {
  const AdminBadge({super.key, required this.session, this.compact = false});

  final AdminSession session;
  final bool compact;

  void _open(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminDashboardScreen(
          client: AdminClient(
            serverUrl: session.serverUrl,
            token: session.token,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = compact ? session.email : 'Admin · ${session.email}';
    return Tooltip(
      message: 'Admin: ${session.email} — open dashboard',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _open(context),
        child: Container(
          margin: EdgeInsets.only(left: compact ? 8 : 0),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 12,
            vertical: compact ? 4 : 6,
          ),
          decoration: BoxDecoration(
            color: AppColors.gold.withAlpha(28),
            border: Border.all(color: AppColors.gold),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.verified_user,
                size: compact ? 14 : 16,
                color: AppColors.gold,
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: compact ? 120 : 220,
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.ivory,
                    fontSize: compact ? 11 : 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
