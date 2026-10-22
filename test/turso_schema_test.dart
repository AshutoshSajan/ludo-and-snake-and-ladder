/// `deploy/turso_schema.sql` is the explicit-provisioning path; it must
/// create exactly the tables the friends store expects (the store also
/// creates them lazily, but a documented schema that omits one would only
/// fail on a hand-provisioned database).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('the provisioning schema contains every friends table and column', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(File('deploy/turso_schema.sql').readAsStringSync());

    final tables = {
      for (final row in db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ))
        row['name'] as String,
    };
    expect(
      tables,
      containsAll([
        'friend_profiles',
        'friendships',
        'friend_requests',
        'friend_messages',
        'friend_invites',
        'friend_blocks',
        // The older stores keep sharing the file.
        'results',
        'players',
        'room_registry',
      ]),
    );

    Set<String> columns(String table) => {
      for (final row in db.select(
        'SELECT name FROM pragma_table_info(?)',
        [table],
      ))
        row['name'] as String,
    };

    expect(
      columns('friend_messages'),
      containsAll(['reply_to', 'reply_from', 'reply_body']),
    );
    expect(
      columns('friend_blocks'),
      containsAll(['blocker', 'blocked', 'blocked_name']),
    );
    expect(columns('friend_invites'), containsAll(['status', 'updated_ms']));
  });
}
