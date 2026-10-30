/// Authentication primitives for the admin panel (and players later).
///
/// Passwords: PBKDF2-HMAC-SHA256 with a per-user random salt. Stored form:
/// `pbkdf2$<iterations>$<base64url salt>$<base64url hash>`.
/// Sessions: opaque 256-bit tokens. Only the SHA-256 hash is stored; the
/// raw token is shown to the client once at login.
///
/// No JWT: logout revokes by deleting the row, expiry is enforced on read,
/// and there is no signing secret to rotate or leak.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../shared/admin_credentials.dart';

/// Production work factor. Tests pass a small value explicitly — never
/// mutate this global from tests; thread the parameter instead.
const defaultPbkdf2Iterations = 100000;

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

/// PBKDF2-HMAC-SHA256. [iterations] is explicit so tests run fast while
/// production uses [defaultPbkdf2Iterations].
List<int> _pbkdf2(List<int> password, List<int> salt, int iterations) {
  const blockIndex = [0, 0, 0, 1];
  final hmac = Hmac(sha256, password);
  var u = hmac.convert([...salt, ...blockIndex]).bytes;
  var result = List<int>.from(u);
  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < result.length; j++) {
      result[j] ^= u[j];
    }
  }
  return result;
}

String hashPassword(
  String password, {
  int iterations = defaultPbkdf2Iterations,
}) {
  final salt = List<int>.generate(16, (_) => _random.nextInt(256));
  final hash = _pbkdf2(utf8.encode(password), salt, iterations);
  final b64 = base64Url.encode;
  return 'pbkdf2\$$iterations\$${b64(salt).replaceAll('=', '')}'
      '\$${b64(hash).replaceAll('=', '')}';
}

/// Constant-time verification. Returns false (never throws) on malformed
/// stored hashes so a corrupt row fails closed.
bool verifyPassword(
  String password,
  String stored, {
  int maxIterations = 1000000,
}) {
  try {
    final parts = stored.split(r'$');
    if (parts.length != 4 || parts[0] != 'pbkdf2') return false;
    final iterations = int.parse(parts[1]);
    if (iterations <= 0 || iterations > maxIterations) return false;
    List<int> decode(String s) {
      final pad = (4 - s.length % 4) % 4;
      return base64Url.decode(s + '=' * pad);
    }

    final salt = decode(parts[2]);
    final expected = decode(parts[3]);
    final actual = _pbkdf2(utf8.encode(password), salt, iterations);
    if (actual.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual[i] ^ expected[i];
    }
    return diff == 0;
  } catch (_) {
    return false;
  }
}

/// Normalizes emails for storage/lookup: trimmed + lowercased.
String normalizeEmail(String email) => email.trim().toLowerCase();
