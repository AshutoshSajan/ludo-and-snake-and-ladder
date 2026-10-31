// The web half of the admin session store: one JSON record in
// window.localStorage.
//
// Shaped to match `services/share_link_web.dart` — the other package:web
// consumer of raw browser storage in this codebase — so both touch the
// window the same way.
import 'dart:convert';

import 'package:web/web.dart' as web;

import 'admin_session_store.dart';

const _key = 'gc.admin.session';

/// The stored record, or null when absent, expired, or malformed. Expiry is
/// checked here so a dead session never reaches the dashboard: on restore the
/// record is dropped immediately rather than pinned until a request fails.
AdminAuthRecord? restoreAdminSession() {
  final raw = web.window.localStorage.getItem(_key);
  if (raw == null || raw.isEmpty) return null;
  try {
    final record = AdminAuthRecord.fromJson(
      (jsonDecode(raw) as Map).cast<String, dynamic>(),
    );
    if (record.expiredAt(DateTime.now().millisecondsSinceEpoch)) {
      web.window.localStorage.removeItem(_key);
      return null;
    }
    return record;
  } catch (_) {
    // A malformed record is a corrupt write, not a bug worth surfacing:
    // forget it and let the operator sign in again.
    web.window.localStorage.removeItem(_key);
    return null;
  }
}

void persistAdminSession(AdminAuthRecord record) {
  web.window.localStorage.setItem(_key, jsonEncode(record.toJson()));
}

void forgetAdminSession() => web.window.localStorage.removeItem(_key);
