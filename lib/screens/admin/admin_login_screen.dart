import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
          403 => 'Setup already complete — sign in instead.',
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
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => AdminDashboardScreen(client: client),
      ),
    );
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
                      'If ADMIN_TOKEN is set on the server, paste it below.',
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
                    autofillHints: const [AutofillHints.password],
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
                      decoration: InputDecoration(
                        labelText: 'Setup token (ADMIN_TOKEN, if set)',
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
