/// Unit tests for [OnlineClient] auto-reconnect: an unplanned socket drop
/// switches the client to `reconnecting`, retries hello with exponential
/// backoff, and restores the room on success — while a definitive server
/// rejection ('error') stops the retry loop.
///
/// Uses fake WebSocket channels (the client's `channelFactory` hook) inside
/// [fakeAsync] so the backoff timers run instantly and deterministically.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/engine/ludo/ludo_rules.dart'
    show createLudoState;
import 'package:game_club/services/online_client.dart';
import 'fake_channel.dart';
import 'voice_fakes.dart';

/// A minimal valid started game snapshot, as the real server would send.
Map<String, dynamic> _startedState() => createLudoState([
      LudoPlayer(id: 'p1', name: 'A', color: LudoColor.red),
      LudoPlayer(id: 'p2', name: 'B', color: LudoColor.blue),
    ]).toJson();

void main() {
  test('a lowercase-typed code is canonicalized in the hashed ?code= URL',
      () {
    fakeAsync((async) {
      final factory = FakeChannelFactory();
      final client = OnlineClient('ws://test/ws',
          seatId: 'p1', name: 'A', channelFactory: factory.create);

      client.connect(code: ' ab2c ');
      async.flushMicrotasks();

      // The load balancer hashes ?code= against the room's canonical
      // uppercase spelling — the URL must never carry a lowercase copy.
      expect(factory.uris.single.queryParameters['code'], 'AB2C');
      // hello carries the same canonical code (the server stores rooms
      // under code.toUpperCase()).
      expect(factory.last.sent.first['code'], 'AB2C');
    });
  });

  test('a dropped socket triggers reconnect and restores the room', () {
    fakeAsync((async) {
      final factory = FakeChannelFactory();
      final client = OnlineClient('ws://test/ws',
          seatId: 'p2', name: 'B', channelFactory: factory.create);

      client.connect(code: 'CODE');
      async.flushMicrotasks();
      expect(client.status, OnlineStatus.connecting);

      // Server seats us (flush: broadcast delivery is a microtask).
      factory.last
          .serverAdd({'type': 'joined', 'code': 'CODE', 'color': 'blue'});
      async.flushMicrotasks();
      expect(client.status, OnlineStatus.inLobby);
      expect(client.roomCode, 'CODE');

      // Network blip.
      factory.last.dropConnection();
      async.flushMicrotasks();
      expect(client.status, OnlineStatus.reconnecting);

      // First retry after the 500 ms base delay: hello is re-sent with the
      // same identity and join code, without the caller doing anything.
      async.elapse(const Duration(milliseconds: 499));
      expect(factory.channels, hasLength(1));
      async.elapse(const Duration(milliseconds: 1));
      expect(factory.channels, hasLength(2));
      expect(factory.last.sent.first,
         {'type': 'hello', 'seatId': 'p2', 'name': 'B', 'game': 'ludo', 'code': 'CODE'});

      // Server answers: we are back in the same seat and even get the
      // running game snapshot.
      factory.last
          .serverAdd({'type': 'joined', 'code': 'CODE', 'color': 'blue'});
      async.flushMicrotasks();
      expect(client.status, OnlineStatus.inLobby);
      factory.last.serverAdd({'type': 'state', 'state': _startedState()});
      async.flushMicrotasks();
      expect(client.status, OnlineStatus.playing);
      expect(client.state, isNotNull);
      expect(client.started, isTrue);
    });
  });

  test('backoff doubles between failed attempts', () {
    fakeAsync((async) {
      final factory = FakeChannelFactory();
      final client = OnlineClient('ws://test/ws',
          seatId: 'p1', name: 'A', channelFactory: factory.create);

      client.connect();
      async.flushMicrotasks();
      // Reach 'joined' first. A close *before* the server ever seated us is a
      // refused connection, which spends the cold-start budget; the reconnect
      // path only owns a socket that was actually established. These tests are
      // about the reconnect backoff, so they have to set that precondition.
      factory.last.serverAdd({'type': 'joined', 'code': 'CODE', 'color': 'red'});
      async.flushMicrotasks();

      factory.last.dropConnection();
      async.elapse(const Duration(milliseconds: 500)); // attempt 1
      expect(factory.channels, hasLength(2));

      factory.last.dropConnection();
      async.elapse(const Duration(milliseconds: 999)); // not yet…
      expect(factory.channels, hasLength(2));
      async.elapse(const Duration(milliseconds: 1)); // attempt 2 at 1 s
      expect(factory.channels, hasLength(3));

      factory.last.dropConnection();
      async.elapse(const Duration(milliseconds: 1999)); // not yet…
      expect(factory.channels, hasLength(3));
      async.elapse(const Duration(milliseconds: 1)); // attempt 3 at 2 s
      expect(factory.channels, hasLength(4));
    });
  });

  test('the client gives up after five failed attempts', () {
    fakeAsync((async) {
      final factory = FakeChannelFactory();
      final client = OnlineClient('ws://test/ws',
          seatId: 'p1', name: 'A', channelFactory: factory.create);

      client.connect();
      async.flushMicrotasks();
      // As above: establish the socket before dropping it, so the drop is a
      // drop and not a refusal.
      factory.last.serverAdd({'type': 'joined', 'code': 'CODE', 'color': 'red'});
      async.flushMicrotasks();

      // Five retries each fail too (delays: 500+1000+2000+4000+8000 ms).
      for (var attempt = 0; attempt < 5; attempt++) {
        factory.last.dropConnection();
        async.elapse(Duration(milliseconds: 500 * (1 << attempt)));
      }
      expect(factory.channels, hasLength(6)); // initial + 5 retries
      // The last retry's failure lands in the terminal error state.
      factory.last.dropConnection();
      async.flushMicrotasks();
      expect(client.status, OnlineStatus.error);
      expect(client.errorText, contains('Connection lost'));

      // No further retries once we're in the error state.
      async.elapse(const Duration(seconds: 30));
      expect(factory.channels, hasLength(6));
    });
  });

  test('a definitive server rejection stops the retry loop', () {
    fakeAsync((async) {
      final factory = FakeChannelFactory();
      final client = OnlineClient('ws://test/ws',
          seatId: 'p1', name: 'A', channelFactory: factory.create);

      client.connect(code: 'GONE');
      async.flushMicrotasks();

      // Socket drops, retry fires, but the room is gone: the server sends
      // 'error' instead of 'joined'.
      factory.last.dropConnection();
      async.elapse(const Duration(milliseconds: 500));
      expect(factory.channels, hasLength(2));
      factory.last
          .serverAdd({'type': 'error', 'text': "room 'GONE' not found"});
      async.flushMicrotasks();
      expect(client.status, OnlineStatus.error);

      // The error must not itself trigger another reconnect cycle.
      async.elapse(const Duration(seconds: 20));
      expect(factory.channels, hasLength(2));
    });
  });

  test('disconnect() closes quietly without reconnecting', () {
    fakeAsync((async) {
      final factory = FakeChannelFactory();
      final client = OnlineClient('ws://test/ws',
          seatId: 'p1', name: 'A', channelFactory: factory.create);

      client.connect();
      async.flushMicrotasks();
      factory.last
          .serverAdd({'type': 'joined', 'code': 'CODE', 'color': 'red'});
      async.flushMicrotasks();
      expect(client.status, OnlineStatus.inLobby);

      // The user leaves: no reconnect attempt may follow.
      client.disconnect();
      async.flushMicrotasks();
      expect(client.status, OnlineStatus.idle);
      async.elapse(const Duration(seconds: 30));
      expect(factory.channels, hasLength(1));
    });
  });

  test('join-by-code and reconnect carry the code in the WS URL', () {
    fakeAsync((async) {
      final factory = FakeChannelFactory();
      final client = OnlineClient('ws://test/ws',
          seatId: 'p1', name: 'A', channelFactory: factory.create);

      // Joining an existing room: affinity from the very first connection —
      // the room-affinity LB hashes ?code= to the replica that owns the room.
      client.connect(code: 'ABCD');
      async.flushMicrotasks();
      expect(factory.uris.last.queryParameters['code'], 'ABCD');

      // Network blip: the retry must reach the same replica, so the URL
      // keeps carrying the code — not just the hello frame.
      factory.last.dropConnection();
      async.elapse(const Duration(milliseconds: 500));
      expect(factory.channels, hasLength(2));
      expect(factory.uris.last.queryParameters['code'], 'ABCD');
    });
  });

  test('reconnects after quick match carry the code learned from joined', () {
    fakeAsync((async) {
      final factory = FakeChannelFactory();
      final client = OnlineClient('ws://test/ws',
          seatId: 'p1',
          name: 'A',
          quickMatch: true,
          channelFactory: factory.create);

      // No code yet: we may land on any replica and create the match there.
      client.connect();
      async.flushMicrotasks();
      expect(factory.uris.last.queryParameters.containsKey('code'), isFalse);

      // Seated; the code is now known and every later open — in particular
      // reconnects — must target the owning replica.
      factory.last
          .serverAdd({'type': 'joined', 'code': 'QK1', 'color': 'red'});
      async.flushMicrotasks();

      factory.last.dropConnection();
      async.elapse(const Duration(milliseconds: 500));
      expect(factory.channels, hasLength(2));
      expect(factory.uris.last.queryParameters['code'], 'QK1');
    });
  });

  test('creating a room carries the requested table size in hello', () {
    fakeAsync((async) {
      final factory = FakeChannelFactory();
      final client = OnlineClient(
        'ws://test/ws',
        seatId: 'p1',
        name: 'A',
        capacity: 3,
        channelFactory: factory.create,
      );

      client.connect();
      async.flushMicrotasks();
      expect(factory.last.sent.first, {
        'type': 'hello',
        'seatId': 'p1',
        'name': 'A',
        'game': 'ludo',
        'players': 3,
      });
    });
  });

  test('a join sends no size, but adopts the room size from the lobby', () {
    fakeAsync((async) {
      final factory = FakeChannelFactory();
      final client = OnlineClient('ws://test/ws',
          seatId: 'p1', name: 'A', channelFactory: factory.create);

      client.connect(code: 'F0UR');
      async.flushMicrotasks();
      // The room already exists — its size is the host's to have chosen,
      // so our hello carries only the code.
      expect(factory.last.sent.first,
          {'type': 'hello', 'seatId': 'p1', 'name': 'A', 'game': 'ludo', 'code': 'F0UR'});

      // The room's real size arrives with the lobby feed and the UI reads
      // it from here.
      factory.last
          .serverAdd({'type': 'joined', 'code': 'F0UR', 'color': 'blue'});
      factory.last.serverAdd({
        'type': 'lobby',
        'code': 'F0UR',
        'started': false,
        'capacity': 2,
        'seats': [],
        'spectators': [],
      });
      async.flushMicrotasks();
      expect(client.capacity, 2);
    });
  });

  test('sending a GIF carries the url and caption in the chat intent', () {
    fakeAsync((async) {
      final factory = FakeChannelFactory();
      final client = OnlineClient('ws://test/ws',
          seatId: 'p1', name: 'A', channelFactory: factory.create);
      client.connect();
      async.flushMicrotasks();

      client.sendGif('https://media.tenor.com/x/abc.gif', caption: 'look');
      async.flushMicrotasks();
      expect(factory.last.sent.last, {
        'type': 'chat',
        'text': 'look',
        'gif': 'https://media.tenor.com/x/abc.gif',
      });
    });
  });

  test('an incoming chat GIF lands in the feed as a ChatLine', () {
    fakeAsync((async) {
      final factory = FakeChannelFactory();
      final client = OnlineClient('ws://test/ws',
          seatId: 'p1', name: 'A', channelFactory: factory.create);
      client.connect();
      async.flushMicrotasks();

      factory.last.serverAdd({
        'type': 'chat',
        'from': 'Bo',
        'gif': 'https://media.tenor.com/y/def.gif',
      });
      factory.last.serverAdd({
        'type': 'chat',
        'from': 'Ana',
        'text': 'nice',
        'gif': 'https://media.tenor.com/z/ghi.gif',
      });
      async.flushMicrotasks();

      final [gifOnly, captioned] = client.chat.toList();
      expect(gifOnly.from, 'Bo');
      expect(gifOnly.text, isEmpty);
      expect(gifOnly.gif, 'https://media.tenor.com/y/def.gif');
      expect(captioned.from, 'Ana');
      expect(captioned.text, 'nice');
      expect(captioned.gif, 'https://media.tenor.com/z/ghi.gif');
    });
  });

  group('table voice', () {
    test('joining offers the elected peer over the room socket', () {
      fakeAsync((async) {
        final factory = FakeChannelFactory();
        final backend = FakeBackend();
        final client = OnlineClient('ws://test/ws',
            seatId: 'p1',
            name: 'A',
            voiceBackend: backend,
            channelFactory: factory.create);
        client.connect();
        async.flushMicrotasks();

        // Seated: we hold 'p1', the table has 'p2' — so 'p1' sorts first
        // and owns the offer for the pair.
        factory.last.serverAdd({
          'type': 'joined',
          'code': 'CODE',
          'color': 'red',
        });
        factory.last.serverAdd({
          'type': 'lobby',
          'code': 'CODE',
          'started': false,
          'seats': [
            {'name': 'A', 'color': 'red', 'seatId': 'p1'},
            {'name': 'B', 'color': 'blue', 'seatId': 'p2'},
          ],
          'spectators': [],
        });
        async.flushMicrotasks();
        expect(client.joinVoice(), completion(isTrue));
        async.flushMicrotasks();

        expect(client.voiceJoined, isTrue);
        final frames = factory.last.sent
            .whereType<Map>()
            .where((m) => m['type'] == 'voice')
            .cast<Map<String, dynamic>>();
        expect(frames, isNotEmpty);
        expect(frames.single['to'], 'p2');
        expect(frames.single['k'], 'offer');
      });
    });

    test('relay loops back into the voice room', () {
      fakeAsync((async) {
        final factory = FakeChannelFactory();
        final backend = FakeBackend();
        final client = OnlineClient('ws://test/ws',
            seatId: 'p1',
            name: 'A',
            voiceBackend: backend,
            channelFactory: factory.create);
        client.connect();
        async.flushMicrotasks();
        factory.last.serverAdd({'type': 'joined', 'code': 'CODE', 'color': 'red'});
        factory.last.serverAdd({
          'type': 'lobby',
          'code': 'CODE',
          'started': false,
          'seats': [
            {'name': 'A', 'color': 'red', 'seatId': 'p1'},
            {'name': 'B', 'color': 'blue', 'seatId': 'p2'},
          ],
          'spectators': [],
        });
        async.flushMicrotasks();
        client.joinVoice();
        async.flushMicrotasks();

        // The answer and one trickle candidate, as they arrive from the
        // relay.
        factory.last.serverAdd({
          'type': 'voice',
          'k': 'answer',
          'from': 'p2',
          's': 'REMOTE-ANSWER',
        });
        factory.last.serverAdd({
          'type': 'voice',
          'k': 'ice',
          'from': 'p2',
          's': 'CAND-1',
        });
        async.flushMicrotasks();
        // enable()'s rebuild closes the pre-mic peer; pin the live one.
        final peer = backend.livePeers.single;
        expect(peer.received, [
          (k: 'answer', s: 'REMOTE-ANSWER'),
          (k: 'ice', s: 'CAND-1'),
        ]);
      });
    });

    test('leaving voice sends hangups and stops the mic', () {
      fakeAsync((async) {
        final factory = FakeChannelFactory();
        final backend = FakeBackend();
        final client = OnlineClient('ws://test/ws',
            seatId: 'p1',
            name: 'A',
            voiceBackend: backend,
            channelFactory: factory.create);
        client.connect();
        async.flushMicrotasks();
        factory.last.serverAdd({'type': 'joined', 'code': 'CODE', 'color': 'red'});
        factory.last.serverAdd({
          'type': 'lobby',
          'code': 'CODE',
          'started': false,
          'seats': [
            {'name': 'A', 'color': 'red', 'seatId': 'p1'},
            {'name': 'B', 'color': 'blue', 'seatId': 'p2'},
          ],
          'spectators': [],
        });
        async.flushMicrotasks();
        client.joinVoice();
        async.flushMicrotasks();
        expect(client.voiceJoined, isTrue);

        client.leaveVoice();
        async.flushMicrotasks();
        expect(client.voiceJoined, isFalse);
        expect(backend.mic!.stopped, isTrue);
        final hangup = factory.last.sent
            .whereType<Map>()
            .lastWhere((m) => m['type'] == 'voice');
        expect(hangup['k'], 'hangup');
        expect(hangup['to'], 'p2');
      });
    });

    test('muting toggles locally, sending nothing on the wire', () {
      fakeAsync((async) {
        final factory = FakeChannelFactory();
        final backend = FakeBackend();
        final client = OnlineClient('ws://test/ws',
            seatId: 'p1',
            name: 'A',
            voiceBackend: backend,
            channelFactory: factory.create);
        client.connect();
        async.flushMicrotasks();
        factory.last.serverAdd({'type': 'joined', 'code': 'CODE', 'color': 'red'});
        factory.last.serverAdd({
          'type': 'lobby',
          'code': 'CODE',
          'started': false,
          'seats': [
            {'name': 'A', 'color': 'red', 'seatId': 'p1'},
            {'name': 'B', 'color': 'blue', 'seatId': 'p2'},
          ],
          'spectators': [],
        });
        async.flushMicrotasks();
        client.joinVoice();
        async.flushMicrotasks();
        final voiceCount = factory.last.sent
            .whereType<Map>()
            .where((m) => m['type'] == 'voice')
            .length;

        client.setVoiceMuted(true);
        async.flushMicrotasks();
        expect(client.voiceMuted, isTrue);
        expect(backend.mic!.muted, isTrue);
        final now = factory.last.sent
            .whereType<Map>()
            .where((m) => m['type'] == 'voice')
            .length;
        expect(now, voiceCount);
      });
    });
  });
}