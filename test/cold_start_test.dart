import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/online_client.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A channel that refuses to open, the way a sleeping host's proxy does.
class _DeadChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  @override
  String? get protocol => null;
  @override
  Future<void> get ready => Future.value();
  @override
  Stream<dynamic> get stream => const Stream<dynamic>.empty();
  @override
  WebSocketSink get sink => _DeadSink();

  static var built = 0;
  static WebSocketChannel Function() factory = () {
    built++;
    throw StateError('connection refused');
  };
}

class _DeadSink implements WebSocketSink {
  @override
  Future<void> get done => Future.value();
  @override
  void add(dynamic data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<dynamic> stream) async {}
  @override
  Future close([int? closeCode, String? closeReason]) async {}
}

/// A cold-starting free-tier host refuses the first few sockets while the
/// platform wakes it. That is a wait, not a failure — reporting an error to
/// someone who pressed Play a moment early was the bug.
void main() {
  setUp(() {
    // Shrink the warm-up window so the give-up path is provable in a second
    // rather than in the 22s a real user would wait.
    OnlineClient.coldStartBaseDelay = const Duration(milliseconds: 2);
    _DeadChannel.built = 0;
    _DeadChannel.factory = () {
      _DeadChannel.built++;
      throw StateError('connection refused');
    };
  });

  test('a refused socket is retried, not reported as an error', () async {
    final client = OnlineClient(
      'ws://sleeping.example/ws',
      seatId: 'p1',
      name: 'Ana',
      channelFactory: (_) => _DeadChannel.factory(),
    );

    final connecting = client.connect();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      client.status,
      isNot(OnlineStatus.error),
      reason: 'a sleeping host must not surface as a failure',
    );
    expect(
      client.waitingForColdStart,
      isTrue,
      reason: 'the UI shows a loader for this, not an error',
    );

    client.dispose();
    await connecting.catchError((Object _) {});
  });

  test('giving up eventually reports a helpful error', () async {
    final client = OnlineClient(
      'ws://gone.example/ws',
      seatId: 'p1',
      name: 'Ana',
      channelFactory: (_) => _DeadChannel.factory(),
    );
    final connecting = client.connect();

    // Outlast the warm-up window, which is the point: a server that is
    // genuinely unreachable must still say so.
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (client.status == OnlineStatus.error) break;
    }
    expect(client.status, OnlineStatus.error);
    expect(
      client.errorText,
      contains('starting up'),
      reason: 'the message should point at cold start, not blame the player',
    );
    expect(
      _DeadChannel.built,
      greaterThan(1),
      reason: 'it must actually have retried',
    );

    client.dispose();
    await connecting.catchError((Object _) {});
  });
}
