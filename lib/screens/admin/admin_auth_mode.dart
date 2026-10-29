/// Which permission story the admin auth screen tells.
///
/// [login] presents an existing credential; [signup] creates the club's
/// first admin. The mode travels on the URL (`/admin/login` vs
/// `/admin/signup`), so a cold load never guesses — and the real screen
/// re-checks the server on mount, moving to the matching URL when the
/// assumption went stale.
///
/// Lives in its own file so the stub body of [AdminLoginScreen]
/// (`admin_login_stub.dart`, compiled on non-web) and the real one export
/// the same name without duplicating a definition or crossing the
/// conditional import.
library;

enum AdminAuthMode { login, signup }
