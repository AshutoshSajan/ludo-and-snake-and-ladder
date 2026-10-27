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
/// per its kind ([maxVoiceNoteBytes] for recordings, [maxImageNoteBytes]
/// for keyboard images), a room keeps at most [maxPerRoom] of them
/// (oldest-first eviction), the whole store stays under [maxBytes], and
/// everything older than [ttl] is swept away lazily.
library;

import 'dart:convert';
import 'dart:typed_data';

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
  });

  final MediaKind kind;
  final String code;
  final String id;
  final String mime;
  final int durMs;
  final Uint8List data;
  final DateTime storedAt;

  /// The playback path, exactly as the chat broadcast carries it —
  /// relative, so the origin is never baked into the store.
  String get urlPath => '/media/${kind.pathSegment}/$code/$id';
}

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

  int maxNoteBytesFor(MediaKind kind) =>
      kind == MediaKind.voice ? maxVoiceNoteBytes : maxImageNoteBytes;

  /// code -> id -> note, both maps in insertion order.
  final Map<String, Map<MediaKind, Map<String, MediaNote>>> _rooms = {};
  int _totalBytes = 0;

  /// Stores one note. Null when any door says no: id shape, size cap of
  /// its kind, the duration sanity for a voice note, the per-room cap,
  /// or the running byte budget.
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
    // survives exactly as its author held it.
    final slot = _rooms[code]?[kind];
    if (slot != null && slot.containsKey(id)) return null;

    final t = _now();
    _sweep(t);

    final room = _rooms.putIfAbsent(code, () => {});
    // Room full: the oldest note of any kind yields its place first.
    int roomCount(Map<MediaKind, Map<String, MediaNote>> slots) =>
        slots.values.fold(0, (n, slot) => n + slot.length);
    while (roomCount(room) >= maxPerRoom) {
      final victim = _oldestInRoom(room);
      if (victim == null) break;
      _totalBytes -= room[victim.$1]!.remove(victim.$2)!.data.length;
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
  bool exists({
    required MediaKind kind,
    required String code,
    required String id,
  }) =>
      _rooms[code]?[kind]?.containsKey(id) ?? false;

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
        }
      }
      room.value.removeWhere((_, notes) => notes.isEmpty);
      if (room.value.isEmpty) deadRooms.add(room.key);
    }
    for (final c in deadRooms) {
      _rooms.remove(c);
    }
  }
}

/// Shared upload validation: the room must be live on this instance —
/// uploads ride the room's chat, so a note for a room that does not
/// exist here has nowhere to be announced.
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
/// Only inert raster formats are accepted (CWE-79), on both gates what
/// can reach the serve path:
///
/// * the content type must name one of the four formats the
///   keyboard-content client actually sends ([_imageNoteMimes] — which
///   is exactly why `image/svg+xml`, which `image/*` used to pass, is
///   out: an SVG file is an XML *document*, not a picture, and inline
///   serving would execute it as one);
/// * the bytes themselves must begin with a real raster signature
///   ([_startsAsRaster]) — a label claiming `image/gif` never earns a
///   stored `<?xml …` or `<script>` body.
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
/// formats [_imageNoteMimes] allows — anything else, active documents
/// and markup included, starts differently and is refused before it can
/// be stored. The keyboard contract may under-label the format (an IME
/// that omits its mime type is sent as `image/gif` whatever the picture
/// is — see `_safeMime`'s default), so the body need not match its own
/// label's family; it only must be *some* verified inert raster.
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

/// Handles `GET /media/<kind>/<code>/<id>` — the raw bytes, no-store
/// because notes die with the room and a cached ghost is worse than a
/// 404.
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
  if (segments.length != 4) return _json(404, 'No such media note');
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
