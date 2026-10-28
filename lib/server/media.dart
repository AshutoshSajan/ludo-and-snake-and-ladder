/// Chat media notes — voice recordings and keyboard GIFs — and the HTTP
/// endpoints that move them.
///
/// A recording or a keyboard-inserted GIF never transits the room's
/// WebSocket — too big. The client POSTs the bytes to `/media/voice` or
/// `/media/image` (raw body; the room, the id and the mime type ride in
/// the query and headers), and then announces the upload as a normal
/// chat line — for the voice a `'note'` intent field, for the image the
/// ordinary `'gif'` URL — where the authority validates the note exists
/// before it broadcasts. Others pull the bytes from
/// `GET /media/<kind>/<room>/<note-id>`.
///
/// The store is in-memory and per-instance **on purpose**: rooms already
/// live this way, a note belongs to one room's chat, and the upload and
/// the announcement both land on the instance that owns that room — so
/// nothing here ever needs shared storage. Caps keep a bad actor (or a
/// bug) from turning the server into a hosting farm: a note is capped
/// per its kind ([maxVoiceNoteBytes] for recordings,
/// [maxImageNoteBytes] for keyboard images), a room keeps at most
/// [maxPerRoom] of them (oldest-first eviction), the whole store stays
/// under [maxBytes], and everything older than [ttl] is swept away
/// lazily.
///
/// Announced media is immutable (CWE-639): a URL names both its id and
/// a [MediaNote.contentTag] digest of the bytes it was announced with,
/// and serving verifies that binding. The reservation of evicted ids
/// (see [_retired]) is a second, bounded guard against mounting new
/// bytes onto a live id; the URL's content tag is what keeps *history*
/// safe even after the reservation window rotates, because a
/// replacement upload can only ever be fetched through the replacement's
/// own tagged URL — the old message's URL fails the tag check.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:shelf/shelf.dart' as shelf;

/// The two chat media kinds. The kind drives the URL path, the size cap
/// and which extra validations apply.
enum MediaKind {
  voice,
  image;

  String get pathSegment => name;
}

/// One held chat media note: a recording or a keyboard-inserted image.
class MediaNote {
  MediaNote({
    required this.kind,
    required this.code,
    required this.id,
    required this.mime,
    required this.durMs,
    required this.data,
    required this.storedAt,
  }) : contentTag = _contentTagOf(data);

  final MediaKind kind;
  final String code;
  final String id;
  final String mime;
  final int durMs;
  final Uint8List data;
  final DateTime storedAt;

  /// A digest of [data], carried as the last segment of [urlPath]. Ids
  /// alone are not enough: the store's reservation window for evicted
  /// ids is a bounded memory guard, so a churned room can rotate an old
  /// id back into the free pool. Without this tag, a new upload could
  /// then mount different bytes under a URL an earlier chat line still
  /// shows, and history would serve the replacement under its author's
  /// name (CWE-639). With it, the URL names the bytes: serving checks
  /// the tag, so a replacement is reachable only through the
  /// replacement's own URL.
  final String contentTag;

  /// The playback path, exactly as the chat broadcast carries it —
  /// relative, so the origin is never baked into the store.
  String get urlPath => '/media/${kind.pathSegment}/$code/$id/$contentTag';
}

/// The first 128 bits of SHA-256, url-safe: a 22-character path segment
/// long enough that a different body cannot land on an existing URL's
/// tag, short enough to keep the announced URL tidy.
String _contentTagOf(Uint8List data) => base64UrlEncode(
  crypto.sha256.convert(data).bytes.sublist(0, 16),
).replaceAll('=', '');

/// Note ids come from the client and end up in a URL path: charset and
/// length are the whole defense, so they are strict.
final RegExp mediaNoteIdPattern = RegExp(r'^[a-z0-9][a-z0-9-]{5,31}$');

