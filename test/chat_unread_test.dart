import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/online_client.dart';

/// The red dot on the chat icon.
///
/// The rule being pinned is that *unread* means "arrived while the reader was
/// not looking". A message that lands with the panel open has been read by
/// definition, so counting it would leave a dot on the icon that never clears —
/// the worst possible failure for an indicator whose entire job is to tell you
/// when to clear it.
void main() {
  OnlineClient client() => OnlineClient('ws://localhost:8080/ws', seatId: 's1', name: 'Me');

  void deliver(OnlineClient c, String from, String text) {
    c.debugHandleMessage(jsonEncode({'type': 'chat', 'from': from, 'text': text}));
  }

  group('unread chat', () {
    test('a message arriving with the panel closed is unread', () {
      final c = client();
      deliver(c, 'Ana', 'hi');
      expect(c.unreadChats, 1);
      expect(c.chat.single.from, 'Ana');
    });

    test('opening the panel marks everything read', () {
      final c = client();
      deliver(c, 'Ana', 'one');
      deliver(c, 'Bo', 'two');
      expect(c.unreadChats, 2);

      c.setChatOpen(true);
      expect(c.unreadChats, 0, reason: 'reading and opening are the same act');
    });

    test('a message arriving with the panel open is not unread', () {
      final c = client()..setChatOpen(true);
      deliver(c, 'Ana', 'hi');
      expect(c.unreadChats, 0,
          reason: 'the reader is looking straight at it');
    });

    test('closing again re-arms the dot for later messages', () {
      final c = client()..setChatOpen(true);
      deliver(c, 'Ana', 'seen');
      c.setChatOpen(false);
      deliver(c, 'Bo', 'unseen');
      expect(c.unreadChats, 1);
    });

    test('the dot counts messages, not senders', () {
      final c = client();
      deliver(c, 'Ana', 'one');
      deliver(c, 'Ana', 'two');
      expect(c.unreadChats, 2);
    });

    test('markChatRead clears without changing panel state', () {
      final c = client()..setChatOpen(false);
      deliver(c, 'Ana', 'hi');
      c.markChatRead();
      expect(c.unreadChats, 0);
      expect(c.chatOpen, isFalse, reason: 'reading is not the same as opening');
    });


    test('the chime is wired by the game view, not the chat sheet', () {
      // Regression guard for the reason the sound was missing entirely: it used
      // to be wired in GameChatSheet.initState, so it could only fire after
      // that sheet had been opened at least once. The first messages of a game
      // - the ones you most want to hear - arrived in silence, and to a player
      // who had never tapped the icon there was no sound at all, ever.
      final c = client();
      var chimed = 0;
      // What LudoSession.online and OnlineSnakesView do on attach.
      c.onMessageArrived = (_) => chimed++;
      deliver(c, 'Ana', 'are you there?');
      deliver(c, 'Bo', 'starting now');
      expect(chimed, 2,
          reason: 'a message must sound without the sheet ever being opened');
      expect(c.unreadChats, 2);
    });

    test('onChat carries the sender and text for the notification', () {
      final c = client();
      ({String from, String text})? seen;
      c.onChat = (m) => seen = m;
      deliver(c, 'Ana', 'roll a six');
      expect(seen?.from, 'Ana');
      expect(seen?.text, 'roll a six');
    });
  });
}
