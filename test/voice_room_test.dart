/// Tests for [VoiceRoom] — the voice-chat state machine — driven through
/// the fake backend (test/voice_fakes.dart) so the WebRTC plugin never
/// loads: enable/deny, offerer election, answering, ICE relay, mute, seat
/// churn, hangups, teardown.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/voice_room.dart';

import 'voice_fakes.dart';

typedef WireFrame = ({String k, String to, String s});

void main() {
  late FakeBackend backend;
  late List<WireFrame> wire;
  late VoiceRoom room;

  setUp(() {
    backend = FakeBackend();
    wire = [];
    room = VoiceRoom(
      backend: backend,
      sendSignal: (k, to, s) => wire.add((k: k, to: to, s: s)),
    );
  });

  test(
    'enabling offers to the elected peer when seats are already known',
    () async {
      // Ticket: id 'a' seats first, so for the pair (a, b) it must offer.
      room.updateSeats({'a', 'b'}, 'a');
      final ok = await room.enable();

      expect(ok, isTrue);
      expect(room.enabled, isTrue);
      expect(backend.mic, isNotNull);
      // Exactly one offer gone out, addressed to the higher-seated peer.
      final offers = wire.where((f) => f.k == 'offer');
      expect(offers, hasLength(1));
      expect(offers.single.to, 'b');
      expect(offers.single.s, serializedOfferBid);
    },
  );

  test('a losing seat asks its elected offerer to re-arm the pair', () async {
    room.updateSeats({'a', 'b'}, 'b');
    final ok = await room.enable();

    expect(ok, isTrue);
    expect(
      wire.where((f) => f.k == 'offer'),
      isEmpty,
      reason: "'a' offers; 'b' never takes the offerer's chair",
    );
    expect(
      wire.where((f) => f.k == 'reinvite').map((f) => f.to),
      {'a'},
      reason:
          'the first offer — if any is even out — died while this seat '
          'was still passive; only an explicit invite re-arms the winner',
    );
  });

  test('an incoming offer is answered back over the wire', () async {
    room.updateSeats({'a', 'b'}, 'b');
    await room.enable();

    await room.onSignal((k: 'offer', from: 'a', s: 'REMOTE-OFFER'));
    // The answer travels addressed to 'a' — this side's own SDP, exactly
    // what the fake peer emits from inside the accepted offer.
    final answers = wire.where((f) => f.k == 'answer');
    expect(answers, hasLength(1));
    expect(answers.single.to, 'a');
    expect(answers.single.s, serializedOfferBid);
  });

  test('ICE is pure transit, both directions', () async {
    room.updateSeats({'a', 'b'}, 'a');
    await room.enable();

    // Outgoing ICE, produced by our own peer.
    backend.livePeers.first.onSignal('ice', 'CANDIDATE-1');
    expect(wire.last.k, 'ice');
    expect(wire.last.to, 'b');

    // Incoming ICE from the other seat.
    await room.onSignal((k: 'ice', from: 'b', s: 'CANDIDATE-2'));
    expect(backend.livePeers.first.received.single, (
      k: 'ice',
      s: 'CANDIDATE-2',
    ));
  });

  test('mute is local and silent on the wire', () async {
    room.updateSeats({}, 'a');
    await room.enable();

    room.setMuted(true);
    expect(backend.mic!.muted, isTrue);
    expect(room.muted, isTrue);
    expect(wire, isEmpty, reason: 'muting toggles the track, not the SDP');
  });

  test('seat churn builds and drops the mesh, never the wrong seats', () async {
    room.updateSeats({'a', 'b'}, 'a');
    await room.enable();
    final peerB = backend.livePeers.single;
    wire.clear(); // the initial offer to 'b' is irrelevant here

    // 'b' leaves, 'c' and 'd' take the empty and fresh seat.
    room.updateSeats({'a', 'c', 'd'}, 'a');
    expect(peerB.closed, isTrue, reason: 'a departed seat loses its peer');
    expect(room.peers, {'c', 'd'});
    // Election for new seats: 'a' offers to 'c' and to 'd'.
    expect(wire.where((f) => f.k == 'offer').map((f) => f.to), {
      'c',
      'd',
    }, reason: "my seat sorts first, so I offer to every newcomer");

    // Rejoining the gone seat (a dropped player reclaims their seat) is
    // just another newcomer.
    room.updateSeats({'a', 'b', 'c', 'd'}, 'a');
    expect(room.peers, {'b', 'c', 'd'});
  });

  test('disable sends hangups to connected seats and frees the mic', () async {
    room.updateSeats({'a', 'b'}, 'a');
    await room.enable();
    wire.clear();

    await room.disable();
    expect(room.enabled, isFalse);
    expect(backend.mic!.stopped, isTrue);
    expect(room.peers, isEmpty);
    expect(wire.where((f) => f.k == 'hangup').map((f) => f.to), {
      'b',
    }, reason: 'a farewell walks to peers, not to cancelled mic state');
  });

  test('a denied mic keeps voice off and does not leave a half mesh', () async {
    room.updateSeats({'a', 'b'}, 'a');
    backend.denyMic = true;
    final ok = await room.enable();

    expect(ok, isFalse);
    expect(room.enabled, isFalse);
    expect(wire, isEmpty, reason: 'no mic, no offer');
  });

  test('an offer from a seat the roster missed still connects', () async {
    // Voice already on before the lobby feed catches up: the relayed
    // offer finds no peer and must not be dropped on the floor.
    room.updateSeats({}, 'a');
    await room.enable();

    await room.onSignal((k: 'offer', from: 'late', s: 'REMOTE-OFFER'));
    expect(room.peers, contains('late'));
    expect(wire.any((f) => f.k == 'answer' && f.to == 'late'), isTrue);
  });

  test('signals with junk kinds are refused', () async {
    room.updateSeats({'a'}, 'a');
    await room.enable();
    final before = backend.peers.length;

    await room.onSignal((k: 'attack', from: 'a', s: 'x'));
    expect(
      backend.peers.length,
      before,
      reason: 'a bogus kind must not conjure a peer',
    );
    expect(wire, isEmpty);
  });

  test('abandoned() closes without goodbyes', () async {
    room.updateSeats({'a', 'b'}, 'a');
    await room.enable();
    final peer = backend.livePeers.single;

    await room.abandoned();
    expect(peer.closed, isTrue);
    expect(
      wire.where((f) => f.k == 'hangup'),
      isEmpty,
      reason: 'the room is gone; nobody is left to receive a hangup',
    );
  });

  test(
    'removeSeat revokes exactly the named seat, silently',
    () async {
      room.updateSeats({'a', 'b', 'c'}, 'a');
      await room.enable();
      final peerB = backend.livePeers
          .singleWhere((p) => p.peerId == 'b')
        ..simulateSpeaking(true);
      expect(room.speaking, {'b'});

      wire.clear();
      room.removeSeat('b');
      expect(peerB.closed, isTrue, reason: 'the departed seat loses its peer');
      expect(
        wire,
        isEmpty,
        reason: 'the departure ended its socket; nobody to say goodbye to',
      );
      expect(room.peers, {'c'}, reason: 'the surviving seats stay mounted');
      expect(
        room.speaking,
        isEmpty,
        reason: 'the departed seat leaves the speaking chips with its peer',
      );

      // Revoking an unknown or already-closed seat is inert — no crash,
      // no change notification churn.
      expect(room.peers, {'c'});
      room.removeSeat('nobody');
      expect(room.peers, {'c'});
    },
  );

  test(
    'every peer mounts its audio under its own seat and frees it there',
    () async {
      // The old code attached every remote stream under one shared 'pc'
      // key: two seats overwrote the same player, teardown (keyed by seat)
      // never matched, and the leaver's audio element leaked. One player
      // per seat, keyed and freed by seat, is the whole lifecycle.
      room.updateSeats({'b', 'c'}, 'a');
      await room.enable();
      await room.onSignal((k: 'offer', from: 'b', s: 'x'));
      await room.onSignal((k: 'offer', from: 'c', s: 'x'));
      expect(
        backend.audioAttached,
        unorderedEquals(['b', 'c']),
        reason: 'one player per seat — never a shared slot',
      );

      room.updateSeats({'a'}, 'a');
      expect(
        backend.peers.every((p) => p.closed),
        isTrue,
        reason: 'both sessions tore down with their seats',
      );
    },
  );

  test(
    'a mid-call joiner is addressed by its own seat, not a stale key',
    () async {
      // Fast signalling vs. slow lobby feeds: the offer creates the peer
      // itself, and that self-created peer must carry the sender's seat as
      // its playback key too.
      room.updateSeats({'a'}, 'a');
      await room.enable();

      await room.onSignal((k: 'offer', from: 'late', s: 'x'));
      expect(backend.livePeers.single.peerId, 'late');
    },
  );

  test(
    'staggered joins still converge: the missed offer is re-armed',
    () async {
      // Two real rooms, the exact shape of two tabs joining voice at
      // different times, wired through a relay that reproduces the client's
      // drop rule (a session not yet enabled buries every incoming frame —
      // onSignal's `!enabled` guard IS that filter).
      final wireA = <WireFrame>[];
      final wireB = <WireFrame>[];
      final backendA = FakeBackend();
      final backendB = FakeBackend();
      final a = VoiceRoom(
        backend: backendA,
        sendSignal: (k, to, s) => wireA.add((k: k, to: to, s: s)),
      );
      final b = VoiceRoom(
        backend: backendB,
        sendSignal: (k, to, s) => wireB.add((k: k, to: to, s: s)),
      );
      // Drain each side's wire into the other room until the protocol has
      // no more to say. Bounded far beyond any round-trip this protocol
      // needs (reinvite → offer → answer is three hops each way).
      Future<void> drain() async {
        for (var hop = 0; hop < 7; hop++) {
          // Snapshot then empty the SOURCE — `List.of(x)..clear()` would
          // cascade onto the copy and lose the frames down the drain.
          final outA = List.of(wireA);
          final outB = List.of(wireB);
          wireA.clear();
          wireB.clear();
          for (final f in outA) {
            await b.onSignal((k: f.k, from: 'a', s: f.s));
          }
          for (final f in outB) {
            await a.onSignal((k: f.k, from: 'b', s: f.s));
          }
        }
      }

      a.updateSeats({'a', 'b'}, 'a');
      b.updateSeats({'a', 'b'}, 'b');

      // 'a' joins first and offers into the void: 'b' is not enabled yet,
      // and the offer dies in the not-enabled filter. This is the step the
      // old mesh never recovered from.
      await a.enable();
      await drain();
      expect(
        wireB.where((f) => f.k == 'answer'),
        isEmpty,
        reason: "b never answered — 'a's first offer was buried",
      );
      expect(
        backendA.livePeers.single.established,
        isFalse,
        reason: "a's session died unanswered",
      );

      // 'b' joins second. Its enable must ask 'a' to re-arm the pair, and
      // the re-armed session must actually close a handshake.
      await b.enable();
      expect(wireB.where((f) => f.k == 'reinvite').map((f) => f.to), {'a'});
      await drain();

      expect(
        backendA.livePeers.single.established,
        isTrue,
        reason: "a's rebuilt session answered and reached the connected pair",
      );
      expect(
        backendB.livePeers.single.established,
        isTrue,
        reason: "b's session accepted the fresh offer",
      );
    },
  );

  test('a live session refuses a reinvite', () async {
    // Established pair: a reinvite (a late joiner re-enabling, say) must
    // not churn a working call.
    room.updateSeats({'a', 'b'}, 'a');
    await room.enable(); // offers to 'b'
    await room.onSignal((k: 'answer', from: 'b', s: 'x'));
    final livePeer = backend.livePeers.single;
    expect(
      livePeer.established,
      isTrue,
      reason: 'an answered offer has completed the handshake',
    );

    await room.onSignal((k: 'reinvite', from: 'b', s: '{}'));
    expect(
      backend.livePeers.single,
      same(livePeer),
      reason: 'a live call is left exactly as it stands',
    );
    expect(
      livePeer.closed,
      isFalse,
      reason: 'nobody tears down a session the reinvite was asked to spare',
    );
  });

  test('a reinvite is taken up only by the elected offerer', () async {
    // Same seat pair, both rooms' perspectives. The offerer rebuilds and
    // re-offers; the election loser neither rebuilds nor answers, since
    // the winner got the same request and owns the restart.
    room.updateSeats({'a', 'b'}, 'a');
    await room.enable();
    final stale = backend.livePeers.single;

    await room.onSignal((k: 'reinvite', from: 'b', s: '{}'));
    expect(
      stale.closed,
      isTrue,
      reason: 'the loser session is torn down for a fresh one',
    );
    expect(
      backend.livePeers.single.peerId,
      'b',
      reason: 'a fresh session is bought and offered immediately',
    );
    final offers = wire.where((f) => f.k == 'offer').map((f) => f.to);
    expect(
      offers,
      contains('b'),
      reason: 'the re-armed session offers at once',
    );

    // The loser's point of view: nothing to do, nothing emitted.
    final wireLoser = <WireFrame>[];
    final loser = VoiceRoom(
      backend: FakeBackend(),
      sendSignal: (k, to, s) => wireLoser.add((k: k, to: to, s: s)),
    );
    loser.updateSeats({'a', 'b'}, 'b');
    await loser.enable();
    wireLoser.clear();
    await loser.onSignal((k: 'reinvite', from: 'a', s: '{}'));
    expect(
      wireLoser.where((f) => f.k == 'offer' || f.k == 'answer'),
      isEmpty,
      reason: 'the loser waits; the winner restarts the pair',
    );
  });

  test(
    'speaking rides the probes: self on the mic, peers on their audio',
    () async {
      room.updateSeats({'a', 'b'}, 'a');
      await room.enable();
      expect(room.speaking, isEmpty);

      backend.mic!.simulate(true);
      expect(room.speaking, {'a'}, reason: 'the local seat reports itself');
      backend.mic!.simulate(false);
      expect(room.speaking, isEmpty);

      backend.livePeers.single.simulateSpeaking(true);
      expect(room.speaking, {
        'b',
      }, reason: 'a remote seat rings up through its own probe');
      backend.livePeers.single.simulateSpeaking(false);
      expect(room.speaking, isEmpty, reason: 'quiet is the default state');
    },
  );

  test('tearing the room down clears a lit speaking set', () async {
    room.updateSeats({'a', 'b'}, 'a');
    await room.enable();
    backend.mic!.simulate(true);
    backend.livePeers.single.simulateSpeaking(true);
    expect(room.speaking, isNotEmpty);

    await room.disable();
    expect(room.speaking, isEmpty, reason: 'no session, no lit chips');
  });
}
