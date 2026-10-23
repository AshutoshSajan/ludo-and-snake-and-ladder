import 'package:flutter/material.dart';

import '../services/report_client.dart';
import '../ui/club_widgets.dart';
import '../ui/page_app_bar.dart';
import '../ui/shared/table_alert.dart';
import '../ui/theme.dart';

/// Contact page: a fuller-screen twin of the report sheet for players who
/// want to reach us outside a game — same endpoint, same queue, filed
/// with source 'contact' and a Question default so the admin tooling can
/// tell the lanes apart.
class ContactScreen extends StatefulWidget {
  const ContactScreen({super.key, required this.serverUrl});

  final String serverUrl;

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  static const _categories = <(String, String)>[
    ('question', 'Question'),
    ('bug', 'Bug'),
    ('feature', 'Feature request'),
    ('other', 'Other'),
  ];

  String _category = 'question';
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _message = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final message = _message.text.trim();
    if (message.isEmpty) {
      showTableAlert(
        context,
        'Write your message first',
        icon: Icons.edit_note,
      );
      return;
    }
    setState(() => _sending = true);
    final client = ReportClient(serverUrl: widget.serverUrl);
    try {
      await client.submit(
        category: _category,
        source: 'contact',
        title: _name.text.trim().isEmpty
            ? null
            : 'Message from ${_name.text.trim()}',
        message: message,
        contact: _email.text.trim(),
      );
      if (!mounted) return;
      // On the root overlay, so the confirmation outlives this screen.
      showTableAlert(
        context,
        'Message sent — we will get back to you.',
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
    return Scaffold(
      appBar: PageAppBar(title: 'Contact'),
      body: ClubBackground(
        child: SafeArea(
          child: ContentColumn(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              children: [
                const ClubCard(
                  accent: true,
                  padding: EdgeInsets.fromLTRB(17, 18, 17, 16),
                  child: ClubPageHeader(
                    eyebrow: 'The front desk',
                    title: 'We read everything',
                    icon: Icons.mail_outline,
                    subtitle:
                        'Questions, bug reports, feature ideas — it all lands '
                        'in the same inbox. Leave an email if you want a reply.',
                  ),
                ),
                const SizedBox(height: 14),
                ClubCard(
                  padding: const EdgeInsets.fromLTRB(18, 17, 18, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const ClubSectionLabel('What is this about?'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final (value, label) in _categories)
                            ChoiceChip(
                              label: Text(label),
                              selected: _category == value,
                              onSelected: (_) =>
                                  setState(() => _category = value),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _name,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Your name (optional)',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email (optional)',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _message,
                        maxLength: 4000,
                        maxLines: 6,
                        decoration: const InputDecoration(
                          labelText: 'Your message *',
                          alignLabelWithHint: true,
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: FilledButton(
                          onPressed: _sending ? null : _send,
                          child: _sending
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.paperLight,
                                  ),
                                )
                              : const Text('Send message'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const ClubNote(
                        'No account needed. We only use an email address to '
                        'answer you.',
                        icon: Icons.lock_outline,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
