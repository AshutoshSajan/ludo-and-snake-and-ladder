import 'package:flutter/material.dart';

import '../../services/admin_client.dart';
import 'admin_auth_mode.dart';

export 'admin_auth_mode.dart';

/// Placeholder compiled into non-web builds so app_router.dart's
/// conditional import resolves — the /admin routes are never registered
/// there. This page is unreachable dead code, not a surface. The
/// signature mirrors the real screen's (see [admin_login_screen.dart])
/// so the route arms compile unchanged on every platform.
class AdminLoginScreen extends StatelessWidget {
  const AdminLoginScreen({
    super.key,
    this.clientFactory,
    this.mode = AdminAuthMode.login,
  });

  final AdminClient Function()? clientFactory;

  final AdminAuthMode mode;

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: Text('Admin is available in the web app.')),
  );
}
