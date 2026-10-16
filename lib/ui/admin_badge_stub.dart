import 'package:flutter/material.dart';

import '../providers/app_providers.dart';

/// Non-web builds never compile the admin screens (see [admin_badge.dart]):
/// the badge is a no-op, so no session can ever surface one on
/// desktop/mobile.
class AdminBadge extends StatelessWidget {
  const AdminBadge({super.key, required this.session, this.compact = false});

  final AdminSession session;
  final bool compact;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
