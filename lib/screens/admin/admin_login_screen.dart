import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_router.dart';
import '../../app_routes.dart';
import '../../providers/app_providers.dart';
import '../../services/admin_client.dart';
import '../../services/server_url.dart';
import '../../ui/club_widgets.dart';
import '../../ui/theme.dart';
import 'admin_dashboard_screen.dart';

/// Admin sign-in at /admin: email + password. On a fresh server the first
/// visit becomes a one-time setup that creates the admin account.
/// The session token lives in memory only and rides as a Bearer header.
class AdminLoginScreen extends ConsumerStatefulWidget {
  const AdminLoginScreen({super.key, this.clientFactory});

  /// Test seam: builds the client used for the status check and auth.
  /// Null in production, where the target is [defaultServerUrl].
  final AdminClient Function()? clientFactory;

  @override
  ConsumerState<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends ConsumerState<AdminLoginScreen> {
  final _emailCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _setupTokenCtrl = TextEditingController();
  final _setupTokenFocus = FocusNode();
  bool? _setupRequired;
  String? _error;
  bool _busy = false;
  bool _showPassword = false;
  bool _showSetupToken = false;

  // The admin page is web-only and same-origin with its server, so the
  // target is a build-time fact — the same rule the online lobby follows.
  // An edit box here invited pointing the back office at a foreign host.
  AdminClient get _client =>
      widget.clientFactory?.call() ??
      AdminClient(serverUrl: defaultServerUrl());

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _nameCtrl.dispose();
    _passCtrl.dispose();
    _setupTokenCtrl.dispose();
    _setupTokenFocus.dispose();
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
              onPressed: () =>
                  editableTextState.cutSelection(SelectionChangedCause.toolbar),
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
            onPressed: () =>
                editableTextState.pasteText(SelectionChangedCause.toolbar),
            type: ContextMenuButtonType.paste,
          ),
          ContextMenuButtonItem(
            onPressed: () =>
                editableTextState.selectAll(SelectionChangedCause.toolbar),
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
      setState(
        () => _setupRequired = status['setupRequired'] as bool? ?? false,
      );
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
    // Auth succeeded, so this is the moment the browser should offer to save
    // the credential. Unfocus first: the web engine only submits a form once
    // its focused input has gone dormant. The group's dispose action cancels
    // instead, so a failed or abandoned sign-in never prompts to save.
    FocusManager.instance.primaryFocus?.unfocus();
    TextInput.finishAutofillContext();
    final user = authed['user'] as Map? ?? {};
    ref
        .read(adminSessionProvider.notifier)
        .signIn(
          AdminSession(
            token: client.token ?? '',
            email: '${user['email'] ?? email}',
            name: '${user['name'] ?? ''}',
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
    final checking = _setupRequired == null && _error == null;
    return Scaffold(
      backgroundColor: AppColors.felt,
      appBar: AppBar(
        title: const Text('Back office'),
        backgroundColor: AppColors.felt,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Check server again',
            onPressed: _checkStatus,
          ),
        ],
      ),
      body: ClubBackground(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 470),
              // One AutofillGroup so password managers offer to fill (and save)
              // the email+password pair instead of fighting the form. Saving
              // is explicit after a successful auth; disposing the screen
              // cancels the context so abandoned forms stay unsaved.
              child: AutofillGroup(
                onDisposeAction: AutofillContextAction.cancel,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 40),
                  shrinkWrap: true,
                  children: [
                    const _AdminEyebrow('Game Club · Back office'),
                    const SizedBox(height: 8),
                    Text(
                      setup ? 'Open the first table' : 'Admin sign in',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(color: AppColors.ivory, height: 1.05),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      setup
                          ? 'No admin account exists yet. Create the first one '
                                'with the server’s ADMIN_TOKEN.'
                          : 'Sign in with the account that keeps this club '
                                'running.',
                      style: const TextStyle(
                        fontFamily: AppFonts.body,
                        color: AppColors.textSecondary,
                        fontSize: 13.5,
                        height: 1.55,
                      ),
                    ),
                    const SizedBox(height: 22),
                    if (checking)
                      const ClubCard(
                        padding: EdgeInsets.fromLTRB(18, 22, 18, 22),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: AppColors.gold,
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Checking the admin API…',
                                style: TextStyle(
                                  fontFamily: AppFonts.body,
                                  color: AppColors.textSecondary,
                                  fontSize: 13.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      ClubCard(
                        accent: true,
                        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (setup) ...[
                              _AdminNote(
                                icon: Icons.shield_outlined,
                                title: 'First-run setup',
                                body:
                                    'The setup token is the server’s '
                                    'ADMIN_TOKEN. It is required and is never '
                                    'stored by this screen.',
                              ),
                              const SizedBox(height: 14),
                            ],
                            TextField(
                              controller: _emailCtrl,
                              enabled: !_busy,
                              keyboardType: TextInputType.emailAddress,
                              autofillHints: const [AutofillHints.username],
                              contextMenuBuilder: _menuBuilder(secret: false),
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                labelText: 'Email',
                                prefixIcon: Icon(
                                  Icons.alternate_email,
                                  size: 20,
                                ),
                              ),
                            ),
                            if (setup) ...[
                              const SizedBox(height: 12),
                              TextField(
                                controller: _nameCtrl,
                                enabled: !_busy,
                                autofillHints: const [AutofillHints.name],
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: 'Name (optional)',
                                  prefixIcon: Icon(
                                    Icons.badge_outlined,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            TextField(
                              controller: _passCtrl,
                              enabled: !_busy,
                              obscureText: !_showPassword,
                              enableInteractiveSelection: true,
                              enableSuggestions: false,
                              autocorrect: false,
                              keyboardType: TextInputType.visiblePassword,
                              // A first-time setup creates the credential; a
                              // sign-in presents an existing one. The hint tells
                              // password managers which is which — the wrong hint
                              // invites them to fight the field
                              // (autofill-over-paste).
                              autofillHints: setup
                                  ? const [AutofillHints.newPassword]
                                  : const [AutofillHints.password],
                              contextMenuBuilder: _menuBuilder(secret: true),
                              // Setup advances to the token explicitly: the
                              // Show button sits between the two fields in
                              // default traversal order.
                              onEditingComplete: setup
                                  ? () {
                                      _passCtrl.clearComposing();
                                      _setupTokenFocus.requestFocus();
                                    }
                                  : null,
                              textInputAction: setup
                                  ? TextInputAction.next
                                  : TextInputAction.done,
                              decoration: InputDecoration(
                                labelText: 'Password',
                                prefixIcon: const Icon(
                                  Icons.lock_outline,
                                  size: 20,
                                ),
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
                              // Enter submits a sign-in; during first-run
                              // setup it advances to the setup token instead
                              // so a half-filled form is never sent.
                              onSubmitted: setup ? null : (_) => _submit(),
                            ),
                            if (setup) ...[
                              const SizedBox(height: 12),
                              TextField(
                                controller: _setupTokenCtrl,
                                focusNode: _setupTokenFocus,
                                enabled: !_busy,
                                obscureText: !_showSetupToken,
                                enableInteractiveSelection: true,
                                enableSuggestions: false,
                                autocorrect: false,
                                keyboardType: TextInputType.visiblePassword,
                                contextMenuBuilder: _menuBuilder(secret: true),
                                textInputAction: TextInputAction.done,
                                decoration: InputDecoration(
                                  labelText: 'Setup token (server ADMIN_TOKEN)',
                                  prefixIcon: const Icon(
                                    Icons.key_outlined,
                                    size: 20,
                                  ),
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
                              const SizedBox(height: 16),
                              _AdminErrorNote(message: _error!),
                            ],
                            const SizedBox(height: 18),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: _busy ? null : _submit,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (_busy) ...[
                                      const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: AppColors.darkInk,
                                        ),
                                      ),
                                      const SizedBox(width: 9),
                                    ],
                                    Text(
                                      _busy
                                          ? 'Checking…'
                                          : setup
                                          ? 'Create admin account'
                                          : 'Sign in',
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Sessions stay in memory. Closing this tab signs '
                              'you out.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: AppFonts.body,
                                color: AppColors.textMuted,
                                fontSize: 11.5,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small gold eyebrow shared by the two admin screens.
class _AdminEyebrow extends StatelessWidget {
  const _AdminEyebrow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontFamily: AppFonts.body,
        color: AppColors.gold,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.8,
      ),
    );
  }
}

/// A brass-tinted note for setup instructions.
class _AdminNote extends StatelessWidget {
  const _AdminNote({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.gold),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.ivory,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: const TextStyle(
                    fontFamily: AppFonts.body,
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A red-tinted, high-contrast error note with the fix implied by its text.
class _AdminErrorNote extends StatelessWidget {
  const _AdminErrorNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontFamily: AppFonts.body,
                color: AppColors.ivory,
                fontSize: 12.5,
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
