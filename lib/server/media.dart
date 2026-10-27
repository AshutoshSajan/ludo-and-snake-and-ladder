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
  final note = store.put(
    kind: kind,
    code: code,
    id: id,
    data: bytes.toBytes(),
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
Future<shelf.Response> imageNoteUpload(
  shelf.Request req, {
  required MediaNoteStore store,
  required bool Function(String code) roomIsLive,
}) {
  bool imageMime(String mime) => mime.startsWith('image/');
  return _uploadNote(
    req,
    kind: MediaKind.image,
    store: store,
    roomIsLive: roomIsLive,
    verb: 'image note',
    mimeOk: imageMime,
    mimeError: 'A keyboard image must be a picture',
  );
}

/// Handles `GET /media/<kind>/<code>/<id>` — the raw bytes, no-store
/// because notes die with the room and a cached ghost is worse than a
/// 404.
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
