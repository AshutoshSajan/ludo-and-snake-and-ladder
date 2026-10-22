/// The inviter handoff once read `roomCode` immediately after `connect()`.
/// `connect()` only opens the socket; the code arrives with the server's
/// `joined` message a moment later. The handoff therefore saw null and
/// closed the lobby before the room existed — and the friend never got an
/// invite. These pin the wait that makes the handoff wait for `joined`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/online_client.dart';
import 'fake_channel.dart';

OnlineClient _client(FakeChannelFactory factory) => OnlineClient(
  'ws://test/ws',
  seatId: 'p1',
  name: 'A',
  channelFactory: factory.create,
);

void main() {
  test('awaitRoomCode resolves when joined arrives after connect', () async {
    final factory = FakeChannelFactory();
    final client = _client(factory);
    await client.connect();

    // Exactly the production ordering: the socket is open, the hello is sent,
    // and the server has not answered yet.
    expect(client.roomCode, isNull);
    final wait = client.awaitRoomCode(timeout: const Duration(seconds: 2));

    factory.last.serverAdd({
      'type': 'joined',
      'code': 'ABCD',
      'color': 'red',
      'game': 'ludo',
    });

    expect(await wait, 'ABCD');
    expect(client.roomCode, 'ABCD');
  });

  test('awaitRoomCode answers immediately once the room is known', () async {
    final factory = FakeChannelFactory();
    final client = _client(factory);
    await client.connect();
    factory.last.serverAdd({
      'type': 'joined',
      'code': 'WXYZ',
      'color': 'red',
      'game': 'ludo',
    });
    // Let the stream listener deliver the join.
    await Future<void>.delayed(Duration.zero);

    expect(await client.awaitRoomCode(timeout: const Duration(seconds: 1)),
        'WXYZ');
  });

  test('awaitRoomCode gives up rather than hanging the lobby forever',
      () async {
    final factory = FakeChannelFactory();
    final client = _client(factory);
    await client.connect();

    final code = await client.awaitRoomCode(
      timeout: const Duration(milliseconds: 20),
    );
    expect(code, isNull);
  });
}
