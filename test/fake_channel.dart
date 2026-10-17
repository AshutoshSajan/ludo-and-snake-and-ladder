/// A scripted server side of one WebSocket connection for client tests.
///
/// [FakeChannel] records everything the client sends, replays server
/// frames through [FakeChannel.serverAdd], and can simulate a network
/// drop. [FakeChannelFactory] hands out one channel per connect attempt,
/// mirroring the real reconnect pattern.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class FakeChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final sent = <Map<String, dynamic>>[];
  final toClient = StreamController<dynamic>.broadcast();
  bool dropped = false;

  @override
  int? get closeCode => dropped ? 1006 : null;
  @override
  String? get closeReason => null;
  @override
  String? get protocol => null;
  @override
  Future<void> get ready => Future.value();
  @override
  Stream<dynamic> get stream => toClient.stream;
  @override
  WebSocketSink get sink => FakeSink(this);

  /// Server -> client message.
  void serverAdd(Map<String, dynamic> msg) => toClient.add(jsonEncode(msg));

  /// Simulate a network failure: the client's stream errors and closes.
  void dropConnection() {
    dropped = true;
    toClient.addError(const SocketException('connection reset'));
    toClient.close();
  }
}

class FakeSink implements WebSocketSink {
  FakeSink(this.channel);
  final FakeChannel channel;

  @override
  Future<void> get done => Future.value();
  @override
  void add(dynamic data) => channel.sent.add(jsonDecode(data as String));
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<dynamic> stream) async {}
  @override
  Future close([int? closeCode, String? closeReason]) async {
    channel.dropped = true;
  }
}

class FakeChannelFactory {
  final channels = <FakeChannel>[];
  final uris = <Uri>[];
  FakeChannel create(Uri uri) {
    uris.add(uri);
    final ch = FakeChannel();
    channels.add(ch);
    return ch;
  }

  FakeChannel get last => channels.last;
}
