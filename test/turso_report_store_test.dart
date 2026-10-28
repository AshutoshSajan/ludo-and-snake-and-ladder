/// ReportStore over Turso's HTTP pipeline: the feedback queue must behave
/// exactly like the SQLite implementation, including id capture from
/// `last_insert_rowid()` and atomic create/select writes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/server/report_store.dart';
import 'package:game_club/server/sql_backend.dart';

import 'fake_turso_pipeline.dart';

ReportStore _store(FakeTursoPipeline fake) => ReportStore.fromBackend(
  TursoBackend(
    url: Uri.parse('https://reports-test.turso.io'),
    authToken: 'test-token',
    client: fake.client,
  ),
);

void main() {
  test('create/update/delete round-trips and survives a redeploy', () async {
    final fake = FakeTursoPipeline();
    addTearDown(fake.dispose);

    var store = _store(fake);
    final made = await store.create(
      category: 'bug',
      message: 'Dice stuck',
      title: 'Dice',
    );
    expect(made.id, greaterThan(0));
    expect(made.status, 'open');
    expect(made.priority, 'medium');

    final updated = await store.update(made.id, {
      'status': 'in_progress',
      'priority': 'high',
    });
    expect(updated!.status, 'in_progress');
    expect(updated.priority, 'high');

    // A new process, a new store, the same remote database.
    store = _store(fake);
    expect((await store.byId(made.id))!.message, 'Dice stuck');
    expect(await store.count(), 1);
    expect(await store.count(status: 'open'), 0);
    expect(await store.delete(made.id), isTrue);
    expect(await store.delete(made.id), isFalse);
    expect(await store.byId(made.id), isNull);
  });

  test('openByCategory counts only actionable rows', () async {
    final fake = FakeTursoPipeline();
    addTearDown(fake.dispose);
    final store = _store(fake);

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

  test('a failed write leaves no half-created row behind', () async {
    final fake = FakeTursoPipeline();
    addTearDown(fake.dispose);
    final store = _store(fake);
    await store.ensureSchema();

    fake.failOnSql = 'SELECT * FROM feedback WHERE id = last_insert_rowid()';
    await expectLater(
      store.create(category: 'bug', message: 'Dice stuck'),
      throwsA(isA<SqlException>()),
    );
    expect(
      fake.db.select('SELECT COUNT(*) AS n FROM feedback').first['n'],
      0,
      reason: 'the insert and its id lookup are one transaction',
    );
  });

  test('validation rejects bad input before inserting', () async {
    final fake = FakeTursoPipeline();
    addTearDown(fake.dispose);
    final store = _store(fake);

    await expectLater(
      store.create(category: 'spam', message: 'm'),
      throwsArgumentError,
    );
    expect(fake.db.select('SELECT COUNT(*) AS n FROM feedback').first['n'], 0);
  });
}
