import 'package:flutter/material.dart';

import '../services/report_client.dart';
import '../ui/page_app_bar.dart';
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
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Write your message first')));
      return;
    }
    setState(() => _sending = true);
    final client = ReportClient(serverUrl: widget.serverUrl);
    try {
      await client.submit(
        category: _category,
        source: 'contact',
        title: _name.text.trim().isEmpty ? null : 'Message from ${_name.text.trim()}',
        message: message,
        contact: _email.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Message sent — we will get back to you.'),
          ),
        );
      Navigator.of(context).pop();
    } on ReportException catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.toString())));
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Could not reach the server')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PageAppBar(title: 'Contact'),
      backgroundColor: AppColors.felt,
      body: ContentColumn(
        child: ListView(
          children: [
            const SizedBox(height: 8),
            const Card(
              child: ListTile(
                leading: Icon(Icons.mail_outline, color: AppColors.gold),
                title: Text('We read everything'),
                subtitle: Text(
                  'Questions, bug reports, feature ideas — it all lands in '
                  'the same inbox. Leave an email if you want a reply.',
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'What is this about?',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (value, label) in _categories)
                  ChoiceChip(
                    label: Text(label),
                    selected: _category == value,
                    selectedColor: AppColors.gold,
                    backgroundColor: AppColors.feltLight,
                    labelStyle: TextStyle(
                      color:
                          _category == value ? AppColors.ink : AppColors.ivory,
                    ),
                    onSelected: (_) => setState(() => _category = value),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Your name (optional)',
                border: OutlineInputBorder(),
                fillColor: AppColors.feltLight,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email (optional)',
                border: OutlineInputBorder(),
                fillColor: AppColors.feltLight,
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
                border: OutlineInputBorder(),
                fillColor: AppColors.feltLight,
                counterText: '',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _sending ? null : _send,
              style: FilledButton.styleFrom(backgroundColor: AppColors.gold),
              child: _sending
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Send message'),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
