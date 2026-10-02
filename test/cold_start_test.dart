import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
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

/// A channel that refuses to open the way a sleeping host's proxy actually
/// does: [WebSocketChannel.connect] returns successfully and the failure only
/// shows up later, as an error on the stream.
///
/// This is the shape that mattered. The existing tests use a factory that
/// throws synchronously, which the client's `catch` already handled — so they
/// passed while the real path stayed broken. In a browser
/// `WebSocketChannel.connect` hands back a channel and lets the handshake fail
/// asynchronously, so a refused first connection reached `_onClosed` and was
/// charged to the *reconnect* budget: 5 attempts, 15.5s, "Connection lost".
class _AsyncDeadChannel extends StreamChannelMixin<dynamic>
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
  Stream<dynamic> get stream =>
      Stream<dynamic>.error(StateError('connection refused'));
  @override
  WebSocketSink get sink => _DeadSink();

  static var built = 0;
}

/// A channel that answers, used to prove the re-probe path recovers.
class _LiveChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  static final toClient = StreamController<dynamic>.broadcast();
  static _LiveChannel? _last;
  _LiveChannel() {
    _last = this;
  }

  static _LiveChannel get live => _last!;

  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  @override
  String? get protocol => null;
  @override
  Future<void> get ready => Future.value();
  @override
  Stream<dynamic> get stream => toClient.stream;
  @override
  WebSocketSink get sink => _DeadSink();

  void serverAdd(Map<String, dynamic> msg) => toClient.add(jsonEncode(msg));
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

  group('a refusal reported asynchronously', () {
    // WebSocketChannel.connect does not throw when the host refuses — it
    // returns a channel and fails the stream. These are the tests that were
    // missing, and their absence is why the room-creation bug shipped: both
    // tests above drive the factory into a synchronous throw, which the
    // `catch` in _openAndHello already handled.

    OnlineClient build() => OnlineClient(
          'ws://sleeping.example/ws',
          seatId: 'p1',
          name: 'Ana',
          channelFactory: (_) {
            _AsyncDeadChannel.built++;
            return _AsyncDeadChannel();
          },
        );

    test('waits out the host instead of reporting a lost connection', () {
      // Before the fix this reported "Connection lost — could not reach the
      // server" after ~15.5s, blaming a drop for a socket that never opened.
      fakeAsync((async) {
        final client = build();
        client.connect();
        // The refusal is delivered on a microtask, so let it land before
        // advancing time.
        async.flushMicrotasks();

        // setUp shrinks coldStartBaseDelay to 2ms, so the whole budget is
        // ~110ms. Elapse well inside it: the point is that we are still
        // waiting and still retrying, not that we survive forever.
        async.elapse(const Duration(milliseconds: 50));
        async.flushMicrotasks();

        expect(
          client.waitingForColdStart,
          isTrue,
          reason: 'the host is asleep, not the connection lost',
        );
        expect(
          client.status,
          OnlineStatus.connecting,
          reason: 'a refused first connection must not be an error status',
        );
        expect(
          client.errorText ?? '',
          isNot(contains('Connection lost')),
        );
        expect(
          _AsyncDeadChannel.built,
          greaterThan(1),
          reason: 'it must have retried rather than given up',
        );

        client.dispose();
        async.flushTimers();
      });
    });

    test('the cold-start budget outlasts the old 15.5s reconnect budget', () {
      // The specific regression: Render needs ~13.6s+ to wake, and the old
      // path was gone at 15.5s with the wrong message. Use the real budget
      // geometry and prove it is still waiting at the point the old one died.
      OnlineClient.coldStartBaseDelay = const Duration(milliseconds: 400);
      addTearDown(() => OnlineClient.coldStartBaseDelay =
          const Duration(milliseconds: 2));

      fakeAsync((async) {
        final client = build();
        client.connect();

        async.elapse(const Duration(milliseconds: 15500));
        async.flushMicrotasks();

        expect(
          client.status,
          isNot(OnlineStatus.error),
          reason: '15.5s was where the reconnect budget died; the cold-start '
              'budget is 400ms * (1+2+...+10) = 22s',
        );
        expect(client.waitingForColdStart, isTrue);

        client.dispose();
        async.flushTimers();
      });
    });

    test('still gives up eventually, and blames cold start', () {
      // The give-up path must survive the change, or a genuinely dead server
      // would spin forever behind a spinner.
      fakeAsync((async) {
        final client = build();
        client.connect();

        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();

        expect(client.status, OnlineStatus.error);
        expect(
          client.errorText,
          contains('starting up'),
          reason: 'the message should point at cold start, not blame the player',
        );

        client.dispose();
        async.flushTimers();
      });
    });
  test('a successful re-probe clears the cold-start loader', () {
      // Guards the regression this fix could have caused: without clearing
      // waitingForColdStart on 'joined', the fix for "gave up too early" would
      // have traded it for a UI stuck behind its spinner on a room that exists.
      fakeAsync((async) {
        var refuseFirst = true;
        final client = OnlineClient(
          'ws://sleeping.example/ws',
          seatId: 'p1',
          name: 'Ana',
          channelFactory: (_) {
            if (refuseFirst) {
              refuseFirst = false;
              return _AsyncDeadChannel();
            }
            return _LiveChannel();
          },
        );

        client.connect();
        async.flushMicrotasks();
        expect(client.waitingForColdStart, isTrue,
            reason: 'precondition: the host refused once');

        async.elapse(const Duration(milliseconds: 50));
        async.flushMicrotasks();
        expect(client.waitingForColdStart, isTrue);

        // The host has woken: the re-probe is answered.
        _LiveChannel.live.serverAdd(
            {'type': 'joined', 'code': 'ABCD', 'color': 'red'});
        async.flushMicrotasks();

        expect(client.status, OnlineStatus.inLobby);
        expect(
          client.waitingForColdStart,
          isFalse,
          reason: 'the loader must clear once the room actually exists',
        );

        client.dispose();
        async.flushTimers();
      });
    });
  });
}
