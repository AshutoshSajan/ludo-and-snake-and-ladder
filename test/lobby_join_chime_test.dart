/// The lobby's join chime: a player taking a seat is audible, without the
/// first roster chiming at the people already in the room.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/providers/app_providers.dart';
import 'package:game_club/screens/online_lobby_screen.dart';
import 'package:game_club/services/friend_signals.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/services/sound_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingSound extends SoundService {
  int joins = 0;

  @override
  Future<void> join() async => joins++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a new seat at the table plays the join chime', (tester) async {
    SharedPreferences.setMockInitialValues({
      'gc.onlinePlayerId': 'me',
      'gc.onlineName': 'Me',
    });
    friendSignals.reset();
    addTearDown(friendSignals.reset);

    final sound = _RecordingSound();
    final adopted = OnlineClient('ws://via.test/ws', seatId: 'me', name: 'Me');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [soundServiceProvider.overrideWithValue(sound)],
        child: MaterialApp(
          home: OnlineLobbyScreen(
            startup: OnlineStartup(adoptedClient: adopted),
          ),
        ),
      ),
    );
    await tester.pump();

    LobbySeat seat(String id, String name, LudoColor color) =>
        LobbySeat(name: name, color: color, seatId: id);

    // The room as we found it: the people already seated are not arrivals.
    adopted.lobbySeats.add(seat('me', 'Me', LudoColor.green));
    adopted.onSeats!();
    expect(sound.joins, 0, reason: 'the first roster only primes the set');

    // A friend takes the second seat.
    adopted.lobbySeats.add(seat('ana', 'Ana', LudoColor.red));
    adopted.onSeats!();
    expect(sound.joins, 1);

    // A repeated roster is not a second arrival.
    adopted.onSeats!();
    expect(sound.joins, 1);

    // Our own seat arriving late stays silent, even though we watched the
    // roster shrink first (a reconnect).
    adopted.lobbySeats.clear();
    adopted.onSeats!();
    adopted.lobbySeats.add(seat('me', 'Me', LudoColor.green));
    adopted.onSeats!();
    expect(sound.joins, 1, reason: 'our own seat is never an arrival');
  });
}
