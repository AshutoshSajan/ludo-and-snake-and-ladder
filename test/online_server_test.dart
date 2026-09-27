/// Tests for the online multiplayer stack:
///
/// 1. `LudoState` JSON roundtrip — the wire format for server snapshots
/// 2. `GameAuthority` — authoritative validation: room lifecycle, seating,
///    turn enforcement, illegal-intent rejection, chat, and a full
///    deterministic scripted game to completion
/// 3. Loopback integration — two real WebSocket clients playing through
///    the actual transport in `bin/server.dart`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/engine/ludo/ludo_rules.dart';
import 'package:game_club/server/game_server.dart';
import 'package:game_club/server/leaderboard_store.dart';
import 'package:game_club/server/room_registry.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:web_socket_channel/web_socket_channel.dart';

// Reuses the real transport (WebSocket handler + protocol) from the
// server entrypoint so the integration test exercises production code.
import '../bin/server.dart'
    show
        wsHandler,
        leaderboardHandler,
        leaderboardStore,
        authority,
        statsHandler,
        roomLookupHandler,
        healthHandler,
        registryRefreshInterval,
        roomRegistry,
        instanceId,
        serverEnv,
        webDir;

ServerMember _member(LudoColor c,
        {String? seatId, String? id, void Function(String)? on}) =>
    ServerMember(
      id: id ?? seatId ?? c.name,
      seatId: seatId ?? c.name,
      name: c.label,
      color: c,
      sink: on ?? (_) {},
    );

/// Cluster-registry stub that refuses the first claim — as if another
/// replica already owns that code — then behaves like a normal CAS map.
/// Zone-local [HttpOverrides] that restores real HTTP clients: it inherits
/// the base implementation, whose `createHttpClient` constructs the actual
/// [HttpClient] — unlike the test binding's global mock, which stubs every
/// client with empty 400 responses.
class _RealHttpOverrides extends HttpOverrides {}

class _RefusingOnceRegistry implements RoomRegistry {
  String? refusedCode;
  final _owners = <String, String>{};
  final _tokens = <String, String?>{};

  @override
  Future<bool> register(String code, String instanceId,
      {String? owner}) async {
    if (refusedCode == null) {
      refusedCode = code;
      return false;
    }
    _owners[code] = instanceId;
    _tokens[code] = owner;
    return true;
  }

  @override
  Future<String?> lookup(String code) async => _owners[code];

  @override
  Future<void> unregister(String code, {String? owner}) async {
    // Mirror the real registries: a stale close never drops a newer room.
    if (owner != null && _tokens[code] != owner) return;
    _owners.remove(code);
    _tokens.remove(code);
  }
}

/// Cluster-registry stub that refuses every claim — as if another replica
/// keeps winning the race for each code this instance generates.
class _RefusingAlwaysRegistry implements RoomRegistry {
  final attempted = <String>[];

  @override
  Future<bool> register(String code, String instanceId,
      {String? owner}) async {
    attempted.add(code);
    return false;
  }

  @override
  Future<String?> lookup(String code) async => 'game-other';

  @override
  Future<void> unregister(String code, {String? owner}) async {}
}

/// Cluster-registry stub whose claims take [delay] to answer — a stand-in
/// for a remote Turso round-trip during which the connecting socket may
/// die. Delegates to a real in-memory registry after the wait.
class _SlowClaimRegistry implements RoomRegistry {
  _SlowClaimRegistry(this.delay);
  final Duration delay;
  final _inner = InMemoryRoomRegistry();
  final unregistered = <String>[];

  @override
  Future<bool> register(String code, String instanceId,
      {String? owner}) async {
    await Future<void>.delayed(delay);
    return _inner.register(code, instanceId, owner: owner);
  }

  @override
  Future<String?> lookup(String code) => _inner.lookup(code);

