/// The admin credential form.
///
/// On the web this is a real DOM `<form>` hosted in a platform view. Flutter's
/// [AutofillGroup] proxies are not a reliable contract with password managers
/// on the web: non-focused proxies are zero-sized, a manager's blur tears down
/// the input listeners, and a fill can land on an input nobody is forwarding
/// from. A real form with real inputs is what Chrome, Firefox, Bitwarden,
/// 1Password and Proton Pass all know how to fill and save.
///
/// The VM build receives the stub: `/admin` is only registered on the web
/// (`app_router.dart` conditional import), and the Flutter fields remain as
/// the fallback used by widget tests.
library;

export 'admin_form_values.dart';
export 'admin_native_form_stub.dart'
    if (dart.library.js_interop) 'admin_native_form_web.dart';
