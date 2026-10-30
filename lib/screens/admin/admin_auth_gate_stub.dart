import 'package:flutter/material.dart';

/// Placeholder compiled into non-web builds so app_router.dart's
/// conditional import resolves — the /admin routes are never registered
/// there. This page is unreachable dead code, not a surface.
class AdminAuthGate extends StatelessWidget {
  const AdminAuthGate({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: Text('Admin is available in the web app.')),
  );
}
