import 'package:flutter/material.dart';

import '../../services/report_client.dart';
import '../theme.dart';
import 'table_alert.dart';

/// "Report an issue" sheet — the one form used everywhere a player can
/// file something: in-game app bar, Settings, and (with a different
/// [source]) the contact page. Category choices are the automation hook:
/// the server stores them verbatim so reports can be triaged/routed.
class BugReportSheet extends StatefulWidget {
  const BugReportSheet({
    super.key,
    required this.serverUrl,
    this.source = 'report',
    this.gameId,
    this.seatId,
  });

  /// Same-origin game server URL (ws(s)://host/ws), as passed by the
  /// screen that opened the sheet.
  final String serverUrl;
  final String source;

  /// Optional context from the playing screen — attached to the row so
  /// the admin can reproduce.
  final String? gameId;
  final String? seatId;

  /// Opens the sheet. Returns when it is dismissed.
  static Future<void> show(
    BuildContext context, {
    required String serverUrl,
    String source = 'report',
    String? gameId,
    String? seatId,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.feltLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => BugReportSheet(
        serverUrl: serverUrl,
        source: source,
        gameId: gameId,
        seatId: seatId,
      ),
    );
  }

  @override
  State<BugReportSheet> createState() => _BugReportSheetState();
}

class _BugReportSheetState extends State<BugReportSheet> {
  static const _categories = <(String, String)>[
    ('bug', 'Bug'),
    ('feature', 'Feature request'),
    ('question', 'Question'),
    ('other', 'Other'),
  ];

  String _category = 'bug';
  final _title = TextEditingController();
  final _message = TextEditingController();
  final _contact = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _title.dispose();
    _message.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final message = _message.text.trim();
    if (message.isEmpty) {
      showTableAlert(
        context,
        'Tell us what happened first',
        icon: Icons.edit_note,
      );
      return;
    }
    setState(() => _sending = true);
    final client = ReportClient(serverUrl: widget.serverUrl);
    try {
      await client.submit(
        category: _category,
        source: widget.source,
        title: _title.text.trim(),
        message: message,
        contact: _contact.text.trim(),
        gameId: widget.gameId,
        seatId: widget.seatId,
      );
      if (!mounted) return;
      // Speak on the app's corner before closing the sheet: the card lives
      // on the root overlay, so it survives the pop instead of vanishing
      // with the sheet's messenger.
      showTableAlert(
        context,
        'Report sent — thank you! We read every one.',
        icon: Icons.check_circle_outline,
      );
      Navigator.of(context).pop();
    } on ReportException catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      showTableAlert(context, e.toString(), icon: Icons.error_outline);
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      showTableAlert(
        context,
        'Could not reach the server',
        icon: Icons.cloud_off,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.bug_report, color: AppColors.gold),
                const SizedBox(width: 8),
                Text(
                  widget.source == 'contact'
                      ? 'Contact Game Club'
                      : 'Report an issue',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.ivory,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (value, label) in _categories)
                  ChoiceChip(
                    label: Text(label),
                    selected: _category == value,
                    selectedColor: AppColors.gold,
                    backgroundColor: AppColors.felt,
                    labelStyle: TextStyle(
                      color: _category == value
                          ? AppColors.ink
                          : AppColors.ivory,
                    ),
                    onSelected: (_) => setState(() => _category = value),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: 'Short summary (optional)',
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _message,
              maxLength: 4000,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'What happened? *',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _contact,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email to reach you (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _sending ? null : _submit,
              style: FilledButton.styleFrom(backgroundColor: AppColors.gold),
              child: _sending
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Send'),
            ),
          ],
        ),
      ),
    );
  }
}
