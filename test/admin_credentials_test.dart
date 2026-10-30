import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/shared/admin_credentials.dart';

void main() {
  group('adminEmailProblem', () {
    test('accepts a normal address and ignores surrounding space', () {
      expect(adminEmailProblem(' root@x.io '), isNull);
    });

    test('requires a local part, an @ and a dotted domain', () {
      expect(adminEmailProblem(''), 'Enter your email address.');
      expect(adminEmailProblem('root'), 'Enter a valid email address.');
      expect(adminEmailProblem('root@'), 'Enter a valid email address.');
      expect(adminEmailProblem('root@x'), 'Enter a valid email address.');
      expect(adminEmailProblem('root @x.io'), 'Enter a valid email address.');
      expect(adminEmailProblem('root@x.io'), isNull);
    });

    test('caps the address length', () {
      final local = 'a' * (adminEmailMaxLength - 6);
      expect(adminEmailProblem('$local@x.io'), isNull);
      expect(adminEmailProblem('$local@x.ioo'), isNull);
      expect(adminEmailProblem('$local@x.iooo'), 'That email is too long.');
    });
  });

  group('adminNewPasswordProblem', () {
    test('accepts letters, numbers and a symbol within the bounds', () {
      expect(adminNewPasswordProblem('long-enough-1'), isNull);
      expect(
        adminNewPasswordProblem('a1!${'x' * (adminPasswordMaxLength - 3)}'),
        isNull,
      );
    });

    test('rejects empty, short and overlong passwords', () {
      expect(adminNewPasswordProblem(''), 'Choose a password.');
      expect(
        adminNewPasswordProblem('a1!'),
        'Use at least $adminPasswordMinLength characters.',
      );
      expect(
        adminNewPasswordProblem('a1!${'x' * (adminPasswordMaxLength - 2)}'),
        'Use at most $adminPasswordMaxLength characters.',
      );
    });

    test('requires each character class', () {
      expect(adminNewPasswordProblem('12345678!'), 'Add at least one letter.');
      expect(
        adminNewPasswordProblem('alllettersonly'),
        'Add at least one number.',
      );
      expect(
        adminNewPasswordProblem('alllettersonly1'),
        'Add at least one symbol.',
      );
    });
  });

  test('confirmation must be present and match exactly', () {
    expect(
      adminPasswordConfirmProblem('long-enough-1', ''),
      'Confirm your password.',
    );
    expect(
      adminPasswordConfirmProblem('long-enough-1', 'long-enough-2'),
      'Passwords do not match.',
    );
    expect(
      adminPasswordConfirmProblem('long-enough-1', 'long-enough-1'),
      isNull,
    );
  });

  test('sign-in only checks that a password is present', () {
    expect(adminSignInPasswordProblem(''), 'Enter your password.');
    expect(adminSignInPasswordProblem('x'), isNull);
    expect(adminSignInPasswordProblem('hunter2hunter2'), isNull);
  });
}
