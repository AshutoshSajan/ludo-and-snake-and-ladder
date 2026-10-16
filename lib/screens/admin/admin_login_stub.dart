import 'package:flutter/material.dart';

/// Placeholder compiled into non-web builds so main.dart's conditional
/// import resolves. The /admin route is never registered there — this page
/// is unreachable dead code, not a surface.
class AdminLoginScreen extends StatelessWidget {
  const AdminLoginScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: Text('Admin is available in the web app.')),
  );
}
