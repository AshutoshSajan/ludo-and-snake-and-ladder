import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_router.dart';
import '../../app_routes.dart';
import '../../providers/app_providers.dart';
import '../../services/admin_client.dart';
import '../../services/server_url.dart';
import '../../shared/admin_credentials.dart';
import '../../ui/club_widgets.dart';
import '../../ui/theme.dart';
import 'admin_auth_mode.dart';
import 'admin_dashboard_screen.dart';
import 'admin_native_form.dart';

export 'admin_auth_mode.dart';

/// Admin sign-in at /admin: email + password (or the first-run setup that
/// creates the account, when the server says none exists). The session
/// token lives in memory only and rides as a Bearer header.
class AdminLoginScreen extends ConsumerStatefulWidget {
  const AdminLoginScreen({
    super.key,
    this.clientFactory,
    this.mode = AdminAuthMode.login,
  });

  /// Test seam: builds the client used for the status check and auth.
  /// Null in production, where the target is [defaultServerUrl].
  final AdminClient Function()? clientFactory;

  /// Login or first-run signup. Defaults to login, the safe always-valid
  /// mode: the server has an account or the answer is a redirect anyway.
  final AdminAuthMode mode;

  @override
  ConsumerState<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends ConsumerState<AdminLoginScreen> {
  final _emailCtrl = TextEditingController();  final _nameCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _setupTokenCtrl = TextEditingController();
  final _confirmFocus = FocusNode();
  final _setupTokenFocus = FocusNode();
  final _nativeForm = GlobalKey<AdminNativeFormState>();
  bool? _setupRequired;
  String? _error;
  bool _busy = false;
  bool _showPassword = false;
  bool _showConfirm = false;
  bool _showSetupToken = false;
  String? _emailError;
  String? _passwordError;
  String? _confirmError;
  String? _tokenError;

  // The admin page is web-only and same-origin with its server, so the
  // target is a build-time fact — the same rule the online lobby follows.
  // An edit box here invited pointing the back office at a foreign host.
  AdminClient get _client =>
      widget.clientFactory?.call() ??
      AdminClient(serverUrl: defaultServerUrl());

  bool get _modeSignup => widget.mode == AdminAuthMode.signup;

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
    _confirmCtrl.dispose();
    _setupTokenCtrl.dispose();
    _confirmFocus.dispose();
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
      final required = status['setupRequired'] as bool? ?? false;
      // The URL's mode and the server's state must agree before any form
      // is drawn: /admin/signup with an account already created and
      // /admin/login with none are both stale — one would invite a
      // stranger to create an admin or fight a server that wants a plain
      // sign-in. Move the tab to the URL that matches the truth instead.
      if (required != _modeSignup) {
        replaceAppScreen<void>(
          context,
          name: required ? AppRoutes.adminSignup : AppRoutes.adminLogin,
          builder: (_) => AdminLoginScreen(
            mode: required ? AdminAuthMode.signup : AdminAuthMode.login,
            clientFactory: widget.clientFactory,
          ),
        );
        return;
      }
      setState(() => _setupRequired = required);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not reach admin API: $e');
    }
  }

  Future<void> _submit() => _submitValues(
    AdminFormValues(
      email: _emailCtrl.text.trim(),
      name: _nameCtrl.text.trim(),
      password: _passCtrl.text,
      confirmPassword: _confirmCtrl.text,
      setupToken: _setupTokenCtrl.text.trim(),
    ),
  );

  Future<void> _submitValues(AdminFormValues values) async {
    final setup = _setupRequired == true;
    final email = values.email;
    final password = values.password;
    // The web form validates its own fields and only calls back with a clean
    // form; this pass is the Flutter fallback's validator and a second guard
    // for any caller. Both use the same shared rules, so the messages match.
    final emailProblem = adminEmailProblem(email);
    final passwordProblem = setup
        ? adminNewPasswordProblem(password)
        : adminSignInPasswordProblem(password);
    final confirmProblem = setup
        ? adminPasswordConfirmProblem(password, values.confirmPassword)
        : null;
    // First-run setup always requires the server's ADMIN_TOKEN (fail
    // closed): without it the server answers 403, so say so up front
    // instead of spending a round trip.
    final tokenProblem = setup && values.setupToken.isEmpty
        ? 'Enter the server ADMIN_TOKEN.'
        : null;
    if (emailProblem != null ||
        passwordProblem != null ||
        confirmProblem != null ||
        tokenProblem != null) {
      setState(() {
        _emailError = emailProblem;
        _passwordError = passwordProblem;
        _confirmError = confirmProblem;
        _tokenError = tokenProblem;
        _error = null;
      });
      return;
    }
    setState(() {
      _emailError = null;
      _passwordError = null;
      _confirmError = null;
      _tokenError = null;
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
          name: values.name,
          setupToken: values.setupToken.isEmpty ? null : values.setupToken,
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
    // the credential. The web form is a real <form>: submitting it lets the
    // browser's password manager see the same successful sign-in a plain HTML
    // page would. The Flutter fallback still has to finish its autofill
    // context explicitly. Both are no-ops when the other path is active.
    FocusManager.instance.primaryFocus?.unfocus();
    TextInput.finishAutofillContext();
    _nativeForm.currentState?.save();
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
                                    'Passwords need 8–60 characters with a '
                                    'letter, a number and a symbol. The setup '
                                    'token is the server’s ADMIN_TOKEN — '
                                    'required, and never stored by this screen.',
                              ),
                              const SizedBox(height: 14),
                            ],
                            // The web form is a real DOM <form> in a platform
                            // view: password managers cannot fill Flutter's
                            // zero-sized autofill proxies on the current web
                            // engine. The VM fallback below is what widget
                            // tests exercise; `/admin` only exists on web.
                            if (kIsWeb)
                              AdminNativeForm(
                                key: _nativeForm,
                                setup: setup,
                                busy: _busy,
                                onSubmit: _submitValues,
                              )
                            else ...[
                              TextField(
                                controller: _emailCtrl,
                                enabled: !_busy,
                                keyboardType: TextInputType.emailAddress,
                                autofillHints: const [AutofillHints.username],
                                contextMenuBuilder: _menuBuilder(secret: false),
                                textInputAction: TextInputAction.next,
                                onChanged: (_) {
                                  if (_emailError != null) {
                                    setState(() => _emailError = null);
                                  }
                                },
                                maxLength: adminEmailMaxLength,
                                decoration: InputDecoration(
                                  labelText: 'Email',
                                  errorText: _emailError,
                                  counterText: '',
                                  prefixIcon: const Icon(
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
                                // sign-in presents an existing one. The hint
                                // tells password managers which is which — the
                                // wrong hint invites them to fight the field
                                // (autofill-over-paste).
                                autofillHints: setup
                                    ? const [AutofillHints.newPassword]
                                    : const [AutofillHints.password],
                                contextMenuBuilder: _menuBuilder(secret: true),
                                maxLength: setup
                                    ? adminPasswordMaxLength
                                    : null,
                                onChanged: (_) {
                                  if (_passwordError != null) {
                                    setState(() => _passwordError = null);
                                  }
                                },
                                // Setup walks password → confirm → token
                                // explicitly: the Show buttons sit between the
                                // fields in default traversal order.
                                onEditingComplete: setup
                                    ? () {
                                        _passCtrl.clearComposing();
                                        _confirmFocus.requestFocus();
                                      }
                                    : null,
                                textInputAction: setup
                                    ? TextInputAction.next
                                    : TextInputAction.done,
                                decoration: InputDecoration(
                                  labelText: 'Password',
                                  errorText: _passwordError,
                                  helperText: setup
                                      ? '8–60 chars · letter · number · symbol'
                                      : null,
                                  counterText: '',
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
                                // setup it advances to the confirmation
                                // instead so a half-filled form is never sent.
                                onSubmitted: setup ? null : (_) => _submit(),
                              ),
                              if (setup) ...[
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _confirmCtrl,
                                  focusNode: _confirmFocus,
                                  enabled: !_busy,
                                  obscureText: !_showConfirm,
                                  enableInteractiveSelection: true,
                                  enableSuggestions: false,
                                  autocorrect: false,
                                  keyboardType: TextInputType.visiblePassword,
                                  autofillHints: const [
                                    AutofillHints.newPassword,
                                  ],
                                  contextMenuBuilder: _menuBuilder(
                                    secret: true,
                                  ),
                                  maxLength: adminPasswordMaxLength,
                                  onChanged: (_) {
                                    if (_confirmError != null) {
                                      setState(() => _confirmError = null);
                                    }
                                  },
                                  onEditingComplete: () {
                                    _confirmCtrl.clearComposing();
                                    _setupTokenFocus.requestFocus();
                                  },
                                  textInputAction: TextInputAction.next,
                                  decoration: InputDecoration(
                                    labelText: 'Confirm password',
                                    errorText: _confirmError,
                                    counterText: '',
                                    prefixIcon: const Icon(
                                      Icons.lock_outline,
                                      size: 20,
                                    ),
                                    suffixIcon: IconButton(
                                      tooltip: _showConfirm ? 'Hide' : 'Show',
                                      icon: Icon(
                                        _showConfirm
                                            ? Icons.visibility_off
                                            : Icons.visibility,
                                      ),
                                      onPressed: () => setState(
                                        () => _showConfirm = !_showConfirm,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
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
                                  contextMenuBuilder: _menuBuilder(
                                    secret: true,
                                  ),
                                  onChanged: (_) {
                                    if (_tokenError != null) {
                                      setState(() => _tokenError = null);
                                    }
                                  },
                                  textInputAction: TextInputAction.done,
                                  decoration: InputDecoration(
                                    labelText:
                                        'Setup token (server ADMIN_TOKEN)',
                                    errorText: _tokenError,
                                    prefixIcon: const Icon(
                                      Icons.key_outlined,
                                      size: 20,
                                    ),
                                    suffixIcon: IconButton(
                                      tooltip: _showSetupToken
                                          ? 'Hide'
                                          : 'Show',
                                      icon: Icon(
                                        _showSetupToken
                                            ? Icons.visibility_off
                                            : Icons.visibility,
                                      ),
                                      onPressed: () => setState(
                                        () =>
                                            _showSetupToken = !_showSetupToken,
                                      ),
                                    ),
                                  ),
                                  onSubmitted: (_) => _submit(),
                                ),
                              ],
                            ],
                            if (_error != null) ...[
                              const SizedBox(height: 16),
                              _AdminErrorNote(message: _error!),
                            ],
                            const SizedBox(height: 18),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: _busy
                                    ? null
                                    : kIsWeb
                                    ? () => _nativeForm.currentState?.submit()
                                    : _submit,
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
