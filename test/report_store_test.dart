/// ReportStore: feedback create/list/update/delete, priority-aware
/// triage ordering, validation, and counts.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:game_club/server/report_store.dart';

void main() {
  late ReportStore store;

  setUp(() {
    store = ReportStore.inMemory();
  });

  group('create', () {
    test('files a bug with defaults (open, medium)', () async {
      final e = await store.create(category: 'bug', message: 'Dice stuck');
      expect(e.id, greaterThan(0));
      expect(e.status, 'open');
      expect(e.priority, 'medium');
      expect(e.source, 'report');
      expect(e.message, 'Dice stuck');
    });

    test('clamps long optional text', () async {
      final long = 'x' * 500;
      final e = await store.create(
        category: 'other',
        message: 'm',
        title: long,
        contact: long,
      );
      expect(e.title.length, ReportStore.maxTitleLength);
      expect(e.contact!.length, ReportStore.maxContactLength);
    });

    test('null-ifies empty optional strings', () async {
      final e = await store.create(
        category: 'other',
        message: 'm',
        contact: '  ',
      );
      expect(e.contact, isNull);
      expect(e.appVersion, isNull);
    });

    final badCases = <String, ({String category, String source, String message})>{
      'unknown category':
          (category: 'spam', source: 'report', message: 'm'),
      'unknown source':
          (category: 'bug', source: 'bogus', message: 'm'),
      'empty message': (category: 'bug', source: 'report', message: '   '),
      'too long message':
          (category: 'bug', source: 'report', message: 'y' * 4001),
    };
    for (final bad in badCases.entries) {
      test('rejects ${bad.key}', () async {
        await expectLater(
          store.create(
            category: bad.value.category,
            source: bad.value.source,
            message: bad.value.message,
          ),
          throwsArgumentError,
        );
      });
    }
  });

  group('triage ordering', () {
    setUp(() async {
      await store.create(category: 'bug', message: 'newest open medium',
          title: 'a');
      await Future<void>.delayed(const Duration(milliseconds: 15));
      final high = await store.create(
          category: 'bug', message: 'older open high', title: 'b');
      await Future<void>.delayed(const Duration(milliseconds: 15));
      final crit = await store.create(
          category: 'feature', message: 'newest open critical', title: 'c');
      await store.update(crit.id, {'priority': 'critical'});
      await store.update(high.id, {'priority': 'high'});
      final resolved = await store.create(
          category: 'bug', message: 'resolved low', title: 'd');
      await store.update(resolved.id, {'status': 'resolved'});
    });

    test('priority sort: open before resolved, critical before high',
        () async {
      final list = await store.list();
      expect(list.map((e) => e.title).toList(), ['c', 'b', 'a', 'd']);
    });

    test('newest sort ignores priority', () async {
      final list = await store.list(sort: 'newest');
      expect(list.map((e) => e.title).toList(), ['d', 'c', 'b', 'a']);
    });

    test('status filter', () async {
      final list = await store.list(status: 'resolved');
      expect(list, hasLength(1));
      expect(list.single.title, 'd');
    });

    test('category filter', () async {
      final list = await store.list(category: 'feature');
      expect(list, hasLength(1));
      expect(list.single.priority, 'critical');
    });
  });

  group('update', () {
    late FeedbackEntry made;

    setUp(() async {
      made = await store.create(category: 'bug', message: 'm');
    });

    test('partial update changes only present fields', () async {
      final e = await store.update(made.id, {
        'status': 'in_progress',
        'adminNotes': 'repro confirmed',
      });
      expect(e!.status, 'in_progress');
      expect(e.adminNotes, 'repro confirmed');
      expect(e.priority, 'medium');
      expect(e.message, 'm');
      expect(
        e.updatedAt,
        greaterThanOrEqualTo(e.createdAt),
      );
    });

    test('unknown field rejected', () async {
      await expectLater(
        store.update(made.id, {'hax': 'x'}),
        throwsArgumentError,
      );
    });

    test('bad status/category/priority rejected', () async {
      for (final patch in [
        {'status': 'gone'},
        {'category': 'spam'},
        {'priority': 'urgent'},
      ]) {
        await expectLater(
          store.update(made.id, patch),
          throwsArgumentError,
        );
      }
    });

    test('missing id returns null', () async {
      expect(await store.update(999, {'status': 'closed'}), isNull);
    });
  });

  group('delete + counts', () {
    test('delete removes the row, unknown id false', () async {
      final e = await store.create(category: 'bug', message: 'm');
      expect(await store.delete(e.id), isTrue);
      expect(await store.byId(e.id), isNull);
      expect(await store.delete(e.id), isFalse);
    });

    test('openByCategory counts only actionable', () async {
      final a = await store.create(category: 'bug', message: '1');
      await store.create(category: 'bug', message: '2');
      final q = await store.create(category: 'question', message: '3');
      await store.update(a.id, {'status': 'closed'});
      await store.update(q.id, {'status': 'in_progress'});
      final counts = await store.openByCategory();
      expect(counts['bug'], 1);
      expect(counts['question'], 1);
      expect(counts['feature'], isNull);
    });

    test('count by status', () async {
      await store.create(category: 'bug', message: '1');
      await store.create(category: 'bug', message: '2');
      expect(await store.count(), 2);
      expect(await store.count(status: 'open'), 2);
    });
  });
}
