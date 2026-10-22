import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_router.dart';
import '../../app_routes.dart';
import '../../providers/app_providers.dart';
import '../../services/admin_client.dart';
import '../../ui/theme.dart';
import '../online_lobby_screen.dart';
import 'admin_dashboard_screen.dart';

/// Admin sign-in at /admin: email + password. On a fresh server the first
/// visit becomes a one-time setup that creates the admin account.
/// The session token lives in memory only and rides as a Bearer header.
class AdminLoginScreen extends ConsumerStatefulWidget {
  const AdminLoginScreen({super.key});

  @override
  ConsumerState<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends ConsumerState<AdminLoginScreen> {
  late final TextEditingController _serverCtrl;
  final _emailCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _setupTokenCtrl = TextEditingController();
  bool? _setupRequired;
  String? _error;
  bool _busy = false;
  bool _showPassword = false;
  bool _showSetupToken = false;

  AdminClient get _client => AdminClient(serverUrl: _serverCtrl.text.trim());

  @override
  void initState() {
    super.initState();
    _serverCtrl = TextEditingController(
      text: OnlineLobbyScreen.defaultServerUrl(),
    );
    _checkStatus();
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _emailCtrl.dispose();
    _nameCtrl.dispose();
    _passCtrl.dispose();
    _setupTokenCtrl.dispose();
    super.dispose();
  }

  /// Text-selection menu with an explicit Paste entry.
  ///
  /// Ctrl+V / Cmd+V is delivered by the browser straight to the engine's
  /// backing input and normally needs no help. But the right-click /
  /// long-press menu is assembled by the framework, and on some
  /// Chrome + password-field combinations it comes up with no Paste entry —
  /// leaving mouse users with no way to paste at all. Building the menu
  /// ourselves guarantees the entry exists; Paste goes through
  /// [EditableTextState.pasteText], a different path from the native
  /// keystroke, so one working does not depend on the other. Cut/Copy are
  /// omitted for secrets, as is customary for password fields.
  EditableTextContextMenuBuilder _menuBuilder({required bool secret}) {
    return (BuildContext context, EditableTextState editableTextState) {
      final selecting =
          editableTextState.currentTextEditingValue.selection.isValid &&
          !editableTextState.currentTextEditingValue.selection.isCollapsed;
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: editableTextState.contextMenuAnchors,
        buttonItems: [
          if (!secret && selecting)
            ContextMenuButtonItem(
              onPressed: () => editableTextState.cutSelection(
                SelectionChangedCause.toolbar,
              ),
              type: ContextMenuButtonType.cut,
            ),
          if (!secret && selecting)
            ContextMenuButtonItem(
              onPressed: () => editableTextState.copySelection(
                SelectionChangedCause.toolbar,
              ),
              type: ContextMenuButtonType.copy,
            ),
          ContextMenuButtonItem(
            onPressed: () => editableTextState.pasteText(
              SelectionChangedCause.toolbar,
            ),
            type: ContextMenuButtonType.paste,
          ),
          ContextMenuButtonItem(
            onPressed: () => editableTextState.selectAll(
              SelectionChangedCause.toolbar,
            ),
            type: ContextMenuButtonType.selectAll,
          ),
        ],
      );
    };
  }

  Future<void> _checkStatus() async {
    try {
      final status = await _client.status();
      if (!mounted) return;
      setState(() => _setupRequired = status['setupRequired'] as bool? ?? false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not reach admin API: $e');
    }
  }

  Future<void> _submit() async {
    final email = _emailCtrl.text.trim();
    final password = _passCtrl.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter email and password.');
      return;
    }
    // First-run setup always requires the server's ADMIN_TOKEN (fail
    // closed): without it the server answers 403, so say so up front
    // instead of spending a round trip.
    if (_setupRequired == true && _setupTokenCtrl.text.trim().isEmpty) {
      setState(
        () => _error =
            'A setup token is required — copy ADMIN_TOKEN from the server.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final client = _client;
    Map<String, dynamic> authed;
    try {
      if (_setupRequired == true) {
        authed = await client.setup(
          email: email,
          password: password,
          name: _nameCtrl.text.trim(),
          setupToken: _setupTokenCtrl.text.trim().isEmpty
              ? null
              : _setupTokenCtrl.text.trim(),
        );
      } else {
        authed = await client.login(email: email, password: password);
      }
    } on AdminException catch (e) {
      setState(() {
        _busy = false;
        _error = switch (e.statusCode) {
          401 => 'Invalid email or password.',
          // 403 has three distinct server reasons (already set up / bad
          // setup token / setup disabled with no ADMIN_TOKEN) — show the
          // server's own text instead of guessing.
          403 => _serverRefusal(e),
          429 => 'Too many attempts — wait a minute.',
          _ => 'Could not reach admin API (HTTP ${e.statusCode}).',
        };
      });
      return;
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not reach admin API: $e';
      });
      return;
    }
    if (!mounted) return;
    final user = authed['user'] as Map? ?? {};
    ref
        .read(adminSessionProvider.notifier)
        .signIn(
          AdminSession(
            token: client.token ?? '',
            email: '${user['email'] ?? email}',
            name: '${user['name'] ?? ''}',
            serverUrl: _serverCtrl.text.trim(),
          ),
        );
    replaceAppScreen<void>(
      context,
      name: AppRoutes.adminDashboard,
      builder: (_) => AdminDashboardScreen(client: client),
    );
  }

