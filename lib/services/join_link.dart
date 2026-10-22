/// The shareable direct-join link for an online room.
///
/// The lobby's room-code card copies this, so a friend can open the URL and
/// land in the right room instead of typing four letters. The origin comes
/// from the page that is running the app (`Uri.base`), never from a
/// hard-coded deployment URL — the same build is served by Netlify, by the
/// Render/Docker server, and by local dev hosts.
library;

/// Canonical spelling of a room code: trimmed and uppercase.
///
/// The server creates rooms under uppercase codes and the load balancer
/// hashes `?code=` values, so a lowercase spelling must never travel.
String normalizeJoinCode(String code) => code.trim().toUpperCase();

/// The in-app path that opens a room, optionally as a spectator.
String joinPathFor(String code, {bool watch = false}) {
  final normalized = normalizeJoinCode(code);
  return watch ? '/join/$normalized?watch=1' : '/join/$normalized';
}

/// The absolute direct-join URL for [code].
///
/// [base] is the page URI the link should be built from; it defaults to the
/// running page ([Uri.base]). A caller that is not on the web (or a test) can
/// inject one, e.g. `Uri.parse('https://game.club')`. The path resolves from
/// the site root, which is where the deployed SPA fallback serves the app.
String joinLinkFor(String code, {Uri? base, bool watch = false}) {
  final origin = base ?? Uri.base;
  return origin.resolve(joinPathFor(code, watch: watch)).toString();
}
