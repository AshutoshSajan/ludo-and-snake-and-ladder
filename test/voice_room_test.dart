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

  test('enabling offers to the elected peer when seats are already known', () async {
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
  });

  test('enabling sends nothing when this seat loses the election', () async {
    room.updateSeats({'a', 'b'}, 'b');
    final ok = await room.enable();

    expect(ok, isTrue);
    expect(wire.where((f) => f.k == 'offer'), isEmpty,
        reason: "'a' offers; 'b' waits for the offer");
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
    backend.peers.first.onSignal('ice', 'CANDIDATE-1');
    expect(wire.last.k, 'ice');
    expect(wire.last.to, 'b');

    // Incoming ICE from the other seat.
    await room.onSignal((k: 'ice', from: 'b', s: 'CANDIDATE-2'));
    expect(backend.peers.first.received.single,
        (k: 'ice', s: 'CANDIDATE-2'));
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
    final peerB = backend.peers.single;
    wire.clear(); // the initial offer to 'b' is irrelevant here

    // 'b' leaves, 'c' and 'd' take the empty and fresh seat.
    room.updateSeats({'a', 'c', 'd'}, 'a');
    expect(peerB.closed, isTrue, reason: 'a departed seat loses its peer');
    expect(room.peers, {'c', 'd'});
    // Election for new seats: 'a' offers to 'c' and to 'd'.
    expect(
      wire.where((f) => f.k == 'offer').map((f) => f.to),
      {'c', 'd'},
      reason: "my seat sorts first, so I offer to every newcomer",
    );

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
    expect(
      wire.where((f) => f.k == 'hangup').map((f) => f.to),
      {'b'},
      reason: 'a farewell walks to peers, not to cancelled mic state',
    );
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
    expect(backend.peers.length, before,
        reason: 'a bogus kind must not conjure a peer');
    expect(wire, isEmpty);
  });

  test('abandoned() closes without goodbyes', () async {
    room.updateSeats({'a', 'b'}, 'a');
    await room.enable();
    final peer = backend.peers.single;

    await room.abandoned();
    expect(peer.closed, isTrue);
    expect(
      wire.where((f) => f.k == 'hangup'),
      isEmpty,
      reason: 'the room is gone; nobody is left to receive a hangup',
    );
  });
}
