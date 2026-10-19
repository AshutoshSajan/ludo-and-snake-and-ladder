/// Report + generic admin-table API: public POST /feedback gating
/// (validation, throttling), admin feedback triage, the whitelisted
/// table CRUD, and the secret columns that must never leak.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:sqlite3/sqlite3.dart' show sqlite3;

import 'package:game_club/server/admin_store.dart';
import 'package:game_club/server/admin_tables.dart';
import 'package:game_club/server/report_store.dart';

import '../bin/server.dart'
    show
        adminActionHandler,
        adminFeedbackHandler,
        adminTableHandler,
        adminStore,
        adminOverviewHandler,
        adminToken,
        feedbackCreateHandler,
        reportStore,
        resetFeedbackAttempts;

shelf.Request _get(String path, {String? token, Map<String, String>? query}) {
  final uri = Uri.parse('http://localhost/$path').replace(
    queryParameters: query,
  );
  return shelf.Request(
    'GET',
    uri,
    headers: {if (token != null) 'authorization': 'Bearer $token'},
  );
}

shelf.Request _post(String path, Map<String, dynamic> body, {String? token}) =>
    shelf.Request(
      'POST',
      Uri.parse('http://localhost/$path'),
      headers: {
        if (token != null) 'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: Stream.fromIterable([utf8.encode(jsonEncode(body))]),
    );

Future<Map<String, dynamic>> _json(shelf.Response r) async =>
    jsonDecode(await r.readAsString()) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdminStore savedAdmin;
  late ReportStore savedReports;
  late String savedToken;

  setUp(() {
    savedAdmin = adminStore;
    savedReports = reportStore;
    savedToken = adminToken;
    // One shared in-memory connection, exactly like main() shares one
    // file connection: the Data tab reaches tables created by either
    // store through the admin store's connection.
    final db = sqlite3.openInMemory();
    adminStore = AdminStore.fromDb(db);
    reportStore = ReportStore.fromDb(db);
    adminToken = 'secret';
    resetFeedbackAttempts();
    addTearDown(() {
      adminStore = savedAdmin;
      reportStore = savedReports;
      adminToken = savedToken;
      resetFeedbackAttempts();
    });
  });

  group('public POST /feedback', () {
    test('files a valid report', () async {
      final r = await feedbackCreateHandler(
        _post('feedback', {
          'category': 'bug',
          'message': 'Dice never shows six',
          'title': 'Dice',
          'contact': 'a@b.c',
        }),
      );
      expect(r.statusCode, 200);
      final body = await _json(r);
      expect(body['ok'], isTrue);
      final row = await reportStore.byId(body['id'] as int);
      expect(row!.category, 'bug');
    });

    test('rejects unknown category and empty message', () async {
      final bad = await feedbackCreateHandler(
        _post('feedback', {'category': 'spam', 'message': 'm'}),
      );
      expect(bad.statusCode, 400);
      final empty = await feedbackCreateHandler(
        _post('feedback', {'category': 'bug'}),
      );
      expect(empty.statusCode, 400);
    });

    test('GET is 405', () async {
      final r = await feedbackCreateHandler(_get('feedback'));
      expect(r.statusCode, 405);
    });

    test('floods are throttled per IP', () async {
      shelf.Response? last;
      for (var i = 0; i < 7; i++) {
        last = await feedbackCreateHandler(
          _post('feedback', {'category': 'bug', 'message': 'report $i'}),
        );
      }
      expect(last!.statusCode, 429);
    });
  });

  group('admin feedback triage', () {
    test('denies the queue without a token', () async {
      final r = await adminFeedbackHandler(_get('admin/feedback'));
      expect(r.statusCode, 403);
    });

    test('lists sorted by priority with counts', () async {
      final high = await reportStore.create(
        category: 'bug',
        message: 'high',
      );
      await reportStore.update(high.id, {'priority': 'high'});
      await reportStore.create(category: 'bug', message: 'medium');
      final r = await adminFeedbackHandler(
        _get('admin/feedback', token: 'secret'),
      );
      final body = await _json(r);
      expect((body['feedback'] as List).first['message'], 'high');
      expect(body['openCount'], 2);
      expect(body['totalCount'], 2);
      expect(body['openByCategory'], {'bug': 2});
    });

    test('update writes status/priority and the audit log knows', () async {
      final e = await reportStore.create(
        category: 'bug',
        message: 'm',
        source: 'contact',
      );
      final r = await adminActionHandler(
        _post('admin/feedback/update', {
          'id': e.id,
          'status': 'resolved',
          'priority': 'critical',
          'adminNotes': 'fixed in 1.2.3',
        }, token: 'secret'),
      );
      expect(r.statusCode, 200);
      final updated = await reportStore.byId(e.id);
      expect(updated!.status, 'resolved');
      expect(updated.priority, 'critical');
      expect(updated.adminNotes, 'fixed in 1.2.3');
      final audit = await adminStore.auditLog();
      expect(audit.any((a) => a.action == 'feedbackUpdate'), isTrue);
    });

    test('invalid status is a 400, not a corruption', () async {
      final e = await reportStore.create(
        category: 'bug',
        message: 'm',
      );
      final r = await adminActionHandler(
        _post('admin/feedback/update', {
          'id': e.id,
          'status': 'wat',
        }, token: 'secret'),
      );
      expect(r.statusCode, 400);
      expect((await reportStore.byId(e.id))!.status, 'open');
    });

    test('delete removes and audits', () async {
      final e = await reportStore.create(
        category: 'bug',
        message: 'm',
      );
      final r = await adminActionHandler(
        _post('admin/feedback/delete', {'id': e.id}, token: 'secret'),
      );
      expect(r.statusCode, 200);
      expect(await reportStore.byId(e.id), isNull);
      final missing = await adminActionHandler(
        _post('admin/feedback/delete', {'id': e.id}, token: 'secret'),
      );
      expect(missing.statusCode, 404);
    });
  });

  group('generic admin table CRUD', () {
    test('unknown table is rejected everywhere', () async {
      expect(
        (await adminTableHandler(
          _get('admin/table?table=secret_stash', token: 'secret'),
        )).statusCode,
        400,
      );
      expect(
        (await adminActionHandler(
          _post('admin/table/insert', {
            'table': 'secret_stash',
          }, token: 'secret'),
        )).statusCode,
        400,
      );
    });

    test('deny without token', () async {
      expect(
        (await adminTableHandler(
          _get('admin/table?table=feedback'),
        )).statusCode,
        403,
      );
    });

    test('lists rows with spec + never password hashes', () async {
      await adminStore.createUser(
        email: 'x@y.z',
        name: 'X',
        password: 'hunter2hunter2',
      );
      final r = await adminTableHandler(
        _get('admin/table?table=auth_users', token: 'secret'),
      );
      final body = await _json(r);
      final cols = (body['columns'] as List).cast<String>();
      expect(cols, isNot(contains('password_hash')));
      final rows = (body['rows'] as List).cast<Map>();
      expect(rows.single, isNot(containsPair('password_hash', anything)));
      expect(rows.single['email'], 'x@y.z');
      expect(body['pk'], 'id');
    });

    test('insert, update, delete a results row', () async {
      final r = await adminActionHandler(
        _post('admin/table/insert', {
          'table': 'results',
          'values': {
            'game_id': 'g1',
            'seat_id': 's1',
            'name': 'Ana',
            'color': 'red',
            'rank': 1,
            'played_at': 12345,
            'game': 'ludo',
          },
        }, token: 'secret'),
      );
      expect(r.statusCode, 200);
      final spec = tableSpec('results')!;
      final rows = adminStore.tableRows(spec);
      expect(rows, hasLength(1));
      expect(rows.single['name'], 'Ana');

      final u = await adminActionHandler(
        _post('admin/table/update', {
          'table': 'results',
          'pk': '${rows.single['id']}',
          'values': {'name': 'Ana P.'},
        }, token: 'secret'),
      );
      expect(u.statusCode, 200);
      expect(adminStore.tableRows(spec).single['name'], 'Ana P.');

      expect(
        (await adminActionHandler(
          _post('admin/table/update', {
            'table': 'results',
            'pk': '${rows.single['id']}',
            'values': {'rank': 3},
          }, token: 'secret'),
        )).statusCode,
        200,
      );
      expect(adminStore.tableRows(spec).single['rank'], 3);

      final d = await adminActionHandler(
        _post('admin/table/delete', {
          'table': 'results',
          'pk': '${rows.single['id']}',
        }, token: 'secret'),
      );
      expect(d.statusCode, 200);
      expect(adminStore.tableRows(spec), isEmpty);
    });

    test('read-only tables refuse writes', () async {
      final audit = tableSpec('admin_audit')!;
      final before = adminStore.tableRows(audit).length;
      expect(
        (await adminActionHandler(
          _post('admin/table/insert', {
            'table': 'admin_audit',
            'values': {'action': 'fake', 'seat_id': 'x', 'by_name': 'n'},
          }, token: 'secret'),
        )).statusCode,
        400,
        reason: 'admin_audit is not insertable',
      );
      expect(
        (await adminActionHandler(
          _post('admin/table/delete', {
            'table': 'admin_audit',
            'pk': '1',
          }, token: 'secret'),
        )).statusCode,
        400,
        reason: 'admin_audit is not deletable',
      );
      expect(adminStore.tableRows(audit).length, before);
    });

    test('writable-value whitelist blocks column injection', () async {
      final spec = tableSpec('players')!;
      final before = adminStore.tableRows(spec).length;
      final r = await adminActionHandler(
        _post('admin/table/insert', {
          'table': 'players',
          'values': {
            'seat_id': 's9',
            'name': 'Ok',
          },
        }, token: 'secret'),
      );
      expect(r.statusCode, 200);
      expect(adminStore.tableRows(spec).length, before + 1);

      final bad = await adminActionHandler(
        _post('admin/table/update', {
          'table': 'players',
          'pk': 's9',
          'values': {'bogus_column': 'x'},
        }, token: 'secret'),
      );
      expect(bad.statusCode, 400);
    });

    test('search narrows by substring', () async {
      final spec = tableSpec('feedback')!;
      final r = adminStore.tableRows(spec, q: 'nomatch');
      expect(r, isEmpty);
    });

    test('deleting an unknown row is a 404', () async {
      final r = await adminActionHandler(
        _post('admin/table/delete', {
          'table': 'results',
          'pk': '999',
        }, token: 'secret'),
      );
      expect(r.statusCode, 404);
    });
  });

  group('overview + legacy auth', () {
    test('overview counts open feedback and denies the legacy token',
        () async {
      await reportStore.create(category: 'bug', message: 'open');
      await reportStore.create(category: 'bug', message: 'open 2');
      final closed = await reportStore.create(
        category: 'bug',
        message: 'closed',
      );
      await reportStore.update(closed.id, {'status': 'closed'});

      final denied = await adminOverviewHandler(
        _get('admin/overview'),
      );
      expect(denied.statusCode, 403);

      final r = await adminOverviewHandler(
        _get('admin/overview', token: 'secret'),
      );
      expect(r.statusCode, 200);
      final body = await _json(r);
      expect(body['stored']['openFeedback'], 2);
      expect((body['stored']['feedbackByCategory'] as Map)['bug'], 2);
    });
  });
}
