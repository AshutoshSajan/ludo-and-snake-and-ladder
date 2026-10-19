/// FriendStore contract: profile service with stable friend codes, the
/// request → friendship lifecycle (including the both-pressed-add match),
/// DMs with likes and reply quotes, invite lifecycle and expiry, and the
/// per-seat caps that bound abuse.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/server/friend_store.dart';

void main() {
  late FriendStore store;

  /// A controllable clock so expiry tests are deterministic.
  DateTime now = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);

  setUp(() {
    store = FriendStore.withClock(() => now);
  });

  tearDown(() => store.close());

  /// Registers both players and makes them friends via a full handshake.
  Future<void> makeFriends(String a, String b) async {
    await store.serve(a, a.isEmpty ? 'A' : a);
    await store.serve(b, b);
    await store.sendRequest(a, a, b);
    await store.respond(b, (await store.incoming(b)).single.id, accept: true);
  }

  group('profiles', () {
    test('serves a profile with a readable 6-char code', () async {
      final p = await store.serve('p1', 'Swift Otter');
      expect(p.seatId, 'p1');
      expect(p.name, 'Swift Otter');
      expect(RegExp(r'^[2-9A-HJ-NP-Z]{6}$').hasMatch(p.code), isTrue);
    });

    test('code survives a re-serve and keeps the newest name', () async {
      final first = await store.serve('p1', 'Old Name');
      final second = await store.serve('p1', 'New Name');
      expect(second.code, first.code, reason: 'codes are minted once');
      expect(second.name, 'New Name');
    });

    test('codes are unique across profiles and findable', () async {
      final a = await store.serve('p1', 'A');
      final b = await store.serve('p2', 'B');
      expect(a.code, isNot(b.code));
      expect(store.profileByCode(a.code)!.seatId, 'p1');
    });

    test('resolveTarget treats uppercase 6-char tokens as codes', () async {
      await store.serve('p1', 'A');
      expect(store.resolveTarget(store.profile('p1')!.code)!.seatId, 'p1');
      expect(store.resolveTarget('p1')!.seatId, 'p1');
      expect(store.resolveTarget('ZZZZZZ'), isNull);
      expect(store.resolveTarget(''), isNull);
    });

    test('serving requires identity', () async {
      await expectLater(store.serve(' ', 'A'), throwsArgumentError);
      await expectLater(store.serve('p1', '   '), throwsArgumentError);
    });
  });

  group('requests', () {
    test('send → incoming/outgoing → accept → friendship', () async {
      await store.serve('p1', 'A');
      await store.serve('p2', 'B');
      expect(await store.sendRequest('p1', 'A', 'p2'), 'pending');
      final incoming = await store.incoming('p2');
      expect(incoming.single.fromName, 'A');
      expect((await store.outgoing('p1')).single.toName, 'B');
      expect(store.areFriends('p1', 'p2'), isFalse);

      expect(
        await store.respond('p2', incoming.single.id, accept: true),
        isTrue,
      );
      expect(store.areFriends('p1', 'p2'), isTrue);
      expect(await store.incoming('p2'), isEmpty);
      expect(await store.outgoing('p1'), isEmpty);
      final friends = await store.friends('p1');
      expect(friends.single.seatId, 'p2');
      expect((await store.friends('p2')).single.seatId, 'p1');
    });

    test('duplicate request is idempotent', () async {
      await store.serve('p1', 'A');
      await store.serve('p2', 'B');
      await store.sendRequest('p1', 'A', 'p2');
      expect(await store.sendRequest('p1', 'A', 'p2'), 'pending');
      expect((await store.outgoing('p1')).length, 1);
    });

    test('both sides asking at once becomes a friendship', () async {
      await store.serve('p1', 'A');
      await store.serve('p2', 'B');
      await store.sendRequest('p2', 'B', 'p1');
      expect(await store.sendRequest('p1', 'A', 'p2'), 'accepted');
      expect(store.areFriends('p1', 'p2'), isTrue);
      expect(await store.incoming('p1'), isEmpty);
      expect(await store.incoming('p2'), isEmpty);
      expect(await store.outgoing('p1'), isEmpty);
    });

    test('decline clears the request and unfriends nothing', () async {
      await store.serve('p1', 'A');
      await store.serve('p2', 'B');
      await store.sendRequest('p1', 'A', 'p2');
      final id = (await store.incoming('p2')).single.id;
      expect(await store.respond('p2', id, accept: false), isTrue);
      expect(await store.incoming('p2'), isEmpty);
      expect(store.areFriends('p1', 'p2'), isFalse);
      // A decline is not a block: the sender may re-ask.
      expect(await store.sendRequest('p1', 'A', 'p2'), 'pending');
    });

    test('only the receiver can accept a request', () async {
      await store.serve('p1', 'A');
      await store.serve('p2', 'B');
      await store.serve('p3', 'C');
      await store.sendRequest('p1', 'A', 'p2');
      final id = (await store.outgoing('p1')).single.id;
      expect(await store.respond('p3', id, accept: true), isFalse);
      expect(store.areFriends('p1', 'p2'), isFalse);
    });

    test('unfriend works from either side', () async {
      await makeFriends('p1', 'p2');
      expect(await store.remove('p2', 'p1'), isTrue);
      expect(store.areFriends('p1', 'p2'), isFalse);
    });

    test('errors: self, unknown, already friends', () async {
      await store.serve('p1', 'A');
      expect(store.sendRequest('p1', 'A', 'p1'), throwsStateError);
      expect(store.sendRequest('p1', 'A', 'ghost'), throwsArgumentError);
      await store.serve('p2', 'B');
      await store.sendRequest('p1', 'A', 'p2');
      await store.respond(
        'p2',
        (await store.incoming('p2')).single.id,
        accept: true,
      );
      expect(store.sendRequest('p2', 'B', 'p1'), throwsStateError);
    });

    test('cancelling an outgoing request clears it', () async {
      await store.serve('p1', 'A');
      await store.serve('p2', 'B');
      await store.sendRequest('p1', 'A', 'p2');
      final id = (await store.outgoing('p1')).single.id;
      expect(await store.cancel('p1', id), isTrue);
      expect(await store.outgoing('p1'), isEmpty);
      expect(await store.incoming('p2'), isEmpty);
    });

    test('a request snapshots names and codes at send time', () async {
      final sender = await store.serve('p1', 'Sender');
      final target = await store.serve('p2', 'Original');
      await store.sendRequest('p1', 'Sender', 'p2');
      await store.serve('p1', 'Renamed Later');
      final incoming = (await store.incoming('p2')).single;
      expect(incoming.fromName, 'Sender');
      expect(incoming.fromCode, sender.code);
      expect(incoming.toName, 'Original');
      expect(incoming.toCode, target.code);
    });

    test('targeting by friend code works', () async {
      await store.serve('p1', 'A');
      final target = await store.serve('p2', 'B');
      expect(await store.sendRequest('p1', 'A', target.code), 'pending');
      expect((await store.incoming('p2')).single.fromSeat, 'p1');
    });
  });

  group('chat', () {
    setUp(() => makeFriends('p1', 'p2'));

    test('friends exchange messages, non-friends do not', () async {
      final m = await store.send('p1', 'p2', 'gg — rematch?');
      expect(m.body, 'gg — rematch?');
      expect(m.liked, isFalse);
      expect(m.fromIs('p1'), isTrue);

      await store.serve('p3', 'C');
      expect(store.send('p1', 'p3', 'hello?'), throwsStateError);
      expect(store.send('p1', 'p2', '   '), throwsArgumentError);
      expect(store.send('p1', 'p2', 'x' * 1001), throwsArgumentError);
    });

    test('pages read oldest-first and sinceId skips the known past', () async {
      await store.send('p1', 'p2', 'one');
      await store.send('p2', 'p1', 'two');
      final m3 = await store.send('p1', 'p2', 'three');
      final page = await store.chat('p1', 'p2');
      expect(page.messages.map((m) => m.body), ['one', 'two', 'three']);
      expect(page.latestId, m3.id);

      final newer = await store.chat('p1', 'p2', since: m3.id);
      expect(newer.messages, isEmpty);
      await store.send('p2', 'p1', 'four');
      final fresh = await store.chat('p1', 'p2', since: m3.id);
      expect(fresh.messages.single.body, 'four');
    });

    test('both sides read the same thread transparently', () async {
      await store.send('p1', 'p2', 'from me');
      await store.send('p2', 'p1', 'from them');
      final mine = await store.chat('p1', 'p2');
      final theirs = await store.chat('p2', 'p1');
      expect(mine.messages.last.fromSeat, 'p2');
      expect(theirs.messages.last.fromSeat, 'p2');
      expect(mine.messages.first.fromIs('p1'), isTrue);
      expect(theirs.messages.first.fromIs('p1'), isTrue);
    });

    test('likes are toggleable by either participant', () async {
      final byMe = await store.send('p1', 'p2', 'nice roll');
      final byThem = await store.send('p2', 'p1', 'pure luck');

      // The recipient likes the sender's message…
      await store.like('p1', byThem.id, liked: true);
      expect(store.message(byThem.id)!.liked, isTrue);
      // …and the sender likes their own.
      await store.like('p2', byMe.id, liked: true);
      expect(store.message(byMe.id)!.liked, isTrue);

      // Third parties cannot like anything.
      await store.serve('p3', 'C');
      expect(await store.like('p3', byMe.id, liked: true), isNull);

      // Unliking restores an empty heart.
      await store.like('p1', byThem.id, liked: false);
      expect(store.message(byThem.id)!.liked, isFalse);
    });

    test('history trims to the cap per pair', () async {
      for (var i = 0; i < FriendCaps.chatHistoryPerPair + 10; i++) {
        await store.send('p1', 'p2', 'msg $i');
      }
      final page = await store.chat('p1', 'p2', limit: 400);
      expect(page.messages.length, FriendCaps.chatHistoryPerPair);
      expect(page.messages.first.body, 'msg 10');
      expect(
        page.messages.last.body,
        'msg ${FriendCaps.chatHistoryPerPair + 9}',
      );
    });
  });

  group('reply quotes', () {
    setUp(() => makeFriends('p1', 'p2'));

    test('reply carries a snapshot of the quoted message', () async {
      final first = await store.send('p1', 'p2', 'Which game tonight?');
      final reply = await store.send(
        'p2',
        'p1',
        'Ludo, obviously',
        replyTo: first.id,
      );
      expect(reply.replyToId, first.id);
      expect(reply.replyFrom, 'p1');
      expect(reply.replyBody, 'Which game tonight?');
    });

    test('a quoted message belonging to another pair is rejected', () async {
      await store.serve('p9', 'D');
      await store.serve('p8', 'E');
      await makeFriends('p9', 'p8');
      final stranger = await store.send('p9', 'p8', 'not your thread');
      expect(
        store.send('p1', 'p2', 'hijack', replyTo: stranger.id),
        throwsArgumentError,
      );
    });

    test(
      'a reply keeps its quote even after the quoted row is trimmed',
      () async {
        // Two hundred messages fill the window; 'keep me' stays visible for
        // one more turn, so the reply can quote it.
        for (var i = 1; i < FriendCaps.chatHistoryPerPair; i++) {
          await store.send('p1', 'p2', 'filler $i');
        }
        final old = await store.send('p1', 'p2', 'keep me');
        final reply = await store.send(
          'p2',
          'p1',
          'about the old one',
          replyTo: old.id,
        );
        // Then 199 more push 'keep me' (and only 'keep me') out of the
        // 200-message window…
        for (var i = 0; i < FriendCaps.chatHistoryPerPair - 1; i++) {
          await store.send('p1', 'p2', 'more $i');
        }
        // …and the reply's cached quote is what keeps it readable.
        expect(reply.replyBody, 'keep me');
        final page = await store.chat('p1', 'p2', limit: 400);
        expect(page.messages.length, FriendCaps.chatHistoryPerPair);
        expect(page.messages.first.replyBody, 'keep me');
      },
    );

    test('replying to an unknown message is rejected', () async {
      await expectLater(
        store.send('p1', 'p2', 'x', replyTo: 987654),
        throwsArgumentError,
      );
    });
  });

  group('invites', () {
    setUp(() => makeFriends('p1', 'p2'));

    test('send → pending → accept returns the room code', () async {
      final invite = await store.sendInvite(
        'p1',
        'A',
        'p2',
        'ludo',
        code: 'ABCD',
      );
      expect(invite.status, 'pending');
      expect(invite.code, 'ABCD');
      expect((await store.invites('p2')).single.game, 'ludo');

      final code = await store.respondInvite('p2', invite.id, accept: true);
      expect(code, 'ABCD');
      final after = (await store.invites('p2')).single;
      expect(after.status, 'accepted');
    });

    test('decline and re-invite supersede the pending row', () async {
      final invite = await store.sendInvite('p1', 'A', 'p2', 'snakes');
      expect(await store.respondInvite('p2', invite.id, accept: false), isNull);
      final declined = (await store.invites('p2')).single;
      expect(declined.status, 'declined');

      // A fresh invite replaces the old one rather than stacking.
      final again = await store.sendInvite('p1', 'A', 'p2', 'ludo');
      expect(again.id, isNot(invite.id));
      final list = await store.invites('p2');
      expect(list.where((i) => i.isPending).length, 1);
    });

    test('invites only go to friends, for valid games', () async {
      await store.serve('p3', 'C');
      expect(store.sendInvite('p1', 'A', 'p3', 'ludo'), throwsStateError);
      expect(store.sendInvite('p1', 'A', 'p2', 'poker'), throwsArgumentError);
      expect(
        store.sendInvite('p1', 'A', 'p2', 'ludo', code: 'TOOLONG12'),
        throwsArgumentError,
      );
      expect(store.sendInvite('p1', 'A', 'p1', 'ludo'), throwsStateError);
    });

    test('only the invitee can respond', () async {
      final invite = await store.sendInvite('p1', 'A', 'p2', 'ludo');
      expect(await store.respondInvite('p1', invite.id, accept: true), isNull);
      // Still pending for the invitee.
      expect((await store.invites('p2')).single.isPending, isTrue);
    });

    test(
      'a code-less invite resolves, and answering it is idempotent',
      () async {
        final invite = await store.sendInvite('p1', 'A', 'p2', 'ludo');
        expect(invite.code, isNull);
        expect(
          await store.respondInvite('p2', invite.id, accept: true),
          isNull,
        );
        expect(
          await store.respondInvite('p2', invite.id, accept: true),
          isNull,
          reason: 'accepting twice keeps the first answer',
        );
      },
    );

    test('stale pendings expire on read', () async {
      final invite = await store.sendInvite('p1', 'A', 'p2', 'ludo');
      expect((await store.invites('p2')).single.isPending, isTrue);

      // Two hours pass: the invitation is closed for us, not merely old.
      now = now.add(FriendCaps.inviteLifetime * 2);
      final list = await store.invites('p2');
      expect(list.single.status, 'expired');
      expect(await store.respondInvite('p2', invite.id, accept: true), isNull);
    });
  });

  group('blocking', () {
    test('block severs friendship, pending requests and invites', () async {
      await store.serve('p3', 'C');
      await store.serve('p4', 'D');
      await store.sendRequest('p3', 'C', 'p4');
      await store.block('p3', 'p4');
      expect((await store.incoming('p4')), isEmpty);
      expect((await store.outgoing('p3')), isEmpty);

      await makeFriends('p1', 'p2');
      await store.sendInvite('p1', 'A', 'p2', 'ludo');
      await store.block('p1', 'p2');
      expect(store.areFriends('p1', 'p2'), isFalse);
      final live = (await store.invites('p2'))
          .where((i) => i.status == 'pending')
          .toList();
      expect(live, isEmpty);
    });

    test('blocked pair cannot re-add, chat, or invite either way', () async {
      await makeFriends('p1', 'p2');
      await store.block('p1', 'p2');

      // The blocked side politely refuses; the blocking side sees why.
      await expectLater(
        store.sendRequest('p2', 'B', 'p1'),
        throwsArgumentError,
      );
      await expectLater(store.sendRequest('p1', 'A', 'p2'), throwsStateError);
      // The friendship was severed, so DMs die in both directions.
      await expectLater(store.send('p1', 'p2', 'hi'), throwsStateError);
      await expectLater(store.send('p2', 'p1', 'hi'), throwsStateError);
      await expectLater(
        store.sendInvite('p1', 'A', 'p2', 'ludo'),
        throwsStateError,
      );

      // Unblocking reopens the door but does not restore the friendship.
      expect(await store.unblock('p1', 'p2'), isTrue);
      expect(await store.unblock('p1', 'p2'), isFalse, reason: 'already gone');
      expect(store.isBlocked('p1', 'p2'), isFalse);
      expect(await store.sendRequest('p1', 'A', 'p2'), 'pending');

      await expectLater(store.block('p1', 'p1'), throwsStateError);
      await expectLater(store.block('ghost', 'p1'), throwsArgumentError);
    });

    test('blocks list preserves the name at block time', () async {
      await store.serve('p1', 'A');
      await store.serve('p2', 'Enemy');
      await store.block('p1', 'p2');
      final listed = (await store.blocks('p1')).single;
      expect(listed.blocked, 'p2');
      expect(listed.blockedName, 'Enemy');
      expect(listed.createdAtMs, now.millisecondsSinceEpoch);
      // Rename later; the block entry keeps the historical name.
      await store.serve('p2', 'Renamed');
      expect((await store.blocks('p1')).single.blockedName, 'Enemy');
    });

    test('block cap refuses the overflow', () async {
      await store.serve('spammer', 'S');
      for (var i = 0; i < FriendStore.blocksPerSeat; i++) {
        final x = 'b$i';
        await store.serve(x, 'B$i');
        await store.block('spammer', x);
      }
      await store.serve('one-too-many', 'T');
      expect(store.block('spammer', 'one-too-many'), throwsStateError);
    });
  });

  group('caps', () {
    test('pending request cap refuses the overflow', () async {
      await store.serve('spammer', 'S');
      for (var i = 0; i < FriendCaps.pendingPerSeat; i++) {
        await store.serve('p$i', 'P$i');
        await store.sendRequest('spammer', 'S', 'p$i');
      }
      await store.serve('one-too-many', 'T');
      expect(
        store.sendRequest('spammer', 'S', 'one-too-many'),
        throwsStateError,
      );
    });

    test('friend cap blocked via per-seat ceiling', () async {
      await store.serve('hub', 'H');
      await store.serve('target', 'T');
      // Saturate the target's list with other players.
      for (var i = 0; i < FriendCaps.friendsPerSeat; i++) {
        final x = 'x$i';
        await store.serve(x, 'X$i');
        await store.sendRequest(x, 'X$i', 'target');
        await store.respond(
          'target',
          (await store.incoming('target')).single.id,
          accept: true,
        );
      }
      expect(store.friendCount('target'), FriendCaps.friendsPerSeat);
      expect(store.sendRequest('hub', 'H', 'target'), throwsStateError);
    });

    test('invite cap per invitee', () async {
      for (var i = 0; i < FriendCaps.invitesPerSeat; i++) {
        final x = 'inv$i';
        await store.serve(x, 'I$i');
        await makeFriends(x, 'invitee');
        await store.sendInvite(x, 'I$i', 'invitee', 'ludo');
        // Distinct senders each hold one pending invite, so twenty fills
        // the invitee's tray and the next sender is refused.
      }
      await store.serve('invX', 'IX');
      await makeFriends('invX', 'invitee');
      expect(
        store.sendInvite('invX', 'IX', 'invitee', 'ludo'),
        throwsStateError,
      );
    });
  });

  group('tablemate mint (the roster name rides the seat id)', () {
    // A gameplay-sourced target is usually a player who has never opened
    // the friends screen — no profile, no code. The room already knows
    // their name, so the request carries it as targetName and the store
    // mints; the minted name heals when the target's own friends call
    // re-registers them under their own typed name.
    test(
      'seat-id request mints a profile for a player who never opened friends',
      () async {
        await store.serve('p1', 'Sam');
        final status = await store.sendRequest(
          'p1',
          'Sam',
          'p9',
          targetName: 'Rally Bo',
        );
        expect(status, 'pending');
        final minted = store.profile('p9');
        expect(
          minted,
          isNotNull,
          reason: 'the tablemate resolves for later traffic',
        );
        expect(minted!.name, 'Rally Bo');
        final incoming = await store.incoming('p9');
        expect(incoming.single.fromSeat, 'p1');
        expect(incoming.single.toName, 'Rally Bo');
      },
    );

    test(
      'the both-pressed-add match still wins when the mint path is taken',
      () async {
        await store.serve('p1', 'Sam');
        // The tablemate's side came in first (their own server minted them).
        await store.serve('p9', 'Rally Bo');
        await store.sendRequest('p9', 'Rally Bo', 'p1');
        final status = await store.sendRequest(
          'p1',
          'Sam',
          'p9',
          targetName: 'Rally Bo',
        );
        expect(
          status,
          'accepted',
          reason: 'both pressed add — friends at once',
        );
      },
    );

    test(
      'code-shaped targets stay unmintable: only the owner mints a code',
      () async {
        await store.serve('p1', 'Sam');
        expect(
          store.sendRequest('p1', 'Sam', 'XZK246', targetName: 'Ghost'),
          throwsArgumentError,
        );
        expect(store.profile('XZK246'), isNull);
      },
    );

    test(
      'no targetName means an unknown seat id is an answer, not a mint',
      () async {
        await store.serve('p1', 'Sam');
        expect(store.sendRequest('p1', 'Sam', 'p9'), throwsArgumentError);
        expect(store.profile('p9'), isNull);
      },
    );

    test(
      'block mints the same way — it must not depend on a target menu',
      () async {
        await store.serve('p1', 'Sam');
        final created = await store.block(
          'p1',
          'p9',
          targetName: 'Quiet Guest',
        );
        expect(created, isTrue);
        expect(store.isBlocked('p1', 'p9'), isTrue);
        expect(store.profile('p9')!.name, 'Quiet Guest');
      },
    );

    test(
      'block without a mint name on a profileless target explains itself',
      () async {
        await store.serve('p1', 'Sam');
        expect(store.block('p1', 'p9'), throwsArgumentError);
        expect(store.profile('p9'), isNull);
      },
    );
  });
}
