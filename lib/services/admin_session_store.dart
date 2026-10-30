/// Where the admin session lives between loads.
///
/// The token arrives once at login and then has to survive a page refresh:
/// `AdminClient` and the session provider are pure memory, so without this
/// store a reload at `/admin/dashboard` forgets the sign-in and the auth
/// gate hands the tab to the login form even though the server still has a
/// perfectly valid session row.
///
/// Web builds read/write `window.localStorage` ([admin_session_store_web.dart]);
/// every other target resolves the stub — native binaries do not compile the
/// admin screens at all, and the stub keeps this module importable anywhere
/// (tests included) with the web-only behavior branching cleanly.
///
/// localStorage, not sessionStorage: a refresh and a closed-and-reopened tab
/// are the same operator continuing their shift, not a different person. The
/// expiry ride-along lets the client delete a dead record without first
/// showing the dashboard a request that cannot succeed (the server remains
/// the source of truth — any 401 clears the store and returns to the login).
library;

export 'admin_session_store_web.dart' if (dart.library.io) 'admin_session_store_stub.dart';

/// One persisted admin session: what [AdminSession] carries plus the expiry
/// the server reported at login. Plain JSON in a single localStorage key.
class AdminAuthRecord {
  const AdminAuthRecord({
    required this.token,
    required this.email,
    required this.name,
    required this.expiresAt,
  });

  factory AdminAuthRecord.fromJson(Map<String, dynamic> json) =>
      AdminAuthRecord(
        token: json['token'] as String,
        email: json['email'] as String,
        name: json['name'] as String,
        expiresAt: (json['expiresAt'] as num).toInt(),
      );

  final String token;
  final String email;
  final String name;
  final int expiresAt;

  /// The store's contract, decidable without a browser: a record whose
  /// server-side expiry has passed is dead on arrival. The web store drops
  /// one like this before it ever reaches the dashboard; the test suite
  /// asserts the decision here on the shared logic rather than inside the
  /// web half.
  bool expiredAt(int nowMs) => expiresAt <= nowMs;

  Map<String, dynamic> toJson() => {
    'token': token,
    'email': email,
    'name': name,
    'expiresAt': expiresAt,
  };
}
