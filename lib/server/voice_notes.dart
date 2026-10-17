/// Chat voice notes: the server-side holding pen and its HTTP endpoints.
///
/// A recorded message never transits the room's WebSocket — too big. The
/// recorder POSTs the bytes to `/media/voice` (raw body; the room, the
/// note id, the mime type and the duration ride in the query and
/// headers), and then announces the upload as a normal chat line, where
/// the authority validates the note exists before it broadcasts. Others
/// play it back from `GET /media/voice/<room>/<note-id>`.
///
/// The store is in-memory and per-instance **on purpose**: rooms already
/// live this way, a note belongs to one room's chat, and the upload and
/// the announcement both land on the instance that owns that room — so
/// nothing here ever needs shared storage. Caps keep a bad actor (or a
/// bug) from turning Juliet into a hosting farm: a note is ≤ 2 MiB, a
/// room keeps at most [maxPerRoom] of them (oldest-first eviction), the
/// whole store stays under [maxBytes], and everything older than [ttl]
/// is swept away lazily.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart' as shelf;

/// One recorded chat voice note held server-side.
class VoiceNote {
  VoiceNote({
    required this.code,
    required this.id,
    required this.mime,
    required this.durMs,
    required this.data,
    required this.storedAt,
  });

  final String code;
  final String id;
  final String mime;
  final int durMs;
  final Uint8List data;
  final DateTime storedAt;

  /// The playback path, exactly as the chat broadcast carries it —
  /// relative, so the origin is never baked into the store.
  String get urlPath => '/media/voice/$code/$id';
}

/// Note ids come from the client and end up in a URL path: charset and
/// length are the whole defense, so they are strict.
final RegExp voiceNoteIdPattern = RegExp(r'^[a-z0-9][a-z0-9-]{5,31}$');

class VoiceNoteStore {
  VoiceNoteStore({
    DateTime Function()? now,
    this.ttl = const Duration(hours: 24),
    this.maxNoteBytes = 2 * 1024 * 1024,
    this.maxPerRoom = 24,
    this.maxBytes = 32 * 1024 * 1024,
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Duration ttl;
  final int maxNoteBytes;
  final int maxPerRoom;
  final int maxBytes;

  /// code -> id -> note, both maps in insertion order.
  final Map<String, Map<String, VoiceNote>> _rooms = {};
  int _totalBytes = 0;

  /// Stores one note. Null when any door says no: id shape, size and
  /// duration sanity, the per-room cap, or the running byte budget.
  VoiceNote? put({
    required String code,
    required String id,
    required Uint8List data,
    required String mime,
    required int durMs,
  }) {
    if (!voiceNoteIdPattern.hasMatch(id)) return null;
    if (code.isEmpty) return null;
    if (data.isEmpty || data.length > maxNoteBytes) return null;
    // A second of silence is a bug; a minute is the recorder's own cap.
    if (durMs < 100 || durMs > 60_000) return null;

    final t = _now();
    _sweep(t);

    final room = _rooms.putIfAbsent(code, () => {});
    // Room full: the oldest note yields its place first.
    while (room.length >= maxPerRoom) {
      final oldest = room.keys.first;
      _totalBytes -= room.remove(oldest)!.data.length;
    }
    // Budget over: walk rooms oldest-first, dropping their oldest notes.
    while (_totalBytes + data.length > maxBytes) {
      final victim = _oldestId();
      if (victim == null) break;
      _totalBytes -= _rooms[victim.$1]!.remove(victim.$2)!.data.length;
      if (_rooms[victim.$1]!.isEmpty) _rooms.remove(victim.$1);
    }

    final note = VoiceNote(
      code: code,
      id: id,
      mime: mime,
      durMs: durMs,
      data: data,
      storedAt: t,
    );
    room[id] = note;
    _totalBytes += data.length;
    return note;
  }

  /// Fetches one note, sweeping expired ones first — the lookup itself is
  /// the cheapest place to age things out, since a pull after a day is
  /// the note's last chance to matter anyway.
  VoiceNote? get(String code, String id) {
    _sweep(_now());
    final room = _rooms[code];
    if (room == null) return null;
    final note = room[id];
    if (note == null) return null;
    if (_rooms[code]!.isEmpty) _rooms.remove(code);
    return note;
  }

  Map<String, int> get roomsStats => {
    for (final e in _rooms.entries) e.key: e.value.length,
  };

  int get totalBytes => _totalBytes;

  /// The (room, id) of the very oldest note alive — budget eviction walks
  /// from the front of that queue.
  (String, String)? _oldestId() {
    DateTime? best;
    (String, String)? pick;
    for (final room in _rooms.entries) {
      for (final note in room.value.entries) {
        if (best == null || note.value.storedAt.isBefore(best)) {
          best = note.value.storedAt;
          pick = (room.key, note.key);
        }
      }
    }
    return pick;
  }

  void _sweep(DateTime t) {
    final deadRooms = <String>[];
    for (final room in _rooms.entries) {
      final deadIds = <String>[];
      for (final note in room.value.entries) {
        if (t.difference(note.value.storedAt) > ttl) {
          deadIds.add(note.key);
          _totalBytes -= note.value.data.length;
        }
      }
      for (final id in deadIds) {
        room.value.remove(id);
      }
      if (room.value.isEmpty) deadRooms.add(room.key);
    }
    for (final c in deadRooms) {
      _rooms.remove(c);
    }
  }
}

/// Handles `POST /media/voice?room=CODE&id=xxx`. The room must be live on
/// this instance — uploads ride the room's chat, so a note for a room
/// that does not exist here has nowhere to be announced.
Future<shelf.Response> voiceNoteUpload(
  shelf.Request req, {
  required VoiceNoteStore store,
  required bool Function(String code) roomIsLive,
}) async {
  if (req.method != 'POST') {
    return _json(405, 'Use POST to upload a voice note');
  }
  final q = req.url.queryParameters;
  final code = q['room'] ?? '';
  final id = q['id'] ?? '';
  if (!roomIsLive(code)) {
    return _json(404, 'No such room to leave a voice note in');
  }

  final mime = (req.headers['content-type'] ?? '').split(';').first.trim();
  if (mime.isEmpty || !mime.startsWith('audio/')) {
    return _json(400, 'A voice note must be audio');
  }
  final durMs = int.tryParse(req.headers['x-voice-duration'] ?? '') ?? 0;

  final bytes = BytesBuilder(copy: false);
  const cap = 2 * 1024 * 1024;
  await for (final chunk in req.read()) {
    bytes.add(chunk);
    if (bytes.length > cap) {
      return _json(413, 'Voice note too large');
    }
  }
  final note = store.put(
    code: code,
    id: id,
    data: bytes.toBytes(),
    mime: mime,
    durMs: durMs,
  );
  if (note == null) {
    return _json(400, 'Voice note rejected (id, size or duration)');
  }
  return _json(200, null, extra: {'url': note.urlPath, 'dur': note.durMs});
}

/// Handles `GET /media/voice/<code>/<id>` — the raw recording, no-store
/// because notes die with the room and a cached ghost is worse than a
/// 404.
shelf.Response voiceNoteServe(
  shelf.Request req, {
  required VoiceNoteStore store,
}) {
  final segments = req.url.pathSegments;
  if (segments.length != 4) return _json(404, 'No such voice note');
  if (req.method != 'GET' && req.method != 'HEAD') {
    return _json(405, 'Use GET to fetch a voice note');
  }
  final note = store.get(segments[2], segments[3]);
  if (note == null) return _json(404, 'No such voice note');
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