class MediaNoteStore {
  MediaNoteStore({
    DateTime Function()? now,
    this.ttl = const Duration(hours: 24),
    this.maxVoiceNoteBytes = 2 * 1024 * 1024,
    this.maxImageNoteBytes = 6 * 1024 * 1024,
    this.maxPerRoom = 24,
    this.maxBytes = 32 * 1024 * 1024,
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Duration ttl;

  /// A recorded chunk of speech is seconds long; 2 MiB holds that with
  /// headroom. A keyboard GIF is a few frames of animation; 6 MiB
  /// covers realistic ones while still refusing absurd uploads.
  final int maxVoiceNoteBytes;
  final int maxImageNoteBytes;
  final int maxPerRoom;
  final int maxBytes;

  /// How many evicted ids stay reserved per (room, kind): see [_retired].
  static const maxReservationsPerKind = 128;

  int maxNoteBytesFor(MediaKind kind) =>
      kind == MediaKind.voice ? maxVoiceNoteBytes : maxImageNoteBytes;

  /// code -> id -> note, both maps in insertion order.
  final Map<String, Map<MediaKind, Map<String, MediaNote>>> _rooms = {};
  int _totalBytes = 0;

  /// Ids whose bytes left the store — evicted by a cap, a budget or the
  /// sweep — so an announced URL stays attached to its author's bytes
  /// even after the store stops holding them (CWE-639 is the immutability
  /// side of announcements; this is the eviction side). The timestamp is
  /// when the note LEFT (not when it was stored), and the entry ages out
  /// with the same [ttl] the notes age out with: by then the URL has been
  /// unresolvable for the full note ttl already. Per (room, kind) the
  /// window is capped at [maxReservationsPerKind] — a genuine
  /// reservation never rotates out within a normal room's life, while a
  /// fabricated id flood cannot grow this map unboundedly.
  ///
  /// The cap is a memory guard, not the immutability guarantee: a room
  /// churned past it can re-use an id, but every announced URL still
  /// names its bytes ([MediaNote.contentTag]), so the old URL cannot
  /// serve replacement content even then.
  final Map<String, Map<MediaKind, Map<String, DateTime>>> _retired = {};

  /// Stores a note, sweeping expired notes and evicting the oldest notes
  /// as needed for the room and byte budgets. Returns null for an invalid
  /// id, empty room code, empty or oversized data, or a voice duration
  /// outside the inclusive range of 100 to 60,000 milliseconds.
  ///
  /// An occupied (room, kind, id) returns null without changing the store,
  /// even if that note has expired but has not yet been swept — and so does
  /// a (room, kind, id) whose evicted or swept note still holds a
  /// reservation: new bytes cannot mount themselves onto a live id at all.
  MediaNote? put({
    required MediaKind kind,
    required String code,
    required String id,
    required Uint8List data,
    required String mime,
    int durMs = 0,
  }) {
    if (!mediaNoteIdPattern.hasMatch(id)) return null;
    if (code.isEmpty) return null;
    if (data.isEmpty || data.length > maxNoteBytesFor(kind)) return null;
    // A second of silence is a bug; a minute is the recorder's own cap.
    // An image carries no duration at all.
    if (kind == MediaKind.voice && (durMs < 100 || durMs > 60_000)) {
      return null;
    }
    // Announced media is immutable (CWE-639): the chat line that carried
    // this URL keeps its author's attribution, so a second upload onto the
    // same (room, kind, id) is either a retry or an attempt to swap the
    // bytes under a live message. Refused before anything moves —
    // no sweep, no eviction, no byte bookkeeping — so the original note
    // survives exactly as its author held it. The refusal reaches past
    // eviction too: an evicted id stays reserved (see [_retired]), so a
    // flood that pushes an announced note out of a room cannot re-mount
    // new bytes on the history's URL. An expired note lands here as that
    // fresh reservation: a day dead, its id is still not available —
    // until the [ttl] ages the reservation out (by then the URL has been
    // unresolvable for a whole note lifetime).
    //
    // Past the bounded reservation window an id may become free again;
    // that is safe because the *URL* is content-bound: [MediaNote.urlPath]
    // carries a digest of the bytes, and mediaNoteServe verifies it, so
    // the old message's URL can never serve the new note.
    final t = _now();
    _sweep(t);
    final slot = _rooms[code]?[kind];
    if (slot != null && slot.containsKey(id)) return null;
    if (_retired[code]?[kind]?.containsKey(id) ?? false) return null;

    final room = _rooms.putIfAbsent(code, () => {});
    // Room full: the oldest note of any kind yields its place first.
    int roomCount(Map<MediaKind, Map<String, MediaNote>> slots) =>
        slots.values.fold(0, (n, slot) => n + slot.length);
    while (roomCount(room) >= maxPerRoom) {
      final victim = _oldestInRoom(room);
      if (victim == null) break;
      _totalBytes -= room[victim.$1]!.remove(victim.$2)!.data.length;
      _retire(code, victim.$1, victim.$2, t);
    }
    // Budget over: walk rooms oldest-first, dropping their oldest notes.
    while (_totalBytes + data.length > maxBytes) {
      final victim = _oldestId();
      if (victim == null) break;
      final (victimRoom, victimKind, victimId) = victim;
      _totalBytes -= _rooms[victimRoom]![victimKind]!
          .remove(victimId)!
          .data
          .length;
      if (_rooms[victimRoom]![victimKind]!.isEmpty) {
        _rooms[victimRoom]!.remove(victimKind);
      }
      if (_rooms[victimRoom]!.isEmpty) _rooms.remove(victimRoom);
      _retire(victimRoom, victimKind, victimId, t);
    }

    final note = MediaNote(
      kind: kind,
      id: id,
      code: code,
      mime: mime,
      durMs: durMs,
      data: data,
      storedAt: t,
    );
    room.putIfAbsent(kind, () => {})[id] = note;
    _totalBytes += data.length;
    return note;
  }

  /// Whether a note already occupies this exact (room, kind, id) slot.
  ///
  /// The upload handler's fast path for answering a duplicate with a
  /// pointed 409 instead of the generic 400. Reporting, never authority:
  /// across the handler's awaits a racing upload can slip in, so [put]
  /// re-verifies the same rule atomically and always has the last word.
  /// A reserved (evicted) id answers the same: the wording's fix — send
  /// it under a fresh id — is what an evicted id's author's old chat
  /// line needs anyway.
  bool exists({
    required MediaKind kind,
    required String code,
    required String id,
  }) =>
      (_rooms[code]?[kind]?.containsKey(id) ?? false) ||
      (_retired[code]?[kind]?.containsKey(id) ?? false);

  /// Fetches one note, sweeping expired ones first — the lookup itself is
  /// the cheapest place to age things out, since a pull after a day is
  /// the note's last chance to matter anyway.
  MediaNote? get(MediaKind kind, String code, String id) {
    _sweep(_now());
    final room = _rooms[code];
    final note = room?[kind]?[id];
    if (note == null) return null;
    if (room![kind]!.isEmpty) room.remove(kind);
    if (room.isEmpty) _rooms.remove(code);
    return note;
  }

  Map<String, int> get roomsStats => {
    for (final e in _rooms.entries)
      e.key: e.value.values.fold(
        0,
        (sum, slot) => sum + slot.length,
      ),
  };

  int get totalBytes => _totalBytes;

  /// The (kind, id) of the very oldest note in one room — the room-cap
  /// eviction starts from the front of that queue.
  (MediaKind, String)? _oldestInRoom(Map<MediaKind, Map<String, MediaNote>> room) {
    DateTime? best;
    (MediaKind, String)? pick;
    for (final slot in room.entries) {
      for (final note in slot.value.entries) {
        if (best == null || note.value.storedAt.isBefore(best)) {
          best = note.value.storedAt;
          pick = (slot.key, note.key);
        }
      }
    }
    return pick;
  }

  /// The (room, kind, id) of the very oldest note alive — budget
  /// eviction walks from the front of that queue.
  (String, MediaKind, String)? _oldestId() {
    DateTime? best;
    (String, MediaKind, String)? pick;
    for (final room in _rooms.entries) {
      for (final slot in room.value.entries) {
        for (final note in slot.value.entries) {
          if (best == null || note.value.storedAt.isBefore(best)) {
            best = note.value.storedAt;
            pick = (room.key, slot.key, note.key);
          }
        }
      }
    }
    return pick;
  }

  /// Reserves an id after its note left the store — the eviction twin of
  /// the immutability gate in [put]: until it ages out or is rotated by
  /// the cap below, a freed id is not available to mount different bytes
  /// under the same URL. Capped FIFO per (room, kind): the oldest
  /// reservation yields when a room's kind space exhausts
  /// [maxReservationsPerKind], which protects the store from a
  /// fabricated-id flood. That rotation cannot reopen history, because
  /// announced URLs carry a [MediaNote.contentTag] and serving verifies
  /// it — the reservation is belt to that braces.
  void _retire(String code, MediaKind kind, String id, DateTime t) {
    final perKind = _retired
        .putIfAbsent(code, () => {})
        .putIfAbsent(kind, () => {});
    perKind[id] = t;
    // Plain insertion-order FIFO: reservations land one per eviction, so
    // the first key is the oldest, and a flood that outruns the cap
    // opens its own old ids back up — never the room's recent history,
    // and never an already-announced URL, whose content tag still binds
    // it to its original bytes.
    while (perKind.length > maxReservationsPerKind) {
      perKind.remove(perKind.keys.first);
    }
  }

  void _sweep(DateTime t) {
    final deadRooms = <String>[];
    for (final room in _rooms.entries) {
      for (final slot in room.value.entries) {
        final deadIds = <String>[];
        for (final note in slot.value.entries) {
          if (t.difference(note.value.storedAt) > ttl) {
            deadIds.add(note.key);
            _totalBytes -= note.value.data.length;
          }
        }
        for (final id in deadIds) {
          slot.value.remove(id);
          _retire(room.key, slot.key, id, t);
        }
      }
      room.value.removeWhere((_, notes) => notes.isEmpty);
      if (room.value.isEmpty) deadRooms.add(room.key);
    }
    for (final c in deadRooms) {
      _rooms.remove(c);
    }
    // Reservations age out with the notes' own ttl: a whole [ttl] has
    // passed since the note left, so its URL has been unresolvable that
    // long already — nothing announces or pulls it anymore, and the id
    // returns to the free pool.
    final deadReservationRooms = <String>[];
    for (final room in _retired.entries) {
      for (final slot in room.value.entries) {
        final stale = [
          for (final e in slot.value.entries)
            if (t.difference(e.value) > ttl) e.key,
        ];
        for (final id in stale) {
          slot.value.remove(id);
        }
      }
      room.value.removeWhere((_, reserved) => reserved.isEmpty);
      if (room.value.isEmpty) deadReservationRooms.add(room.key);
    }
    for (final c in deadReservationRooms) {
      _retired.remove(c);
    }
  }
}

/// Shared upload validation: the room must be live on this instance —
/// uploads ride the room's chat, so a note for a room that does not
/// exist here has nowhere to be announced.
///
/// Checks [mimeOk] before reading and optional [bodyOk] after reading a
/// size-limited body. Success returns the stored URL and, for voice, the
/// duration in milliseconds. Returns 405 for other methods, 404 for an
/// unknown room, 409 for an already occupied id — live or reserved by a
/// past note's eviction, so history's URLs cannot be remounted — 413 for
/// oversized data, or 400 for validation/store rejection (including a
/// racing duplicate).
/// Request stream and validation callback errors propagate.
Future<shelf.Response> _uploadNote(
  shelf.Request req, {
  required MediaKind kind,
  required MediaNoteStore store,
  required bool Function(String code) roomIsLive,
  required String verb,
  required bool Function(String mime) mimeOk,
  required String mimeError,
  bool Function(Uint8List bytes)? bodyOk,
  String? bodyError,
}) async {
  if (req.method != 'POST') {
    return _json(405, 'Use POST to upload a $verb');
  }
  final q = req.url.queryParameters;
  final code = q['room'] ?? '';
  final id = q['id'] ?? '';
  if (!roomIsLive(code)) {
    return _json(404, 'No such room to leave a $verb in');
  }
  // Announced media is immutable (CWE-639): a chat line already pointing
  // at this id keeps its author's attribution, so a second upload onto it
  // is refused with the fix named — send it under a fresh id. The check is
  // the wording fast path only; across the body-read awaits a racing
  // upload can still slip past, and [MediaNoteStore.put] re-verifies the
  // same rule atomically with the final say.
  if (store.exists(kind: kind, code: code, id: id)) {
    return _json(409, 'A $verb with this id already exists — send it under a fresh id');
  }

  final mime = (req.headers['content-type'] ?? '').split(';').first.trim();
  if (mime.isEmpty || !mimeOk(mime)) {
    return _json(400, mimeError);
  }
  int durMs = 0;
  if (kind == MediaKind.voice) {
    durMs = int.tryParse(req.headers['x-voice-duration'] ?? '') ?? 0;
  }

  final bytes = BytesBuilder(copy: false);
  final cap = store.maxNoteBytesFor(kind);
  await for (final chunk in req.read()) {
    bytes.add(chunk);
    if (bytes.length > cap) {
      return _json(413, '${verb[0].toUpperCase()}${verb.substring(1)} too large');
    }
  }
  final data = bytes.toBytes();
  // The label alone is not proof of format: check what actually arrives
  // before anything is stored. Stored notes are announce-and-immutable
  // (the CWE-639 contract above), so a body that never should have been
  // accepted could not be corrected later — the gate must run here,
  // after the cap has bounded the materialization and before
  // [MediaNoteStore.put].
  if (bodyOk != null && !bodyOk(data)) {
    return _json(400, bodyError ?? '$verb rejected (unsupported body)');
  }
  final note = store.put(
    kind: kind,
    code: code,
    id: id,
    data: data,
    mime: mime,
    durMs: durMs,
  );
  if (note == null) {
    return _json(400, '$verb rejected (id, size or duration)');
  }
  final extraBody = kind == MediaKind.voice
      ? {'url': note.urlPath, 'dur': note.durMs}
      : {'url': note.urlPath};
  return _json(200, null, extra: extraBody);
}

/// Handles `POST /media/voice?room=CODE&id=xxx` — a recorded chat note.
/// The room must be live on this instance — uploads ride the room's
/// chat, so a note for a room that does not exist here has nowhere to be
/// announced.
Future<shelf.Response> voiceNoteUpload(
  shelf.Request req, {
  required MediaNoteStore store,
  required bool Function(String code) roomIsLive,
}) => _uploadNote(
      req,
      kind: MediaKind.voice,
      store: store,
      roomIsLive: roomIsLive,
      verb: 'voice note',
      mimeOk: (mime) => mime.startsWith('audio/'),
      mimeError: 'A voice note must be audio',
    );

/// Handles `POST /media/image?room=CODE&id=xxx` — a GIF (or a still
/// image) inserted from the mobile keyboard, uploaded before it is
/// announced as a normal `'gif'` chat line. Same room-gating as voice.
///
/// Acceptance requires both an allowed raster content type and a matching
/// signature from any allowed raster format:
///
/// * the content type must name one of the four formats the
///   keyboard-content client actually sends ([_imageNoteMimes] — which
///   is exactly why `image/svg+xml`, which `image/*` used to pass, is
///   out: an SVG file is an XML *document*, not a picture, and inline
///   serving would execute it as one);
/// * the bytes themselves must begin with a real raster signature
///   ([_startsAsRaster]) — a label claiming `image/gif` never earns a
///   stored `<?xml …` or `<script>` body. These are prefix checks, not
///   full image decoding or validation of the remaining bytes.
Future<shelf.Response> imageNoteUpload(
  shelf.Request req, {
  required MediaNoteStore store,
  required bool Function(String code) roomIsLive,
}) {
  return _uploadNote(
    req,
    kind: MediaKind.image,
    store: store,
    roomIsLive: roomIsLive,
    verb: 'image note',
    mimeOk: _imageNoteMimes.contains,
    mimeError: 'Only GIF, PNG, JPEG or WebP images are accepted — '
        'SVG is a document, not a picture',
    bodyOk: _startsAsRaster,
    bodyError: 'That file does not start like a GIF, PNG, JPEG or WebP picture',
  );
}

/// The raster mimes the keyboard-content flow can produce
/// (lib/ui/shared/keyboard_content.dart's allow-list mirrored here).
const Set<String> _imageNoteMimes = {
  'image/gif',
  'image/webp',
  'image/png',
  'image/jpeg',
};

/// True when [bytes] begins with the signature of one of the four raster
/// formats [_imageNoteMimes] allows. The keyboard contract may under-label
/// the format (an IME
/// that omits its mime type is sent as `image/gif` whatever the picture
/// is — see `_safeMime`'s default), so the body need not match its own
/// label's family. Only the prefix is checked; the rest is not decoded or
/// validated as an image.
bool _startsAsRaster(Uint8List bytes) {
  bool has(int at, List<int> sig) {
    if (bytes.length - at < sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (bytes[at + i] != sig[i]) return false;
    }
    return true;
  }

  return has(0, _gif87aSignature) ||
      has(0, _gif89aSignature) ||
      has(0, _pngSignature) ||
      has(0, _jpegSignature) ||
      (has(0, _riffSignature) && has(8, _webpSignature));
}

const List<int> _gif87aSignature = [0x47, 0x49, 0x46, 0x38, 0x37, 0x61];
const List<int> _gif89aSignature = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61];
const List<int> _pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const List<int> _jpegSignature = [0xff, 0xd8, 0xff];
const List<int> _riffSignature = [0x52, 0x49, 0x46, 0x46];
const List<int> _webpSignature = [0x57, 0x45, 0x42, 0x50];

/// Handles `GET /media/<kind>/<code>/<id>/<content-tag>` — the raw bytes,
/// no-store because notes die with the room and a cached ghost is worse
/// than a 404.
///
/// The last segment is the note's [MediaNote.contentTag]; it must match
/// the tag computed from the stored bytes or the answer is a 404. That
/// check is the content binding (CWE-639): an id can be freed, rotated
/// out of the reservation window and re-used by a churned room, but any
/// URL an earlier chat line still shows names the *old* bytes and stops
/// resolving instead of serving the replacement.
///
/// The bytes are untrusted uploads, so they get served as inert as the
/// web can make them (CWE-79): `content-security-policy: sandbox` gives
/// a document load of this URL a unique opaque origin with scripting
/// disabled, and `x-content-type-options: nosniff` refuses the browser
/// any second opinion about the bytes' type. Inline mounting — the only
/// way a played note actually appears — is unaffected: those
/// directives bind document contexts, not `<img>`/`<audio>` embeds.
shelf.Response mediaNoteServe(
  shelf.Request req, {
  required MediaNoteStore store,
}) {
  final segments = req.url.pathSegments;
  if (segments.length != 5) return _json(404, 'No such media note');
  final kind = switch (segments[1]) {
    'voice' => MediaKind.voice,
    'image' => MediaKind.image,
    _ => null,
  };
  if (kind == null) return _json(404, 'No such media note');
  if (req.method != 'GET' && req.method != 'HEAD') {
    return _json(405, 'Use GET to fetch a media note');
  }
  final note = store.get(kind, segments[2], segments[3]);
  if (note == null) return _json(404, 'No such media note');
  // The URL names the bytes it was announced with. A mismatch is not a
  // "wrong version" to correct — it is a different body under an old
  // message's URL, so it must not resolve at all.
  if (segments[4] != note.contentTag) return _json(404, 'No such media note');
  return shelf.Response(
    200,
    body: note.data, // shelf_io strips the body for HEAD at the socket.
    headers: {
      'content-type': note.mime,
      'cache-control': 'no-store',
      'accept-ranges': 'none',
      'content-security-policy': 'sandbox',
      'x-content-type-options': 'nosniff',
    },
  );
}

shelf.Response _json(int status, String? text, {Map<String, dynamic>? extra}) =>
    shelf.Response(
      status,
      body: jsonEncode({
        'ok': status < 400,
        'text': ?text,
        ...?extra,
      }),
      headers: {'content-type': 'application/json'},
    );
