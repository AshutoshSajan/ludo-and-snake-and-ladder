/// The server's friends pulse must reach the app's friends hook without
/// turning the socket into a second friends-state parser.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/services/online_client.dart';

void main() {
  test('a friendPulse frame invokes the app-level pulse hook', () {
    final client = OnlineClient('ws://test/ws', seatId: 'me', name: 'Me');
    var pulses = 0;
    client.onFriendsPulse = () => pulses++;

    client.debugHandleMessage('{"type":"friendPulse"}');

    expect(pulses, 1);
  });
}
