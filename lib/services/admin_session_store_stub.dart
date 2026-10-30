// The non-web half of the admin session store: a stub.
//
// Native binaries never compile the admin screens (conditional imports on
// `dart.library.io` resolve to stubs for every admin screen), so there is no
// caller below the provider layer that could need a token back. The functions
// exist with the same shapes as the web implementation so the provider file
// compiles unchanged on every target; restore always reads as signed out.
import 'admin_session_store.dart';

AdminAuthRecord? restoreAdminSession() => null;

void persistAdminSession(AdminAuthRecord record) {}

void forgetAdminSession() {}
