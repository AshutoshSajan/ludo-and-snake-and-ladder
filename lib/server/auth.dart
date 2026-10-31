/// Authentication primitives for the admin panel (and players later).
///
/// Passwords: bcrypt with a per-hash random salt. The stored form is the
/// bcrypt string itself (`$2a$12$...`): salt, cost and digest ride in one
/// field, so verification is `verifyPassword(stored)` with nothing else to
/// fetch, and rows never need a rehash-on-login upgrade for the cost to
/// rise — a future cost bump re-hashes at the next password change instead.
/// Sessions: opaque 256-bit tokens. Only the SHA-256 hash is stored; the
/// raw token is handed to the browser once at login, inside the HttpOnly
/// session cookie.
///
/// No JWT: logout revokes by deleting the row, expiry is enforced on read,
/// and there is no signing secret to rotate or leak.
library;

import 'dart:convert';
import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:crypto/crypto.dart';

import '../shared/admin_credentials.dart';

/// Production cost factor: bcrypt at cost 12 — the 2^12 key schedule the
/// guidance for this algorithm asks for in the 2020s. A one-off `dart run`
/// bench on this repo's server hardware measured a cost-12 hash or verify
/// at about 370ms (cost 11 ~185ms, cost 10 ~100ms), short enough to run
/// inline on the event loop without freezing live player sockets, unlike
/// the multi-second PBKDF2 it replaced. If this ever rises to 14 or more,
/// the spend must leave the event loop again (`Isolate.run`) before the
/// next login is served.
///
/// Tests pass a smaller value explicitly — thread the parameter as with
/// this constant's consumers; never mutate the global from tests.
const defaultBcryptRounds = 12;

/// Minimum accepted password length for new users / resets. The admin form
/// uses the same constant through `shared/admin_credentials.dart`.
const minPasswordLength = adminPasswordMinLength;

final _random = Random.secure();

/// URL-safe random bytes (default 32 = 256-bit session entropy).
String randomToken([int bytes = 32]) {
  final data = List<int>.generate(bytes, (_) => _random.nextInt(256));
  return base64Url.encode(data).replaceAll('=', '');
}

/// SHA-256 hex of [token] — what is stored for sessions.
String hashToken(String token) => sha256.convert(utf8.encode(token)).toString();

/// bcrypt hash with a fresh random salt. [rounds] is explicit so tests run
/// fast while production uses [defaultBcryptRounds].
String hashPassword(String password, {int rounds = defaultBcryptRounds}) =>
    BCrypt.hashpw(password, BCrypt.gensalt(logRounds: rounds));

/// bcrypt verification — constant time inside the package by construction.
/// Returns false (never throws) on malformed stored hashes so a corrupt row
/// fails closed.
bool verifyPassword(String password, String stored) {
  try {
    return BCrypt.checkpw(password, stored);
  } catch (_) {
    return false;
  }
}

/// The absent-email decoy, reduced to a constant. A malformed row or an
/// unregistered address must cost the same verification work as a wrong
/// password on an existing one, or response timing separates "no such
/// email" from "bad password" (CWE-208). This is a one-time minted cost-12
/// hash of a random preimage the mint script discarded: verifying any
/// password against it spends the full bcrypt schedule and always returns
/// false, and even reading its source reveals nothing that helps an
/// attacker — there is no faster path through the work than doing it.
const absentEmailHash =
    r'$2a$12$Be7SsRCK5QIjmkGr923RVez7pa.WXrec7n6yj/ID6UU7wkEJzmxyG';

/// Normalizes emails for storage/lookup: trimmed + lowercased.
String normalizeEmail(String email) => email.trim().toLowerCase();
