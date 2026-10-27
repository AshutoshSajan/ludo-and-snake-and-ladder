/// Tests for the chat media-note server: the [MediaNoteStore]'s caps and
/// sweeps, and the upload/serve endpoints' refusals — voice and
/// keyboard-image kinds share the one room budget. The store takes an
/// injectable clock so TTL behaviour is deterministic, not slept.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/server/media.dart';
import 'package:shelf/shelf.dart' as shelf;

/// A DateTime advance-by knob for the store's clock.
class _Clock {
  DateTime now = DateTime(2026, 1, 1, 12);
}

MediaNoteStore _store(_Clock clock, {int? maxPerRoom, int? maxBytes}) =>
    MediaNoteStore(
      now: () => clock.now,
      maxPerRoom: maxPerRoom ?? 24,
      maxBytes: maxBytes ?? 32 * 1024 * 1024,
    );

Future<shelf.Response> _upload(
  String kindPath,
  shelf.Request req, {
  required MediaNoteStore store,
  bool live = true,
}) => kindPath == 'voice'
    ? voiceNoteUpload(req, store: store, roomIsLive: (_) => live)
    : imageNoteUpload(req, store: store, roomIsLive: (_) => live);

void main() {
  group('MediaNoteStore', () {
    test('a stored voice note round trips through get() with its url path', () {
      final store = _store(_Clock());
      final data = Uint8List.fromList([1, 2, 3]);
      final note = store.put(
        kind: MediaKind.voice,
        code: 'ROOM',
        id: 'abcdefgh',
        data: data,
        mime: 'audio/mp4',
        durMs: 1500,
      );
      expect(note, isNotNull);
      expect(note!.urlPath, '/media/voice/ROOM/abcdefgh');
      final back = store.get(MediaKind.voice, 'ROOM', 'abcdefgh');
      expect(back!.data, data);
      expect(back.mime, 'audio/mp4');
      expect(back.durMs, 1500);
      expect(store.totalBytes, 3);
    });

    test('a put onto an occupied room/kind/id refuses and preserves the '
        'original', () {
      final store = _store(_Clock());
      final data = Uint8List.fromList([1, 2, 3]);
      final first = store.put(
        kind: MediaKind.voice,
        code: 'ROOM',
        id: 'abcdefgh',
        data: data,
        mime: 'audio/mp4',
        durMs: 1500,
      );
      expect(first, isNotNull);

      // A would-be swap: same coordinates, a different recording.
      final swapped = store.put(
        kind: MediaKind.voice,
        code: 'ROOM',
        id: 'abcdefgh',
        data: Uint8List.fromList([9, 9, 9]),
        mime: 'audio/mp4',
        durMs: 1000,
      );
      expect(swapped, isNull);

      final back = store.get(MediaKind.voice, 'ROOM', 'abcdefgh')!;
      expect(back.data, data,
          reason: 'the author recording survives the refusal byte for byte');
      expect(back.durMs, 1500);
      expect(back.storedAt, first!.storedAt);
    });

    test('the id key binds per room and per kind, not globally', () {
      final store = _store(_Clock());
      final data = Uint8List.fromList([1]);
      expect(
        store.put(
          kind: MediaKind.voice,
          code: 'ROOM',
          id: 'abcdefgh',
          data: data,
          mime: 'audio/mp4',
          durMs: 1500,
        ),
        isNotNull,
      );
      // Same id, other room: a fresh, unrelated note.
      expect(
        store.put(
          kind: MediaKind.voice,
          code: 'OTHER',
          id: 'abcdefgh',
          data: data,
          mime: 'audio/mp4',
          durMs: 1500,
        ),
        isNotNull,
      );
      // Same id, other kind in the same room: voice and image slots never
      // collide.
      expect(
        store.put(
          kind: MediaKind.image,
          code: 'ROOM',
          id: 'abcdefgh',
          data: data,
          mime: 'image/gif',
        ),
        isNotNull,
      );
    });

    test('a refused put leaves the caps and bookkeeping untouched', () {
      final store = _store(_Clock());
      final data = Uint8List.fromList([1, 2]);
      final oldest = store.put(
        kind: MediaKind.voice,
        code: 'ROOM',
        id: 'aaaaaa',
        data: data,
        mime: 'audio/mp4',
        durMs: 1500,
      );
      final newer = store.put(
        kind: MediaKind.image,
        code: 'ROOM',
        id: 'bbbbbb',
        data: data,
        mime: 'image/gif',
      );
      expect(oldest, isNotNull);
      expect(newer, isNotNull);
      final statsBefore = store.roomsStats;
      final bytesBefore = store.totalBytes;

      // An overwrite attempt must not run the room-cap eviction either:
      // nothing ages out, nothing gives ground, the store is inert.
      expect(
        store.put(
          kind: MediaKind.voice,
          code: 'ROOM',
          id: 'aaaaaa',
          data: Uint8List.fromList([9, 9]),
          mime: 'audio/mp4',
          durMs: 1500,
        ),
        isNull,
      );
      expect(store.roomsStats, statsBefore);
      expect(store.totalBytes, bytesBefore);
      expect(store.get(MediaKind.voice, 'ROOM', 'aaaaaa')!.data, data);
    });

    test('an expired-but-not-yet-swept id still refuses recreation', () {
      final clock = _Clock();
      final store = _store(clock);
      final data = Uint8List.fromList([1]);
      final note = store.put(
        kind: MediaKind.voice,
        code: 'ROOM',
        id: 'abcdefgh',
        data: data,
        mime: 'audio/mp4',
        durMs: 1500,
      );
      expect(note, isNotNull);

      // Past the TTL, before any sweep ran: the store still holds the
      // binding, so the gate — which is checked first, before the sweep —
      // refuses. A later reader sweeps it away, and the id frees up then;
      // the point is that existence, not freshness, is what the store
      // answers atomically.
      clock.now = clock.now.add(const Duration(hours: 25));
      expect(
        store.put(
          kind: MediaKind.voice,
          code: 'ROOM',
          id: 'abcdefgh',
          data: data,
          mime: 'audio/mp4',
          durMs: 1500,
        ),
        isNull,
      );
    });

    test('a malformed id is refused — it ends up in a URL path', () {
      final store = _store(_Clock());
      final data = Uint8List.fromList([1]);
      for (final bad in [
        '', // nothing at all
        'ABCdef', // the pattern is lowercase only
        'abc', // too short (needs 6+)
        '-abcde', // must start [a-z0-9]
        'a' * 33, // 33 — past the 32 cap
        'abc de', // spaces are junk
      ]) {
        expect(
          store.put(
            kind: MediaKind.voice,
            code: 'ROOM',
            id: bad,
            data: data,
            mime: 'audio/mp4',
            durMs: 500,
          ),
          isNull,
          reason: 'id "$bad" must not be storable',
        );
      }
    });

    test('oversized or empty voice notes are refused; durations are checked',
        () {
      final store = _store(_Clock());
      final filler = Uint8List(store.maxNoteBytesFor(MediaKind.voice) + 1);
      expect(
        store.put(
          kind: MediaKind.voice,
          code: 'R',
          id: 'aaaaaa',
          data: Uint8List(0),
          mime: 'audio/mp4',
          durMs: 500,
        ),
        isNull,
        reason: 'an empty note is not a note',
      );
      expect(
        store.put(
          kind: MediaKind.voice,
          code: 'R',
          id: 'aaaaaa',
          data: filler,
          mime: 'audio/mp4',
          durMs: 500,
        ),
        isNull,
        reason: 'past the per-note cap',
      );
      expect(
        store.put(
          kind: MediaKind.voice,
          code: 'R',
          id: 'aaaaaa',
          data: Uint8List(4),
          mime: 'audio/mp4',
          durMs: 50,
        ),
        isNull,
        reason: 'under 100 ms is a recording accident',
      );
      expect(
        store.put(
          kind: MediaKind.voice,
          code: 'R',
          id: 'aaaaaa',
          data: Uint8List(4),
          mime: 'audio/mp4',
          durMs: 61_000,
        ),
        isNull,
        reason: 'past the recorder cap',
      );
      expect(store.totalBytes, 0);
    });

    test('an image carries no duration and rides a larger per-note cap', () {
      final store = _store(_Clock());
      final note = store.put(
        kind: MediaKind.image,
        code: 'ROOM',
        id: 'gifaa1',
        data: Uint8List.fromList([1, 2, 3, 4]),
        mime: 'image/gif',
      );
      expect(note, isNotNull, reason: 'a keyboard gif needs no duration');
      expect(note!.urlPath, '/media/image/ROOM/gifaa1');
      final filler = Uint8List(store.maxNoteBytesFor(MediaKind.image) + 1);
      expect(
        store.put(
          kind: MediaKind.image,
          code: 'ROOM',
          id: 'gifaa2',
          data: filler,
          mime: 'image/gif',
        ),
        isNull,
        reason: 'the image cap holds even though voice caps are smaller',
      );
      expect(store.get(MediaKind.voice, 'ROOM', 'gifaa1'), isNull,
          reason: 'kinds do not cross');
    });

    test('a full room evicts its oldest note — kinds compete together', () {
      final store = _store(_Clock(), maxPerRoom: 2);
      store.put(
        kind: MediaKind.voice,
        code: 'ROOM',
        id: 'aaaaaa',
        data: Uint8List.fromList([1]),
        mime: 'audio/mp4',
        durMs: 500,
      );
      store.put(
        kind: MediaKind.image,
        code: 'ROOM',
        id: 'bbbbbb',
        data: Uint8List.fromList([2]),
        mime: 'image/gif',
      );
      store.put(
        kind: MediaKind.voice,
        code: 'ROOM',
        id: 'cccccc',
        data: Uint8List.fromList([3]),
        mime: 'audio/mp4',
        durMs: 500,
      );
      expect(
        store.get(MediaKind.voice, 'ROOM', 'aaaaaa'),
        isNull,
        reason: 'the oldest of any kind yielded',
      );
      expect(store.get(MediaKind.image, 'ROOM', 'bbbbbb'), isNotNull);
      expect(store.get(MediaKind.voice, 'ROOM', 'cccccc'), isNotNull);
      expect(store.roomsStats['ROOM'], 2);
    });

    test('the global byte budget evicts the oldest note anywhere', () {
      final store = _store(_Clock(), maxBytes: 8);
      store.put(
        kind: MediaKind.voice,
        code: 'R1',
        id: 'aaaaaa',
        data: Uint8List(4),
        mime: 'audio/mp4',
        durMs: 500,
      );
      store.put(
        kind: MediaKind.image,
        code: 'R2',
        id: 'aaaaaa',
        data: Uint8List(4),
        mime: 'image/gif',
      );
      // A third four-byte note cannot exist under a 8-byte budget.
      final third = store.put(
        kind: MediaKind.voice,
        code: 'R0',
        id: 'aaaaaa',
        data: Uint8List(4),
        mime: 'audio/mp4',
        durMs: 500,
      );
      expect(third, isNotNull, reason: 'the budget evicted a victim first');
      expect(store.totalBytes, lessThanOrEqualTo(8));
      expect(store.get(MediaKind.voice, 'R1', 'aaaaaa'), isNull,
          reason: 'R1 was the oldest');
    });

    test('notes older than the TTL are swept on the next touch', () {
      final clock = _Clock();
      final store = _store(clock);
      store.put(
        kind: MediaKind.voice,
        code: 'R',
        id: 'aaaaaa',
        data: Uint8List(4),
        mime: 'audio/mp4',
        durMs: 500,
      );
      store.put(
        kind: MediaKind.image,
        code: 'R',
        id: 'bbbbbb',
        data: Uint8List(4),
        mime: 'image/gif',
      );
      clock.now = clock.now.add(const Duration(hours: 25));
      expect(store.get(MediaKind.voice, 'R', 'aaaaaa'), isNull,
          reason: 'a day old is gone');
      expect(store.get(MediaKind.image, 'R', 'bbbbbb'), isNull);
      expect(store.roomsStats, isEmpty);
      expect(store.totalBytes, 0);
    });

    test('an evicted id stays reserved: its announced history cannot be '
        'remounted with other bytes', () {
      // The reviewer's exact shape: fill the per-room cap, evict an
      // announced note, then try to upload different bytes onto its id.
      // The eviction freed the bytes, not the id (CWE-639's eviction
      // side): the chat line that carried the URL keeps naming the
      // author's note, so the id belongs to that note.
      final store = _store(_Clock(), maxPerRoom: 2);
      final original = store.put(
        kind: MediaKind.voice,
        code: 'ROOM',
        id: 'aaaaaa',
        data: Uint8List.fromList([1]),
        mime: 'audio/mp4',
        durMs: 500,
      );
      expect(original, isNotNull);
      // Two more fills the 2-cap and evicts aaaa — then removes the
      // middle one so the cap has room for the attack again.
      store.put(
        kind: MediaKind.voice,
        code: 'ROOM',
        id: 'bbbbbb',
        data: Uint8List.fromList([2]),
        mime: 'audio/mp4',
        durMs: 500,
      );
      store.put(
        kind: MediaKind.voice,
        code: 'ROOM',
        id: 'cccccc',
        data: Uint8List.fromList([3]),
        mime: 'audio/mp4',
        durMs: 500,
      );
      expect(store.get(MediaKind.voice, 'ROOM', 'aaaaaa'), isNull,
          reason: 'the original was evicted as the oldest');
      // The attack: same (room, kind, id), different bytes.
      final swap = store.put(
        kind: MediaKind.voice,
        code: 'ROOM',
        id: 'aaaaaa',
        data: Uint8List.fromList([9, 9, 9]),
        mime: 'audio/mp4',
        durMs: 500,
      );
      expect(swap, isNull, reason: 'the evicted id is reserved');
      // The reserve leaves the frees intact: the two live notes keep
      // serving, the totals did not shift.
      expect(store.get(MediaKind.voice, 'ROOM', 'bbbbbb'), isNotNull);
      expect(store.get(MediaKind.voice, 'ROOM', 'cccccc'), isNotNull);
      expect(store.roomsStats['ROOM'], 2);
      // And the upload handler's 409 fast path sees the same thing.
      expect(
        store.exists(kind: MediaKind.voice, code: 'ROOM', id: 'aaaaaa'),
        isTrue,
      );
    });

    test('a budget-evicted id and an expired id stay reserved too', () {
      final clock = _Clock();
      final store = _store(clock, maxBytes: 8);
      store.put(
        kind: MediaKind.voice,
        code: 'R1',
        id: 'aaaaaa',
        data: Uint8List(4),
        mime: 'audio/mp4',
        durMs: 500,
      );
      store.put(
        kind: MediaKind.voice,
        code: 'R2',
        id: 'bbbbbb',
        data: Uint8List(4),
        mime: 'audio/mp4',
        durMs: 500,
      );
      // The 8-byte budget holds one more 4-byte note only after
      // evicting the oldest anywhere — R1 loses its bytes.
      store.put(
        kind: MediaKind.voice,
        code: 'R3',
        id: 'cccccc',
        data: Uint8List(4),
        mime: 'audio/mp4',
        durMs: 500,
      );
      expect(store.get(MediaKind.voice, 'R1', 'aaaaaa'), isNull,
          reason: 'the bytes were budget-evicted');
      final swap = store.put(
        kind: MediaKind.voice,
        code: 'R1',
        id: 'aaaaaa',
        data: Uint8List(4),
        mime: 'audio/mp4',
        durMs: 500,
      );
      expect(swap, isNull, reason: 'the budget-evicted id stays reserved');

      // A swept-away id keeps the same stain: the ttl (not the sweep)
      // opens ids back up, because that also means the URL is a day
      // unresolvable already.
      clock.now = clock.now.add(const Duration(hours: 10));
      final swept = store.put(
        kind: MediaKind.voice,
        code: 'R9',
        id: 'fff000',
        data: Uint8List(4),
        mime: 'audio/mp4',
        durMs: 500,
      );
      expect(swept, isNotNull);
      clock.now = clock.now.add(const Duration(hours: 25));
      expect(store.get(MediaKind.voice, 'R9', 'fff000'), isNull,
          reason: 'swept by ttl');
      final reuse = store.put(
        kind: MediaKind.voice,
        code: 'R9',
        id: 'fff000',
        data: Uint8List(4),
        mime: 'audio/mp4',
        durMs: 500,
      );
      expect(reuse, isNull, reason: 'reserved while its URL could still '
          'have been pulled');
      // Still a day later, past the reservation ttl, the id frees up —
      // every pull of the old URL has long been a 404.
      clock.now = clock.now.add(const Duration(hours: 25));
      final freed = store.put(
        kind: MediaKind.voice,
        code: 'R9',
        id: 'fff000',
        data: Uint8List(4),
        mime: 'audio/mp4',
        durMs: 500,
      );
      expect(freed, isNotNull, reason: 'the reservation expired with ttl');
    });

    test('the reservation window is cap-bounded: real rooms keep their '
        'ids forever', () {
      // A 2-note room with every put evicting its oldest: the flood below
      // mints 132 notes — 130 evictions — enough to push the 128-deep
      // reservation window past its two oldest entries, after which the
      // oldest reservations yield. A real room never churns near this.
      final store = _store(_Clock(), maxPerRoom: 2);
      String idFor(int i) => 'x${i.toRadixString(36).padLeft(5, '0')}a';
      for (var i = 0; i < 132; i++) {
        store.put(
          kind: MediaKind.voice,
          code: 'R',
          id: idFor(i),
          data: Uint8List.fromList([1]),
          mime: 'audio/mp4',
          durMs: 500,
        );
      }
      // The first two reservations were rotated out by the cap.
      // The in-window id is checked FIRST: the freed-but-that-works put
      // below evicts a note of its own, which rotates the window once
      // more — sequencing matters when the window is this tight.
      final inWindow = store.put(
        kind: MediaKind.voice,
        code: 'R',
        id: idFor(2),
        data: Uint8List.fromList([7]),
        mime: 'audio/mp4',
        durMs: 500,
      );
      expect(inWindow, isNull, reason: 'still inside the 128-deep window');
      final freed = store.put(
        kind: MediaKind.voice,
        code: 'R',
        id: idFor(0),
        data: Uint8List.fromList([7]),
        mime: 'audio/mp4',
        durMs: 500,
      );
      expect(freed, isNotNull, reason: 'the oldest reservation yielded');
    });
  });

  group('voiceNoteUpload', () {
    final data = Uint8List.fromList([9, 8, 7]);

    Future<shelf.Response> post(
      MediaNoteStore store, {
      String? room = 'ROOM',
      String? id = 'abcdefgh',
      String mime = 'audio/mp4',
      String? duration = '1200',
      List<int>? body,
    }) => _upload(
          'voice',
          shelf.Request(
            'POST',
            Uri.parse(
              'http://s/media/voice'
              '?room=${room ?? ''}&id=${id ?? ''}',
            ),
            headers: {
              'content-type': ?mime.isEmpty ? null : mime,
              'x-voice-duration': ?duration,
            },
            body: body ?? data,
          ),
          store: store,
        );

    test('a good upload answers 200 with the store url and duration', () async {
      final store = _store(_Clock());
      final res = await post(store);
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['ok'], isTrue);
      expect(body['url'], '/media/voice/ROOM/abcdefgh');
      expect(body['dur'], 1200);
      expect(store.get(MediaKind.voice, 'ROOM', 'abcdefgh'), isNotNull);
    });

    test('a duplicate id answers 409 and the announced recording stands', () async {
      final store = _store(_Clock());
      final first = await post(store, body: [9, 8, 7]);
      expect(first.statusCode, 200);

      // Same coordinates, a different body: an attempt to exchange the
      // recording under a chat line already pointing at this URL.
      final second = await post(store, body: [1, 1, 1]);
      expect(second.statusCode, 409);
      final body =
          jsonDecode(await second.readAsString()) as Map<String, dynamic>;
      expect(body['ok'], isFalse);
      expect(body['text'], contains('fresh id'));

      expect(
        store.get(MediaKind.voice, 'ROOM', 'abcdefgh')!.data,
        Uint8List.fromList([9, 8, 7]),
        reason: 'the author recording survives the refused upload intact',
      );
    });

    test('a note for a room that is not live here is a 404', () async {
      final res = await _upload(
        'voice',
        shelf.Request(
          'POST',
          Uri.parse('http://s/media/voice?room=X&id=abcdefgh'),
          headers: {'content-type': 'audio/mp4', 'x-voice-duration': '1200'},
          body: data,
        ),
        store: _store(_Clock()),
        live: false,
      );
      expect(res.statusCode, 404);
    });

    test('non-audio content types are refused', () async {
      final res = await post(_store(_Clock()), mime: 'text/plain');
      expect(res.statusCode, 400);
      final res2 = await post(_store(_Clock()), mime: '');
      expect(res2.statusCode, 400);
    });

    test('a voice note body needs no raster signature', () async {
      // The body gate is an image-note construction: audio MIMEs pass
      // with whatever bytes the recorder produced — [9, 8, 7] starts like
      // nothing a real audio container does, and is kept anyway.
      final store = _store(_Clock());
      final res = await post(store, body: [9, 8, 7]);
      expect(res.statusCode, 200);
      expect(store.get(MediaKind.voice, 'ROOM', 'abcdefgh'), isNotNull);
    });

    test('a missing duration header is a 400, not a stored 0', () async {
      final store = _store(_Clock());
      final res = await post(store, duration: null);
      expect(res.statusCode, 400);
      expect(store.totalBytes, 0);
    });

    test('a malformed id reaches the store check and 400s', () async {
      final res = await post(_store(_Clock()), id: 'Bad_ID');
      expect(res.statusCode, 400);
    });

    test('a body past the per-note cap is a 413 mid-stream', () async {
      final res = await post(
        _store(_Clock()),
        body: Uint8List(2 * 1024 * 1024 + 1),
      );
      expect(res.statusCode, 413);
    });

    test('GET on the upload path is 405', () async {
      final res = await _upload(
        'voice',
        shelf.Request(
          'GET',
          Uri.parse('http://s/media/voice?room=ROOM&id=abcdefgh'),
        ),
        store: _store(_Clock()),
      );
      expect(res.statusCode, 405);
    });
  });

  group('imageNoteUpload', () {
    // The full 6-byte GIF file header ("GIF89a") — the gate verifies a
    // real raster signature, so the fixture must be a real one.
    final gifBytes = Uint8List.fromList([71, 73, 70, 56, 57, 97]);

    Future<shelf.Response> post(
      MediaNoteStore store, {
      String? room = 'ROOM',
      String? id = 'gifabc',
      String mime = 'image/gif',
      List<int>? body,
    }) => _upload(
          'image',
          shelf.Request(
            'POST',
            Uri.parse(
              'http://s/media/image'
              '?room=${room ?? ''}&id=${id ?? ''}',
            ),
            headers: {'content-type': mime},
            body: body ?? gifBytes,
          ),
          store: store,
        );

    test('a good upload answers 200 with the store url — and no duration',
        () async {
      final store = _store(_Clock());
      final res = await post(store);
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['ok'], isTrue);
      expect(body['url'], '/media/image/ROOM/gifabc');
      expect(body.containsKey('dur'), isFalse,
          reason: 'an image has no playback duration');
      expect(store.get(MediaKind.image, 'ROOM', 'gifabc'), isNotNull);
    });

    test('a duplicate id answers 409 and the announced image stands', () async {
      final store = _store(_Clock());
      final first = await post(store, body: gifBytes);
      expect(first.statusCode, 200);

      // Same coordinates, a different image: an attempt to exchange the
      // bytes under a chat line already pointing at this URL.
      final body2 = Uint8List.fromList([0, 1, 2, 3]);
      final second = await post(store, body: body2);
      expect(second.statusCode, 409);
      expect(
        store.get(MediaKind.image, 'ROOM', 'gifabc')!.data,
        gifBytes,
        reason: 'the author image survives the refused upload intact',
      );
    });

    test('a dead room is a 404 like voice', () async {
      final res = await _upload(
        'image',
        shelf.Request(
          'POST',
          Uri.parse('http://s/media/image?room=GHOST&id=gifabc'),
          headers: {'content-type': 'image/gif'},
          body: gifBytes,
        ),
        store: _store(_Clock()),
        live: false,
      );
      expect(res.statusCode, 404);
    });

    test('non-image content types are refused', () async {
      final res = await post(_store(_Clock()), mime: 'text/plain');
      expect(res.statusCode, 400);
      final res2 = await post(_store(_Clock()), mime: '');
      expect(res2.statusCode, 400);
    });

    test('SVG content types are refused, with the reason in the wording',
        () async {
      // image/svg+xml passed the old image/* gate; it is a document,
      // not a picture, and inline serving would have executed it.
      final svgBytes = Uint8List.fromList(
        utf8.encode('<?xml version="1.0"?><svg>…'),
      );
      final res = await post(
        _store(_Clock()),
        mime: 'image/svg+xml',
        body: svgBytes,
      );
      expect(res.statusCode, 400);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['text'], contains('SVG'));

      final store = _store(_Clock());
      final res2 = await post(store, mime: 'image/svg+xml', body: svgBytes);
      expect(res2.statusCode, 400);
      expect(store.totalBytes, 0, reason: 'nothing of it is ever held');
    });

    test('raster mimes are the whole accept-list, matching the keyboard client',
        () async {
      // Exactly what lib/ui/shared/keyboard_content.dart may send —
      // anything beyond (image/avif, image/bmp, …) is refused at the mime
      // gate even when the body is a decent raster. GIF and WebP are
      // covered by their signature tests below.
      for (final (mime, sig, id) in [
        ('image/png', [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 'gifabc'),
        ('image/jpeg', [0xff, 0xd8, 0xff], 'gifabd'),
      ]) {
        final store = _store(_Clock());
        final res = await post(store, id: id, mime: mime, body: sig);
        expect(res.statusCode, 200, reason: '$mime accepted with its own bytes');
      }
    });

    test('a raster-labelled body that is not a raster is refused intact',
        () async {
      // The label claiming image/gif does not earn a stored markup body:
      // signature gate catches whatever survived past the mime gate.
      final store = _store(_Clock());
      final markup = Uint8List.fromList(
        utf8.encode('<script>alert(1)</script>'),
      );
      final res = await post(store, mime: 'image/gif', body: markup);
      expect(res.statusCode, 400);
      expect(store.get(MediaKind.image, 'ROOM', 'gifabc'), isNull);
      expect(store.totalBytes, 0);
    });

    test('a body too short to verify any signature is refused', () async {
      final res = await post(_store(_Clock()), body: [71, 73, 70, 56, 57]);
      expect(res.statusCode, 400);
      final res2 = await post(_store(_Clock()), body: [0x89, 0x50, 0x4e, 0x47]);
      expect(res2.statusCode, 400);
      final res3 = await post(_store(_Clock()), body: [1, 2, 3]);
      expect(res3.statusCode, 400);
    });

    test('real WebP and GIF bodies are accepted', () async {
      // WebP: RIFF ???? WEBP — the four label bytes then four free ones.
      final webp = Uint8List.fromList(
        [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50],
      );
      final store = _store(_Clock());
      expect((await post(store, mime: 'image/webp', body: webp)).statusCode,
          200);

      final gif87a = Uint8List.fromList([71, 73, 70, 56, 55, 97]);
      expect((await post(store, id: 'gifabd', body: gif87a)).statusCode, 200);
    });

    test('an underlabelled because label-less picture still gets in', () async {
      // The keyboard contract sends a label-less IME picture as
      // image/gif whatever format it actually is; the body need only be
      // *some* verified inert raster, so gif-labelled png bytes pass —
      // no real insertion flow is lost to the gate.
      final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
      final store = _store(_Clock());
      final res = await post(store, mime: 'image/gif', body: png);
      expect(res.statusCode, 200);
      expect(store.get(MediaKind.image, 'ROOM', 'gifabc'), isNotNull);
    });

    test('a body past the image cap is a 413 mid-stream', () async {
      final res = await post(
        _store(_Clock()),
        body: Uint8List(6 * 1024 * 1024 + 1),
      );
      expect(res.statusCode, 413);
    });

    test('GET on the upload path is 405', () async {
      final res = await _upload(
        'image',
        shelf.Request(
          'GET',
          Uri.parse('http://s/media/image?room=ROOM&id=gifabc'),
        ),
        store: _store(_Clock()),
      );
      expect(res.statusCode, 405);
    });
  });

  group('mediaNoteServe', () {
    test('a stored voice note is served back with its mime and no-store', () async {
      final store = _store(_Clock());
      store.put(
        kind: MediaKind.voice,
        code: 'ROOM',
        id: 'abcdefgh',
        data: Uint8List.fromList([4, 5]),
        mime: 'audio/mp4',
        durMs: 900,
      );
      final res = mediaNoteServe(
        shelf.Request('GET', Uri.parse('http://s/media/voice/ROOM/abcdefgh')),
        store: store,
      );
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'audio/mp4');
      expect(res.headers['cache-control'], 'no-store');
      expect(res.headers['accept-ranges'], 'none');
      // Inert-serve hardening (CWE-79) rides on both kinds: a document
      // load of this URL gets a sandboxed opaque origin and no sniffing.
      expect(res.headers['content-security-policy'], 'sandbox');
      expect(res.headers['x-content-type-options'], 'nosniff');
      final bytes = await res.read().fold<List<int>>(
        [],
        (acc, chunk) => acc..addAll(chunk),
      );
      expect(bytes, [4, 5]);
    });

    test('an image note serves by its own path-family', () async {
      final store = _store(_Clock());
      store.put(
        kind: MediaKind.image,
        code: 'ROOM',
        id: 'gifabc',
        data: Uint8List.fromList([7, 7, 7]),
        mime: 'image/gif',
      );
      final res = mediaNoteServe(
        shelf.Request('GET', Uri.parse('http://s/media/image/ROOM/gifabc')),
        store: store,
      );
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'image/gif');
      expect(res.headers['cache-control'], 'no-store');
      expect(res.headers['content-security-policy'], 'sandbox');
      expect(res.headers['x-content-type-options'], 'nosniff');
    });

    test('a pre-gate svg-labelled note serves inert anyway', () async {
      // Bytes stored before the upload gate existed (or seeded directly)
      // must not regain script authority at serve time: the stored label
      // stays the truth of the response, and the sandbox + nosniff pair
      // is what keeps a document load from executing it on our origin.
      final store = _store(_Clock());
      store.put(
        kind: MediaKind.image,
        code: 'ROOM',
        id: 'gifabc',
        data: Uint8List.fromList(utf8.encode('<svg><script>alert(1)</script>')),
        mime: 'image/svg+xml',
      );
      final res = mediaNoteServe(
        shelf.Request('GET', Uri.parse('http://s/media/image/ROOM/gifabc')),
        store: store,
      );
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'image/svg+xml');
      expect(res.headers['content-security-policy'], 'sandbox');
      expect(res.headers['x-content-type-options'], 'nosniff');
    });

    test('HEAD answers like GET, without the body', () async {
      final store = _store(_Clock());
      store.put(
        kind: MediaKind.image,
        code: 'ROOM',
        id: 'gifabc',
        data: Uint8List.fromList([7]),
        mime: 'image/gif',
      );
      final res = mediaNoteServe(
        shelf.Request('HEAD', Uri.parse('http://s/media/image/ROOM/gifabc')),
        store: store,
      );
      // The body travels (shelf_io strips it for HEAD at the socket) —
      // status and headers are the contract here.
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'image/gif');
    });

    test('an unknown note, unknown kind, or path shape is a 404', () {
      expect(
        mediaNoteServe(
          shelf.Request('GET', Uri.parse('http://s/media/voice/ROOM/nnnnnn')),
          store: _store(_Clock()),
        ).statusCode,
        404,
      );
      expect(
        mediaNoteServe(
          shelf.Request('GET', Uri.parse('http://s/media/jpg/ROOM/abcdef')),
          store: _store(_Clock()),
        ).statusCode,
        404,
        reason: 'only the two real kinds are addressable',
      );
      expect(
        mediaNoteServe(
          shelf.Request('GET', Uri.parse('http://s/media/voice/nospace')),
          store: _store(_Clock()),
        ).statusCode,
        404,
      );
    });

    test('writing to a serve path is 405', () {
      expect(
        mediaNoteServe(
          shelf.Request(
            'POST',
            Uri.parse('http://s/media/image/ROOM/gifabc'),
          ),
          store: _store(_Clock()),
        ).statusCode,
        405,
      );
    });
  });
}