  /// The server's own refusal text for 403s (setup already complete, bad
  /// setup token, or setup disabled). Falls back to a generic line when the
  /// body is not the expected JSON.
  String _serverRefusal(AdminException e) {
    try {
      final text = (jsonDecode(e.body) as Map)['text'];
      if (text is String && text.isNotEmpty) return text;
    } catch (_) {}
    return 'Setup refused (HTTP ${e.statusCode}).';
  }

  @override
  Widget build(BuildContext context) {
    final setup = _setupRequired ?? false;
    return Scaffold(
      backgroundColor: AppColors.felt,
      appBar: AppBar(
        title: Text(setup ? 'Admin setup' : 'Admin sign in'),
        backgroundColor: AppColors.feltLight,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          // One AutofillGroup so password managers offer to fill (and save)
          // the email+password pair instead of fighting the form.
          child: AutofillGroup(
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                if (_setupRequired == null && _error == null)
                  const Center(child: CircularProgressIndicator())
                else ...[
                  if (setup)
                    const Text(
                      'No admin account exists yet — create the first one. '
                      'Paste the server\'s ADMIN_TOKEN below (required).',
                      style: TextStyle(
                        color: AppColors.ivoryDark,
                        fontSize: 13,
                      ),
                    ),
                  TextField(
                    controller: _serverCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Server WS URL',
                    ),
                    onChanged: (_) => _checkStatus(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.username],
                    contextMenuBuilder: _menuBuilder(secret: false),
                    decoration: const InputDecoration(labelText: 'Email'),
                    onSubmitted: (_) => _submit(),
                  ),
                  if (setup) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Name (optional)',
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passCtrl,
                    obscureText: !_showPassword,
                    enableInteractiveSelection: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    keyboardType: TextInputType.visiblePassword,
                    // A first-time setup creates the credential; a sign-in
                    // presents an existing one. The hint tells password
                    // managers which is which — the wrong hint invites them
                    // to fight the field (autofill-over-paste).
                    autofillHints: setup
                        ? const [AutofillHints.newPassword]
                        : const [AutofillHints.password],
                    contextMenuBuilder: _menuBuilder(secret: true),
                    onEditingComplete: TextInput.finishAutofillContext,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      suffixIcon: IconButton(
                        tooltip: _showPassword ? 'Hide' : 'Show',
                        icon: Icon(
                          _showPassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () => setState(
                          () => _showPassword = !_showPassword,
                        ),
                      ),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  if (setup) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _setupTokenCtrl,
                      obscureText: !_showSetupToken,
                      enableInteractiveSelection: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      keyboardType: TextInputType.visiblePassword,
                      contextMenuBuilder: _menuBuilder(secret: true),
                      decoration: InputDecoration(
                        labelText: 'Setup token (server ADMIN_TOKEN)',
                        suffixIcon: IconButton(
                          tooltip: _showSetupToken ? 'Hide' : 'Show',
                          icon: Icon(
                            _showSetupToken
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () => setState(
                            () => _showSetupToken = !_showSetupToken,
                          ),
                        ),
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: const TextStyle(color: AppColors.danger),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: Text(
                      _busy
                          ? 'Checking…'
                          : setup
                              ? 'Create admin account'
                              : 'Sign in',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
