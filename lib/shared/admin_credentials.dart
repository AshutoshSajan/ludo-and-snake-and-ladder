/// Credential rules for the admin account.
///
/// The setup form exists twice (a real DOM `<form>` on the web and the Flutter
/// fallback used by the VM build) and the server owns the final say. Keeping
/// the rules in one pure-Dart file means the three cannot drift: a password
/// the UI accepts is one the setup endpoint accepts, and a message the UI
/// shows is the server's own wording.
library;

/// A new password must be at least this long.
const adminPasswordMinLength = 8;

/// …and at most this long. The cap keeps the KDF payload and the password
/// manager's save payload bounded; it is not a security boundary.
const adminPasswordMaxLength = 60;

/// RFC 5321's maximum address length.
const adminEmailMaxLength = 254;

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
final _letterPattern = RegExp('[A-Za-z]');
final _digitPattern = RegExp('[0-9]');
final _symbolPattern = RegExp('[^A-Za-z0-9]');

/// A valid sign-in / setup email: one `@`, no whitespace, and a dotted domain.
///
/// Deliberately stricter than the store's historical `contains('@')` check so
/// the form catches a typo before a round trip. The server applies the same
/// rule at setup, so the two can never disagree about what was created.
String? adminEmailProblem(String email) {
  final value = email.trim();
  if (value.isEmpty) return 'Enter your email address.';
  if (value.length > adminEmailMaxLength) return 'That email is too long.';
  if (!_emailPattern.hasMatch(value)) return 'Enter a valid email address.';
  return null;
}

/// A new password: letters, numbers and symbols, bounded at both ends.
///
/// The length floor matches `minPasswordLength` in `server/auth.dart`; the
/// character classes are what make "strong" concrete instead of a vague
/// promise. Sign-in never calls this — an existing credential is whatever the
/// server stored, including one created before these rules existed.
String? adminNewPasswordProblem(String password) {
  if (password.isEmpty) return 'Choose a password.';
  if (password.length < adminPasswordMinLength) {
    return 'Use at least $adminPasswordMinLength characters.';
  }
  if (password.length > adminPasswordMaxLength) {
    return 'Use at most $adminPasswordMaxLength characters.';
  }
  if (!_letterPattern.hasMatch(password)) return 'Add at least one letter.';
  if (!_digitPattern.hasMatch(password)) return 'Add at least one number.';
  if (!_symbolPattern.hasMatch(password)) return 'Add at least one symbol.';
  return null;
}

/// The two password fields must agree.
String? adminPasswordConfirmProblem(String password, String confirmation) {
  if (confirmation.isEmpty) return 'Confirm your password.';
  if (confirmation != password) return 'Passwords do not match.';
  return null;
}

/// Sign-in only checks presence: strength rules belong to new credentials.
String? adminSignInPasswordProblem(String password) =>
    password.isEmpty ? 'Enter your password.' : null;
