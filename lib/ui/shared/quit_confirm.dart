import 'package:flutter/material.dart';

/// The walk-out confirmation for a running game.
///
/// One dialog for every table: online leave flows reuse it with their own
/// wording (the seat is forfeited and the table is told), and local pause
/// menus ask before the back press or "Quit to home" ends a running match.
/// [Stay] and the confirm button keep the online dialog's weight so the
/// destructive action is visually the heavier one everywhere.
Future<bool> showQuitConfirm(
  BuildContext context, {
  required String content,
  String title = 'Quit the game?',
  String confirmLabel = 'Quit',
}) async {
  final sure = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Stay'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return sure ?? false;
}