  @override
  Future<void> unregister(String code, {String? owner}) async {
    unregistered.add(code);
    await _inner.unregister(code, owner: owner);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ------------------------------------------------------------ wire format

  group('LudoState JSON roundtrip', () {
    test('preserves every field the client needs', () {
      final s = createLudoState([
        LudoPlayer(id: 'p1', name: 'Ana', color: LudoColor.red),
        LudoPlayer(id: 'p2', name: 'Bo', color: LudoColor.blue),
      ]);
      rollDice(s, 6);
      applyMove(s, 0); // red spawns onto its start cell
      final restored = LudoState.fromJson(s.toJson());

      expect(restored.players.length, 2);
      expect(restored.players[0].id, 'p1');
      expect(restored.players[0].name, 'Ana');
      expect(restored.players[0].color, LudoColor.red);
      expect(restored.players[1].color, LudoColor.blue);
      expect(restored.tokens.length, 8);
      // Red's first token spawned; its position must survive the wire.
      expect(
        restored.tokens
            .firstWhere((t) => t.color == LudoColor.red && t.index == 0)
            .pos,
        s.tokens
            .firstWhere((t) => t.color == LudoColor.red && t.index == 0)
            .pos,
      );
      expect(restored.currentPlayerIndex, s.currentPlayerIndex);
      expect(restored.phase, s.phase);
      expect(restored.lastRoll, s.lastRoll);
      expect(restored.rollSeq, s.rollSeq);
      expect(restored.turnCount, s.turnCount);
      expect(restored.lastEvent, s.lastEvent);
    });

    test('from a fresh state: defaults survive', () {
      final s = createLudoState([
        LudoPlayer(id: 'p1', name: 'A', color: LudoColor.red),
        LudoPlayer(id: 'p2', name: 'B', color: LudoColor.yellow),
      ]);
      final r = LudoState.fromJson(s.toJson());
      expect(r.rankings, isEmpty);
      expect(r.lastRoll, isNull);
      expect(r.phase, LudoPhase.awaitingRoll);
      expect(r.consecutiveSixes, 0);
      expect(r.extraRoll, isFalse);
    });
  });

  // ------------------------------------------------------- game authority

  group('GameAuthority: room lifecycle', () {
    test('host is seated in the first clockwise corner (red)', () {
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.green));
      expect(room.members.values.single.color, LudoColor.red,
          reason: 'seat color is assigned by the authority, not the client');
      expect(room.code.length, 4);
    });

    test('createRoom accepts a pre-claimed code and registry token', () {
      // The server reserves a code cluster-wide BEFORE creating the room;
      // the room must adopt that exact code and token.
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red),
          code: 'ZZ99', registryToken: 'room-pre-claimed');
      expect(room.code, 'ZZ99');
      expect(room.registryToken, 'room-pre-claimed');
      expect(auth.rooms['ZZ99'], same(room));
    });

    test('createRoom refuses an explicit code that already lives locally', () {
      final auth = GameAuthority(rng: Random(1));
      final first = auth.createRoom(_member(LudoColor.red), code: 'DUPE');
      expect(() => auth.createRoom(_member(LudoColor.blue), code: 'DUPE'),
          throwsStateError);
      expect(auth.rooms['DUPE'], same(first),
          reason: 'the racing creation must never overwrite the original');
    });

    test('joinWithColor honors a free preferred corner', () {
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red));
      auth.joinWithColor(
          room.code, _member(LudoColor.yellow, seatId: 'y'), LudoColor.yellow);
      expect(room.ownerOf(LudoColor.yellow)!.seatId, 'y');
    });

    test('joinWithColor falls back to the first free corner when taken', () {
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red));
      auth.joinWithColor(
          room.code, _member(LudoColor.green, seatId: 'g'), LudoColor.red);
      // Clockwise order is red -> blue -> yellow -> green, so the first
      // free corner after red is blue.
      expect(room.ownerOf(LudoColor.blue), isNotNull);
      expect(room.ownerOf(LudoColor.red)!.seatId, 'red',
          reason: 'the host keeps red; a latecomer cannot steal it');
    });

    test('duplicate seat id is rejected', () {
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red));
      expect(auth.joinRoom(room.code, _member(LudoColor.blue)), isNotNull);
      expect(
        auth.joinRoom(room.code, _member(LudoColor.yellow, seatId: 'blue')),
        isNull,
      );
    });

    test('room caps at four members', () {
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red));
      for (final c in [LudoColor.blue, LudoColor.yellow, LudoColor.green]) {
        auth.joinRoom(room.code, _member(c));
      }
      expect(room.full, isTrue);
      expect(
        auth.joinRoom(room.code, _member(LudoColor.red, seatId: 'fifth')),
        isNull,
      );
    });

    test('an emptied lobby closes and unregisters immediately', () async {
      final registry = InMemoryRoomRegistry();
      final closed = <String>[];
      final auth = GameAuthority(rng: Random(1), onRoomClosed: (code, token) {
        closed.add(code);
        registry.unregister(code, owner: token);
      });
      final room = auth.createRoom(_member(LudoColor.red));
      await registry.register(room.code, 'game-1', owner: room.registryToken);

      auth.leaveRoom(room.code, 'red');

      expect(room.removed, isTrue);
      expect(auth.rooms, isEmpty);
      expect(closed, [room.code],
          reason: 'the registry hook must fire at once, not on a later sweep');
      expect(await registry.lookup(room.code), isNull,
          reason: 'a stale route would send joins to a dead room');
    });

    test('an abandoned started room unregisters after the grace period',
        () async {
      final registry = InMemoryRoomRegistry();
      final closed = <String>[];
      final auth = GameAuthority(
          rng: Random(1),
          emptyRoomGrace: const Duration(milliseconds: 20),
          onRoomClosed: (code, token) {
            closed.add(code);
            registry.unregister(code, owner: token);
          });
      final room = auth.createRoom(_member(LudoColor.red));
      auth.joinRoom(room.code, _member(LudoColor.blue));
      await registry.register(room.code, 'game-1', owner: room.registryToken);
      auth.handleIntent(
          room: room, connectionId: 'red', msg: {'type': 'start'});

      // Everyone drops; a started room lingers for the grace period first.
      auth.leaveRoom(room.code, 'red');
      auth.leaveRoom(room.code, 'blue');
      expect(room.removed, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(room.removed, isTrue);
      expect(auth.rooms, isEmpty);
      expect(closed, [room.code]);
      expect(await registry.lookup(room.code), isNull);
    });

    test('a late close delete never erases a newer room on the same code',
        () async {
      final registry = InMemoryRoomRegistry();
      final auth = GameAuthority(rng: Random(1));
      final old = auth.createRoom(_member(LudoColor.red));
      await registry.register(old.code, 'game-1', owner: old.registryToken);

      // The old room closes: its scoped delete frees the code (in the Turso
      // registry the row could equally have expired and been GC'd).
      await registry.unregister(old.code, owner: old.registryToken);
      expect(await registry.lookup(old.code), isNull);

      // A newer room recycles the code and claims the live route ...
      final newer = auth.createRoom(_member(LudoColor.blue, seatId: 'blue2'));
      await registry.register(old.code, 'game-1', owner: newer.registryToken);
      expect(await registry.lookup(old.code), 'game-1');

      // ... and only now does a late (or retried) delete from the old close
      // land — the slow Turso pipeline. It is scoped to the closed room's
      // token, so the live route survives.
      await registry.unregister(old.code, owner: old.registryToken);
      expect(await registry.lookup(old.code), 'game-1',
          reason: 'the stale delete must not erase the newer room');

      // A competing claim while the newer row is live is refused outright:
      // the two creations must never both believe they own the code, or the
      // loser's cleanup would delete the winner's live route.
      expect(
        await registry.register(old.code, 'game-1',
            owner: '${newer.registryToken}-other'),
        isFalse,
      );
      expect(await registry.lookup(old.code), 'game-1');
    });

    test('a started room rejects new joiners', () {
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red));
      auth.joinRoom(room.code, _member(LudoColor.blue));
      auth.handleIntent(
          room: room, connectionId: 'red', msg: {'type': 'start'});
      expect(auth.joinRoom(room.code, _member(LudoColor.yellow)), isNull);
    });

    test('only the first seated member may start the game', () {
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red));
      auth.joinRoom(room.code, _member(LudoColor.blue));
      auth.handleIntent(
          room: room, connectionId: 'blue', msg: {'type': 'start'});
      expect(room.started, isFalse,
          reason: 'blue is not the host — start is ignored');
      auth.handleIntent(
          room: room, connectionId: 'red', msg: {'type': 'start'});
      expect(room.started, isTrue);
    });

    test('the last member leaving dissolves the room', () {
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red));
      auth.leaveRoom(room.code, 'red');
      expect(room.removed, isTrue);
      expect(auth.rooms.containsKey(room.code), isFalse);
    });
  });

  // ---------------------------------------------------- gameplay authority

  group('GameAuthority: gameplay', () {
    // Two seated members with recording sinks.
    (Room, GameAuthority, List<String>, List<String>) playRoom() {
      final hostLog = <String>[];
      final guestLog = <String>[];
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(
          _member(LudoColor.red, on: hostLog.add));
      auth.joinRoom(room.code, _member(LudoColor.blue, on: guestLog.add));
      auth.handleIntent(
          room: room, connectionId: 'red', msg: {'type': 'start'});
      return (room, auth, hostLog, guestLog);
    }

    test('roll by the wrong seat is ignored', () {
      final (room, auth, host, guest) = playRoom();
      // start already broadcast once — record the baseline.
      final hostBase = host.length, guestBase = guest.length;
      final before = room.state.rollSeq;
      auth.handleIntent(
          room: room, connectionId: 'blue', msg: {'type': 'roll'});
      expect(room.state.rollSeq, before,
          reason: 'blue is not the current player — no dice');
      expect(host.length, hostBase, reason: 'no broadcast for a wrong seat');
      expect(guest.length, guestBase);
    });

    test('roll by the current seat advances the game and broadcasts', () {
      final (room, auth, host, guest) = playRoom();
      final hostBase = host.length, guestBase = guest.length;
      auth.handleIntent(
          room: room, connectionId: 'red', msg: {'type': 'roll'});
      expect(room.state.rollSeq, 1);
      expect(host.length, hostBase + 1);
      expect(guest.length, guestBase + 1);
      // A non-six with everyone in base is a skip: the engine clears
      // lastRoll. Either a dice value or a skip is authoritative.
      expect(room.state.lastRoll, anyOf(isNull, inInclusiveRange(1, 6)));
    });

    test('move from base without a six is rejected as illegal', () {
      final (room, auth, _, _) = playRoom();
      auth.handleIntent(
          room: room, connectionId: 'red', msg: {'type': 'roll'});
      // Server dice is seeded, not fixed — force the illegal scenario.
      room.state
        ..lastRoll = 3
        ..phase = LudoPhase.awaitingMove;
      auth.handleIntent(
          room: room, connectionId: 'red', msg: {'type': 'move', 'token': 0});
      expect(room.state.tokens[0].pos, -1,
          reason: 'a base token cannot move on a 3');
    });

    test('legal move (spawn on six) is applied and broadcast', () {
      final (room, auth, host, guest) = playRoom();
      room.state
        ..lastRoll = 6
        ..phase = LudoPhase.awaitingMove;
      auth.handleIntent(
          room: room, connectionId: 'red', msg: {'type': 'move', 'token': 2});
      expect(room.state.tokens[2].pos, 0,
          reason: 'token must spawn on its own start cell');
      expect(host.last, contains('"type":"state"'));
      expect(guest.last, contains('"type":"state"'));
    });

    test('move by the wrong seat or a bad token index is ignored', () {
      final (room, auth, _, _) = playRoom();
      room.state
        ..lastRoll = 6
        ..phase = LudoPhase.awaitingMove;
      final before = room.state.tokens[0].pos;
      auth.handleIntent(
          room: room, connectionId: 'blue', msg: {'type': 'move', 'token': 0});
      expect(room.state.tokens[0].pos, before);
      auth.handleIntent(
          room: room, connectionId: 'red', msg: {'type': 'move', 'token': 9});
      expect(room.state.tokens[0].pos, before);
    });

    test('chat is relayed to every member with the sender name', () {
      final (room, auth, host, guest) = playRoom();
      auth.handleIntent(
          room: room,
          connectionId: 'red',
          msg: {'type': 'chat', 'text': '  hello  '});
      for (final log in [host, guest]) {
        final msg =
            jsonDecode(log.last) as Map<String, dynamic>;
        expect(msg['type'], 'chat');
        expect(msg['from'], 'Red');
        expect(msg['text'], 'hello');
      }
    });
  });

  // ------------------------------------------- loopback integration (real WS)

  group('loopback WebSocket integration (production wsHandler)', () {
    late HttpServer srv;
    late WebSocketChannel host;
    late WebSocketChannel guest;
    final hostBuf = <Map<String, dynamic>>[];
    final guestBuf = <Map<String, dynamic>>[];

    /// Waits up to 10s for a message of [type] in [buf]. Consumes every
    /// buffered message up to and including the match, so successive
    /// calls always advance to *new* messages.
    Future<Map<String, dynamic>> nextMsg(
        List<Map<String, dynamic>> buf, String type) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        for (var i = 0; i < buf.length; i++) {
          if (buf[i]['type'] == type) {
            final m = buf[i];
            buf.removeRange(0, i + 1);
            return m;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      fail('expected a "$type" message, got: $buf');
    }

    setUp(() async {
      hostBuf.clear();
      guestBuf.clear();
      final handler = const shelf.Pipeline().addHandler((req) {
        if (req.url.path == 'ws') return wsHandler()(req);
        if (req.url.path == 'stats') return statsHandler(req);
        return shelf.Response.ok('ok');
      });
      srv = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
      final url = 'ws://127.0.0.1:${srv.port}/ws';
      host = WebSocketChannel.connect(Uri.parse(url));
      guest = WebSocketChannel.connect(Uri.parse(url));
      await host.ready;
      await guest.ready;
      host.stream.listen(
          (d) => hostBuf.add(jsonDecode(d as String) as Map<String, dynamic>));
      guest.stream.listen((d) =>
          guestBuf.add(jsonDecode(d as String) as Map<String, dynamic>));
    });

    tearDown(() async {
      await host.sink.close();
      await guest.sink.close();
      await srv.close(force: true);
    });

    test('quick match auto-pairs two strangers and auto-starts', () async {
      // Both players ask the server to match them — nobody shares a code.
      host.sink.add(jsonEncode(
          {'type': 'hello', 'seatId': 'qm-1', 'name': 'Solo', 'match': true}));
      final hj = await nextMsg(hostBuf, 'joined');
      expect(hj['game'], 'ludo');

      guest.sink.add(jsonEncode(
          {'type': 'hello', 'seatId': 'qm-2', 'name': 'Rival', 'match': true}));
      final gj = await nextMsg(guestBuf, 'joined');
      expect(gj['code'], hj['code'], reason: 'matched into the same room');

      // The server started the game itself — no 'start' intent was sent.
      final hs = await nextMsg(hostBuf, 'state');
      await nextMsg(guestBuf, 'state');
      expect((hs['state'] as Map)['players'], hasLength(2));
    });

    test('a code owned by another replica is never handed out', () async {
      final stubborn = _RefusingOnceRegistry();
      final saved = roomRegistry;
      roomRegistry = stubborn;
      addTearDown(() => roomRegistry = saved);

      host.sink.add(
          jsonEncode({'type': 'hello', 'seatId': 'dup-1', 'name': 'Dup'}));
      final joined = await nextMsg(hostBuf, 'joined');
      final code = joined['code'] as String;

      // The first generated code was claimed by another replica — the
      // player must land in a freshly claimed room, never the stolen one.
      expect(code, isNot(stubborn.refusedCode));
      expect(authority.rooms[code], isNotNull);
      expect(authority.rooms[stubborn.refusedCode], isNull,
          reason: 'the duplicate code was never turned into a room');
    });

    test('a registry that refuses every code fails the hello cleanly',
        () async {
      final refusing = _RefusingAlwaysRegistry();
      final saved = roomRegistry;
      roomRegistry = refusing;
      addTearDown(() => roomRegistry = saved);
      final before = authority.rooms.keys.toSet();

      host.sink.add(
          jsonEncode({'type': 'hello', 'seatId': 'ex-1', 'name': 'Ex'}));
      final err = await nextMsg(hostBuf, 'error');
      expect(err['text'], contains('could not create a room'));
      expect(refusing.attempted, hasLength(3),
          reason: 'three codes are tried, then the creation gives up');
      expect(authority.rooms.keys.toSet().difference(before), isEmpty,
          reason: 'no room may exist under an unclaimed code');
    });

    test('quick match fails cleanly when every generated code is refused',
        () async {
      final refusing = _RefusingAlwaysRegistry();
      final saved = roomRegistry;
      roomRegistry = refusing;
      addTearDown(() => roomRegistry = saved);
      final before = authority.rooms.keys.toSet();

      host.sink.add(jsonEncode(
          {'type': 'hello', 'seatId': 'ex-2', 'name': 'Ex', 'match': true}));
      final err = await nextMsg(hostBuf, 'error');
      expect(err['text'], contains('could not open a room'));
      expect(authority.rooms.keys.toSet().difference(before), isEmpty,
          reason: 'a quick-matcher must never be seated in an '
              'unroutable room');
    });

    test('a created room only becomes visible after its claim succeeds',
        () async {
      final slow = _SlowClaimRegistry(const Duration(milliseconds: 200));
      final saved = roomRegistry;
      roomRegistry = slow;
      addTearDown(() => roomRegistry = saved);
      final before = authority.rooms.keys.toSet();

      host.sink.add(
          jsonEncode({'type': 'hello', 'seatId': 'vis-1', 'name': 'Vis'}));
      // Mid-claim: nobody can join, match, or watch a room whose code is
      // not claimed yet — a refused claim must never strand a joiner in a
      // room the server would then drop.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(authority.rooms.keys.toSet().difference(before), isEmpty,
          reason: 'a room awaiting its claim is not visible to anyone yet');
      final joined = await nextMsg(hostBuf, 'joined');
      expect(authority.rooms[joined['code']], isNotNull,
          reason: 'once the claim lands the room opens normally');
    });

    test('a disconnect during the claim leaves no phantom room or stale route',
        () async {
      final slow = _SlowClaimRegistry(const Duration(milliseconds: 250));
      final saved = roomRegistry;
      roomRegistry = slow;
      addTearDown(() => roomRegistry = saved);
      // The production onRoomClosed wiring lives in main(); mirror it here
      // so the test can observe the room's row being released on close.
      final savedAuthority = authority;
      authority = GameAuthority(onRoomClosed: (code, token) {
        roomRegistry.unregister(code, owner: token).catchError((Object _) {});
      });
      addTearDown(() => authority = savedAuthority);
      final before = authority.rooms.keys.toSet();

      final dying = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${srv.port}/ws'));
      await dying.ready;
      dying.sink.add(jsonEncode(
          {'type': 'hello', 'seatId': 'ghost', 'name': 'Ghost'}));
      // Hang up while the remote claim is still in flight.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await dying.sink.close();
      // Let the claim answer, the cleanup notice the dead socket, and the
      // room close its registry row.
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(authority.rooms.keys.toSet().difference(before), isEmpty,
          reason: 'no phantom occupied room may survive the dead host');
      expect(slow.unregistered, isNotEmpty,
          reason: 'the freshly claimed code must be released again');
    });

    test('/stats counts live WebSockets and drops them after close',
        () async {
      // The test binding stubs every HTTP client with empty 400 responses
      // via a global HttpOverrides; a zone-local no-op override opts back
      // into real networking (the base createHttpClient builds the real
      // HttpClient) without touching the global mock.
      Future<int?> connections() =>
          HttpOverrides.runWithHttpOverrides<Future<int>>(
            () async {
              final resp = await http
                  .get(Uri.parse('http://127.0.0.1:${srv.port}/stats'));
              return jsonDecode(resp.body)['connections'] as int;
            },
            _RealHttpOverrides(),
          );

      // The setUp sockets (and any leftovers from a previous test) are the
      // baseline — the gauge must react to deltas, not absolute values.
      final before = (await connections())!;

      // A raw socket counts before it even says hello: the gauge is the
      // capacity metric, not the lobby roster.
      final socket = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${srv.port}/ws'));
      addTearDown(socket.sink.close);
      await socket.ready;
      expect(await connections(), before + 1);

      // ...and it must drop again once the socket is gone.
      await socket.sink.close();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      var after = await connections();
      while (after != before && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        after = await connections();
      }
      expect(after, before,
          reason: 'closing the socket must decrement the gauge');
    });

    test('hello -> joined -> lobby -> start -> state, full protocol', () async {
      // Host creates a room; guest joins by code.
      host.sink.add(jsonEncode(
          {'type': 'hello', 'seatId': 'host-1', 'name': 'Host'}));
      final joined = await nextMsg(hostBuf, 'joined');
      final code = joined['code'] as String;
      expect(code, hasLength(4));
      expect(joined['color'], 'red');

      guest.sink.add(jsonEncode({
        'type': 'hello',
        'seatId': 'guest-1',
        'name': 'Guest',
        'code': code,
      }));
      expect((await nextMsg(guestBuf, 'joined'))['color'], 'blue');

      // Both receive the lobby roster.
      final lobby = await nextMsg(guestBuf, 'lobby');
      expect((lobby['seats'] as List).map((s) => s['name']),
          containsAll(const ['Host', 'Guest']));

      // Host starts the game; both receive the first authoritative state.
      host.sink.add(jsonEncode({'type': 'start'}));
      final state = await nextMsg(hostBuf, 'state');
      expect((state['state'] as Map)['players'], hasLength(2));
      await nextMsg(guestBuf, 'state');
    });

    test('a rolled dice reaches both clients as an authoritative state',
        () async {
      host.sink.add(
          jsonEncode({'type': 'hello', 'seatId': 'h2', 'name': 'H'}));
      final code = (await nextMsg(hostBuf, 'joined'))['code'] as String;
      guest.sink.add(
          jsonEncode({'type': 'hello', 'seatId': 'g2', 'name': 'G', 'code': code}));
      await nextMsg(guestBuf, 'joined');
      host.sink.add(jsonEncode({'type': 'start'}));
      final first = await nextMsg(hostBuf, 'state');
      final seqBefore = first['state']['rollSeq'];

      host.sink.add(jsonEncode({'type': 'roll'}));
      final second = await nextMsg(hostBuf, 'state');
      expect(second['state']['rollSeq'], seqBefore + 1);
      // null lastRoll == a skip turn (everyone in base, no six) — still
      // an authoritative state both clients must receive.
      expect(second['state']['lastRoll'],
          anyOf(isNull, inInclusiveRange(1, 6)));
      final guestView = await nextMsg(guestBuf, 'state');
      expect(guestView['state']['lastRoll'], second['state']['lastRoll'],
          reason: 'every client sees the same authoritative dice');
    });

    test('a spectator watches a running game without a seat', () async {
      host.sink.add(
          jsonEncode({'type': 'hello', 'seatId': 'h3', 'name': 'H'}));
      final code = (await nextMsg(hostBuf, 'joined'))['code'] as String;
      guest.sink.add(
          jsonEncode({'type': 'hello', 'seatId': 'g3', 'name': 'G', 'code': code}));
      await nextMsg(guestBuf, 'joined');
      host.sink.add(jsonEncode({'type': 'start'}));
      await nextMsg(hostBuf, 'state');

      // The watcher connects mid-game.
      final watcher = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${srv.port}/ws'));
      await watcher.ready;
      final buf = <Map<String, dynamic>>[];
      watcher.stream
          .listen((d) => buf.add(jsonDecode(d as String) as Map<String, dynamic>));
      watcher.sink.add(jsonEncode({
        'type': 'hello',
        'seatId': 'watcher-1',
        'name': 'Watcher',
        'code': code,
        'spectate': true,
      }));

      final wJoined = await nextMsg(buf, 'joined');
      expect(wJoined['spectator'], isTrue);
      expect(wJoined.containsKey('color'), isFalse,
          reason: 'spectators claim no corner');
      final snapshot = await nextMsg(buf, 'state');
      expect((snapshot['state'] as Map)['players'], hasLength(2));

      // The watcher's intents are dead letters, but real play reaches them.
      watcher.sink.add(jsonEncode({'type': 'roll'}));
      host.sink.add(jsonEncode({'type': 'roll'}));
      final after = await nextMsg(buf, 'state');
      expect(after['state']['rollSeq'],
          (snapshot['state'] as Map)['rollSeq'] + 1);
      // The watcher's own lobby roster names them.
      final roster = await nextMsg(buf, 'lobby');
      expect(roster['spectators'], contains('Watcher'));

      await watcher.sink.close();
    });

    test('joining a bogus room code yields an error message', () async {
      final stranger = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${srv.port}/ws'));
      await stranger.ready;
      final buf = <Map<String, dynamic>>[];
      stranger.stream
          .listen((d) => buf.add(jsonDecode(d as String) as Map<String, dynamic>));
      stranger.sink.add(jsonEncode({
        'type': 'hello',
        'seatId': 'x',
        'name': 'X',
        'code': 'ZZZZ',
      }));
      expect((await nextMsg(buf, 'error'))['text'], contains('ZZZZ'));
      await stranger.sink.close();
    });

    test('malformed JSON gets an error, socket stays usable', () async {
      host.sink.add('not json at all');
      expect((await nextMsg(hostBuf, 'error'))['text'], 'bad json');
      // The connection must still accept a valid hello afterwards.
      host.sink.add(
          jsonEncode({'type': 'hello', 'seatId': 'h', 'name': 'H'}));
      expect(await nextMsg(hostBuf, 'joined'), isNotNull);
    });

    test('dropped player rejoins mid-game and resumes the game', () async {
      host.sink.add(
          jsonEncode({'type': 'hello', 'seatId': 'h', 'name': 'H'}));
      final code =
          (await nextMsg(hostBuf, 'joined'))['code'] as String;
      guest.sink.add(jsonEncode(
          {'type': 'hello', 'seatId': 'g', 'name': 'G', 'code': code}));
      await nextMsg(guestBuf, 'joined');
      host.sink.add(jsonEncode({'type': 'start'}));
      final before =
          (await nextMsg(hostBuf, 'state'))['state'] as Map<String, dynamic>;
      expect(before['phase'], 'awaitingRoll');

      // The guest's connection dies mid-game.
      await guest.sink.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Same profile comes back on a fresh socket.
      final guest2 = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${srv.port}/ws'));
      await guest2.ready;
      final guest2Buf = <Map<String, dynamic>>[];
      guest2.stream.listen((d) => guest2Buf
          .add(jsonDecode(d as String) as Map<String, dynamic>));
      guest2.sink.add(jsonEncode(
          {'type': 'hello', 'seatId': 'g', 'name': 'G', 'code': code}));
      await nextMsg(guest2Buf, 'joined');
      // The rejoining client immediately receives the current snapshot.
      final resumed = (await nextMsg(guest2Buf, 'state'))['state']
          as Map<String, dynamic>;
      expect(resumed['rollSeq'], before['rollSeq']);
      expect(resumed['currentPlayerIndex'], before['currentPlayerIndex']);

      // And the reconnected seat is live in the broadcast path again.
      host.sink.add(jsonEncode({'type': 'roll'}));
      final after = (await nextMsg(guest2Buf, 'state'))['state']
          as Map<String, dynamic>;
      expect(after['rollSeq'], 1);
      await guest2.sink.close();
    });
  });

  // -------------------------------------------------- reconnect (authority)

  group('GameAuthority: reconnect', () {
    test('rejoinRoom reclaims the original corner mid-game', () {
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red));
      auth.joinRoom(room.code, _member(LudoColor.blue));
      auth.handleIntent(
          room: room, connectionId: 'red', msg: {'type': 'start'});
      expect(room.started, isTrue);

      // red drops; blue remains.
      auth.leaveRoom(room.code, 'red');
      expect(room.members, hasLength(1));

      // red returns on a new connection and gets the same corner back.
      final sinkJson = <String>[];
      final rejoining =
          _member(LudoColor.green, seatId: 'red', id: 'c9', on: sinkJson.add);
      final rejoined = auth.rejoinRoom(room.code, rejoining);
      expect(rejoined, same(room));
      expect(rejoining.color, LudoColor.red,
          reason: 'the returning player reclaims their original seat');
      expect(room.members, hasLength(2));

      // The authority's turn check matches on seatId, so the returned
      // member can act as their old self again.
      auth.handleIntent(room: room, connectionId: 'c9', msg: {'type': 'roll'});
      expect(sinkJson, isNotEmpty,
          reason: 'the reconnected member receives state broadcasts');
      expect(room.stateOrNull!.rollSeq, 1);
    });

    test('rejoinRoom rejects a seatId that never sat in the room', () {
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red));
      expect(
        auth.rejoinRoom(room.code, _member(LudoColor.blue)),
        isNull,
        reason: 'reconnect must not become seat stealing',
      );
      expect(room.members, hasLength(1));
    });

    test('rejoinRoom evicts a stale half-open connection for the seat', () {
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red));
      // Simulate a half-open socket the server never saw close.
      room.members['ghost'] = _member(LudoColor.red, id: 'ghost');
      final fresh = _member(LudoColor.red, id: 'c1');
      expect(auth.rejoinRoom(room.code, fresh), same(room));
      expect(room.members.keys, ['c1']);
    });

    test('a started empty room survives the grace period, then is dropped',
        () async {
      final auth = GameAuthority(
          rng: Random(1), emptyRoomGrace: const Duration(milliseconds: 40));
      final room = auth.createRoom(_member(LudoColor.red));
      auth.joinRoom(room.code, _member(LudoColor.blue));
      auth.handleIntent(
          room: room, connectionId: 'red', msg: {'type': 'start'});
      auth.leaveRoom(room.code, 'red');
      auth.leaveRoom(room.code, 'blue');
      expect(auth.rooms.containsKey(room.code), isTrue,
          reason: 'the game stays recoverable for a moment');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(auth.rooms.containsKey(room.code), isFalse);
      expect(room.removed, isTrue);
    });

    test('an emptied lobby room is removed immediately', () {
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red));
      auth.leaveRoom(room.code, 'red');
      expect(auth.rooms.containsKey(room.code), isFalse);
      expect(room.removed, isTrue);
    });

    test('rejoining cancels the abandon timer', () async {
      final auth = GameAuthority(
          rng: Random(1), emptyRoomGrace: const Duration(milliseconds: 40));
      final room = auth.createRoom(_member(LudoColor.red));
      auth.joinRoom(room.code, _member(LudoColor.blue));
      auth.handleIntent(
          room: room, connectionId: 'red', msg: {'type': 'start'});
      auth.leaveRoom(room.code, 'red');
      auth.leaveRoom(room.code, 'blue');
      auth.rejoinRoom(
          room.code, _member(LudoColor.red, seatId: 'red', id: 'c1'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(auth.rooms.containsKey(room.code), isTrue,
          reason: 'a returning player keeps the room alive');
    });
  });

  // ---------------------------------------------------------- spectating

  group('GameAuthority: spectators', () {
    test('a watcher receives broadcasts but cannot act', () {
      final seen = <String>[];
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red));
      auth.joinRoom(room.code, _member(LudoColor.blue));
      final watcher =
          auth.spectateRoom(room.code, _member(LudoColor.green, seatId: 'w',
              id: 'w1', on: seen.add));
      expect(watcher, isNotNull);
      expect(room.spectators, hasLength(1));

      room.broadcast({'type': 'lobby', 'code': room.code});
      expect(seen, hasLength(1),
          reason: 'spectators are on the broadcast feed');

      // The watcher cannot start or roll — handleIntent only looks at
      // seated members.
      auth.handleIntent(
          room: room, connectionId: 'w1', msg: {'type': 'start'});
      auth.handleIntent(room: room, connectionId: 'w1', msg: {'type': 'roll'});
      expect(room.started, isFalse);
    });

    test('a seated player cannot spectate the same room', () {
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red));
      expect(
        auth.spectateRoom(room.code, _member(LudoColor.red, id: 'red-x')),
        isNull,
        reason: 'no duplicate feeds for someone already seated',
      );
    });

    test('a spectator leaving does not kill a started room', () {
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red));
      auth.joinRoom(room.code, _member(LudoColor.blue));
      auth.spectateRoom(room.code, _member(LudoColor.green, seatId: 'w'));
      auth.leaveRoom(room.code, 'w');
      expect(auth.rooms.containsKey(room.code), isTrue);
      auth.leaveRoom(room.code, 'red');
      expect(auth.rooms.containsKey(room.code), isTrue,
          reason: 'started games linger for the grace period');
    });
  });

  // ------------------------------------------------- leaderboard recording

  group('GameAuthority: leaderboard recording', () {
    test('a finished game is recorded once with correct ranks', () async {
      final store = SqliteLeaderboardStore.inMemory();
      final auth = GameAuthority(rng: Random(1), leaderboard: store);
      final room = auth.createRoom(_member(LudoColor.red));
      auth.joinRoom(room.code, _member(LudoColor.blue));
      auth.handleIntent(
          room: room, connectionId: 'red', msg: {'type': 'start'});

      final s = room.state;
      // Force the endgame: three of red's tokens home, the last one one
      // step short, a pending 1 for red. Red's move finishes red; with
      // 2 players the game then ends and blue is auto-ranked behind.
      for (final t in s.tokens) {
        t.pos = t.color == LudoColor.red && t.index == 0 ? 55 : 56;
      }
      s
        ..lastRoll = 1
        ..phase = LudoPhase.awaitingMove;
      auth.handleIntent(
          room: room, connectionId: 'red', msg: {'type': 'move', 'token': 0});

      expect(s.phase, LudoPhase.gameOver);
      expect(s.rankings, ['red', 'blue']);
      expect(await store.totalGames(), 1);

      final rows = await store.topPlayers();
      expect(rows.map((r) => r.name), ['Red', 'Blue']);
      expect(rows[0].wins, 1);
      expect(rows[0].games, 1);
      expect(rows[0].avgRank, 1.0);
      expect(rows[1].avgRank, 2.0);

      // Anything after game over is rejected, so no double recording.
      auth.handleIntent(room: room, connectionId: 'red', msg: {'type': 'roll'});
      expect(await store.totalGames(), 1);
      expect((await store.topPlayers()).first.games, 1);
    });

    test('without a store, completion stays a pure no-op', () {
      final auth = GameAuthority(rng: Random(1));
      final room = auth.createRoom(_member(LudoColor.red));
      auth.joinRoom(room.code, _member(LudoColor.blue));
      auth.handleIntent(
          room: room, connectionId: 'red', msg: {'type': 'start'});
      for (final t in room.state.tokens) {
        t.pos = t.color == LudoColor.red && t.index == 0 ? 55 : 56;
      }
      room.state
        ..lastRoll = 1
        ..phase = LudoPhase.awaitingMove;
      expect(
        () => auth.handleIntent(
            room: room, connectionId: 'red', msg: {'type': 'move', 'token': 0}),
        returnsNormally,
      );
      expect(room.state.phase, LudoPhase.gameOver);
    });
  });

  // ------------------------------------------------------------ matchmaking

  group('GameAuthority: matchmaking (quick match)', () {
    late GameAuthority auth;
    setUp(() {
      auth = GameAuthority(rng: Random(3), leaderboard: null);
    });

    test('pairs two quick-match players into one shared room', () {
      final a = auth.findMatch(_member(LudoColor.red));
      final b = auth.findMatch(_member(LudoColor.blue));
      expect(a.code, b.code, reason: 'both players belong in the same room');
      expect(a.members.length, 2);
      expect(a.started, isFalse);
      // Distinct seats even though both joined without a color preference.
      expect(a.ownerOf(a.members.values.first.color), isNotNull);
    });

    test('respects the requested game type', () {
      final ludo = auth.findMatch(_member(LudoColor.red), game: 'ludo');
      final snakes = auth.findMatch(_member(LudoColor.blue), game: 'snakes');
      expect(ludo.gameType, 'ludo');
      expect(snakes.gameType, 'snakes');
      expect(ludo.code, isNot(snakes.code),
          reason: 'a snakes player must never land in a ludo room');
      // A second snakes player pairs with the first snakes room.
      final s2 = auth.findMatch(_member(LudoColor.green), game: 'snakes');
      expect(s2.code, snakes.code);
    });

    test('fills a waiting room before opening a new one', () {
      final first = auth.findMatch(_member(LudoColor.red));
      auth.findMatch(_member(LudoColor.blue));
      auth.findMatch(_member(LudoColor.yellow));
      final fourth = auth.findMatch(_member(LudoColor.green));
      expect(fourth.code, first.code);
      expect(auth.rooms.values.where((r) => r.gameType == 'ludo').length, 1);
    });

    test('never matches into a started, full, or already-joined room', () {
      final room = auth.findMatch(_member(LudoColor.red));
      auth.findMatch(_member(LudoColor.blue));
      auth.findMatch(_member(LudoColor.yellow));
      auth.findMatch(_member(LudoColor.green));
      room.start(); // full room started — must be invisible to matchmaking
      final lateJoiner = auth.findMatch(
          _member(LudoColor.red, seatId: 'late'));
      expect(lateJoiner.code, isNot(room.code));
      expect(lateJoiner.members.length, 1);
    });
  });

  // --------------------------------------------------- leaderboard over HTTP

  group('GET /leaderboard (production handler)', () {
    test('serves recorded games as JSON and rejects non-GET', () async {
      // Swap the module globals for a clean, seeded pair.
      final store = SqliteLeaderboardStore.inMemory();
      leaderboardStore = store;
      authority = GameAuthority(rng: Random(1), leaderboard: store);
      await store.recordResults(gameId: 'g1', results: [
        GameResult(seatId: 'w', name: 'Winnie', color: 'red', rank: 1),
        GameResult(seatId: 'l', name: 'Louie', color: 'blue', rank: 2),
      ]);

      final resp = await leaderboardHandler(shelf.Request(
          'GET', Uri.parse('http://localhost/leaderboard')));
      expect(resp.statusCode, 200);
      final body =
          jsonDecode(await resp.readAsString()) as Map<String, dynamic>;
      expect(body['ok'], isTrue);
      expect(body['games'], 1);
      final players = body['players'] as List;
      expect(players, hasLength(2));
      expect(players.first['name'], 'Winnie');
      expect(players.first['wins'], 1);
      expect(players.first['avgRank'], 1.0);

      final post = await leaderboardHandler(shelf.Request(
          'POST', Uri.parse('http://localhost/leaderboard')));
      expect(post.statusCode, 405);
    });
  });

  // ------------------------------------------------- scaling endpoints

  group('GET /stats and /rooms/lookup (production handlers)', () {
    test('stats reports instance, connections, rooms, and spectators',
        () async {
      // Fresh authority with one room: two seated players + a spectator.
      final auth = GameAuthority(rng: Random(1));
      authority = auth;
      final room = auth.createRoom(_member(LudoColor.red));
      auth.joinRoom(room.code, _member(LudoColor.blue));
      auth.spectateRoom(room.code, _member(LudoColor.green, seatId: 'spec'));

      final resp = await statsHandler(
          shelf.Request('GET', Uri.parse('http://localhost/stats')));
      expect(resp.statusCode, 200);
      final body =
          jsonDecode(await resp.readAsString()) as Map<String, dynamic>;
      expect(body['ok'], isTrue);
      expect(body['instance'], instanceId);
      expect(body['rooms'], 1);
      expect(body['spectators'], 1);
      // Connections counts only live WebSockets in this process; a direct
      // handler call has none, and the joined-room map is not double-counted.
      expect(body['connections'], isA<int>());
    });

    test('rooms/lookup resolves a code registered by this instance',
        () async {
      final registry = InMemoryRoomRegistry();
      roomRegistry = registry;
      await registry.register('ABCD', 'game-2');

      final resp = await roomLookupHandler(shelf.Request(
          'GET', Uri.parse('http://localhost/rooms/lookup?code=ABCD')));
      expect(resp.statusCode, 200);
      final body =
          jsonDecode(await resp.readAsString()) as Map<String, dynamic>;
      expect(body, {'ok': true, 'code': 'ABCD', 'instance': 'game-2'});
    });

    test('rooms/lookup normalizes lowercase codes like joins do', () async {
      // Joins uppercase the code (rooms[code.toUpperCase()]) while the
      // registry stores the canonical uppercase room code, so an edge
      // asking about the user-typed lowercase form must resolve too.
      final registry = InMemoryRoomRegistry();
      roomRegistry = registry;
      await registry.register('AB12', 'game-3');

      final resp = await roomLookupHandler(shelf.Request(
          'GET', Uri.parse('http://localhost/rooms/lookup?code=ab12')));
      expect(resp.statusCode, 200);
      final body =
          jsonDecode(await resp.readAsString()) as Map<String, dynamic>;
      expect(body, {'ok': true, 'code': 'AB12', 'instance': 'game-3'});
    });

    test('rooms/lookup 404s unknown codes and 400s missing ones', () async {
      roomRegistry = InMemoryRoomRegistry();

      final missing = await roomLookupHandler(shelf.Request('GET',
          Uri.parse('http://localhost/rooms/lookup?code=ZZZZ')));
      expect(missing.statusCode, 404);

      final noCode = await roomLookupHandler(
          shelf.Request('GET', Uri.parse('http://localhost/rooms/lookup')));
      expect(noCode.statusCode, 400);

      final post = await roomLookupHandler(shelf.Request('POST',
          Uri.parse('http://localhost/rooms/lookup?code=ABCD')));
      expect(post.statusCode, 405);
    });
  });

  group('registry refresh cadence', () {
    test('stays well under the configured TTL', () {
      // Default (null -> 120 s TTL) keeps the historical 30 s sweep.
      expect(registryRefreshInterval(null), const Duration(seconds: 30));
      expect(registryRefreshInterval(const Duration(seconds: 120)),
          const Duration(seconds: 30));
      // A short TTL shortens the sweep; a fixed 30 s cadence with a 10 s
      // TTL left live rooms expiring (lookup 404) for ~20 s per cycle.
      expect(registryRefreshInterval(const Duration(seconds: 10)),
          const Duration(seconds: 3));
      expect(registryRefreshInterval(const Duration(seconds: 45)),
          const Duration(seconds: 15));
      // Degenerate TTLs still yield a valid, positive timer period.
      expect(registryRefreshInterval(const Duration(seconds: 1)),
          const Duration(seconds: 1));
      expect(registryRefreshInterval(Duration.zero),
          const Duration(seconds: 1));
    });
  });

  group('GET /health (production handler)', () {
    test('health returns the documented JSON payload', () async {
      final resp = await healthHandler(
          shelf.Request('GET', Uri.parse('http://localhost/health')));
      expect(resp.statusCode, 200);
      final body =
          jsonDecode(await resp.readAsString()) as Map<String, dynamic>;
      expect(body['ok'], isTrue);
      expect(body['rooms'], isA<int>());
      expect(body['games'], isA<int>());
    });
  });

  group('WEB_DIR resolution (web UI serving)', () {
    test('WEB_DIR set only via .env-style config is honored', () async {
      // Deployments may configure the web build location in .env, not the
      // process environment; the server must serve the UI in both cases.
      final tmp = await Directory.systemTemp.createTemp('game-club-web');
      File('${tmp.path}/index.html')
          .writeAsStringSync('<html>game ui</html>');
      final prev = serverEnv;
      serverEnv = {'WEB_DIR': tmp.path};
      addTearDown(() {
        serverEnv = prev;
        tmp.deleteSync(recursive: true);
      });

      expect(webDir, tmp.path);
    });

    test('a WEB_DIR without index.html is ignored', () async {
      final tmp = await Directory.systemTemp.createTemp('game-club-empty');
      final prev = serverEnv;
      serverEnv = {'WEB_DIR': tmp.path};
      addTearDown(() {
        serverEnv = prev;
        tmp.deleteSync(recursive: true);
      });

      expect(webDir, isNull);
    });
  });
}
