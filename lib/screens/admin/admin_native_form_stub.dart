import 'package:flutter/widgets.dart';

import 'admin_form_values.dart';

/// Non-web placeholder for [AdminNativeForm].
///
/// The admin route is web-only, and the Flutter form stays in
/// `admin_login_screen.dart` for the VM build, so this widget is never shown.
/// It exists only to keep the web-only file out of VM builds.
class AdminNativeForm extends StatefulWidget {
  const AdminNativeForm({
    super.key,
    required this.setup,
    required this.busy,
    required this.onSubmit,
  });

  final bool setup;
  final bool busy;
  final ValueChanged<AdminFormValues> onSubmit;

  @override
  State<AdminNativeForm> createState() => AdminNativeFormState();
}

class AdminNativeFormState extends State<AdminNativeForm> {
  /// No-op on the VM: the Flutter fields own the submit.
  void submit() {}

  /// No-op on the VM: there is no browser password manager to prompt.
  void save() {}

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
