/// Credentials read from the admin sign-in / first-run setup form.
///
/// The web form is a real DOM `<form>` (see `admin_native_form.dart`), so its
/// values only become Dart strings at submit time. The VM fallback fills the
/// same object from its [TextEditingController]s.
class AdminFormValues {
  const AdminFormValues({
    required this.email,
    required this.name,
    required this.password,
    required this.confirmPassword,
    required this.setupToken,
  });

  final String email;
  final String name;
  final String password;

  /// The setup form's second password field. Sign-in leaves it empty.
  final String confirmPassword;
  final String setupToken;
}
