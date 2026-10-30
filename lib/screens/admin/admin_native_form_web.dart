import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:web/web.dart' as web;

import '../../../shared/admin_credentials.dart';
import 'admin_form_values.dart';

/// A real DOM form for the admin credentials.
///
/// This is deliberately not a Flutter [AutofillGroup]. On the web Flutter
/// paints text on a canvas and synthesises hidden `<input>` proxies; in the
/// engine shipped with Flutter 3.47 every non-focused proxy is zero-sized and
/// the connection drops when a password manager's popup takes focus. Managers
/// therefore cannot see — and cannot fill — the pair. A platform-view form
/// gives the browser and every extension the ordinary HTML contract they
/// already support, including the save prompt.
///
/// The form owns its validation so a bad email or a weak password is pointed
/// at the offending field instead of a card-level banner. The screen repeats
/// the same checks through [AdminFormValues] as a fallback for its VM form.
class AdminNativeForm extends StatefulWidget {
  const AdminNativeForm({
    super.key,
    required this.setup,
    required this.busy,
    required this.onSubmit,
  });

  /// First-run setup asks for a name, a confirmed password and the server's
  /// ADMIN_TOKEN as well.
  final bool setup;

  /// Disables the controls while the credential is being checked.
  final bool busy;

  final ValueChanged<AdminFormValues> onSubmit;

  @override
  State<AdminNativeForm> createState() => AdminNativeFormState();
}

class AdminNativeFormState extends State<AdminNativeForm> {
  web.HTMLFormElement? _form;
  web.HTMLInputElement? _email;
  web.HTMLInputElement? _name;
  web.HTMLInputElement? _password;
  web.HTMLInputElement? _confirm;
  web.HTMLInputElement? _token;
  web.HTMLSpanElement? _message;
  bool _saveOnly = false;

  /// Reads and validates the form, then hands the values to the screen. Used
  /// by the Flutter submit button and by Enter in the final field.
  void submit() {
    if (widget.busy) return;
    _emit();
  }

  /// Submits the real form after a successful sign-in so the browser offers
  /// to save the credential. The submit handler deliberately does not re-run
  /// the API call; it only lets the browser see the successful form.
  void save() {
    final form = _form;
    if (form == null) return;
    // The form is disabled while the request is in flight, and a disabled
    // password control is not a successful control: the browser would see a
    // submit with no credential in it. Enable the fields for the save submit;
    // the screen replaces itself with the dashboard immediately afterwards.
    _setBusy(false);
    _saveOnly = true;
    form.requestSubmit();
    _saveOnly = false;
  }

  @override
  Widget build(BuildContext context) {
    // Fixed heights so the Flutter card around the form does not jump while
    // the browser opens its password manager or the API answers. Fields are
    // 56 px with 12 px between them; the message line below them is 23 px.
    final height = widget.setup ? 352.0 : 148.0;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: HtmlElementView.fromTagName(
        tagName: 'form',
        onElementCreated: _onElementCreated,
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      ),
    );
  }

  @override
  void didUpdateWidget(AdminNativeForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.setup != widget.setup) _buildContents();
    if (oldWidget.busy != widget.busy) _setBusy(widget.busy);
  }

  void _onElementCreated(Object element) {
    final form = element as web.HTMLFormElement;
    _form = form;
    form
      ..className = 'gc-admin-form'
      ..noValidate = true;
    form.setAttribute('method', 'post');
    form.setAttribute('action', '#');
    form.setAttribute('autocomplete', 'on');
    form.setAttribute(
      'aria-label',
      widget.setup ? 'Create the admin account' : 'Admin sign in',
    );
    form.addEventListener(
      'submit',
      ((web.Event event) {
        event.preventDefault();
        if (!_saveOnly) _emit();
      }).toJS,
    );
    _buildContents();
  }

  void _buildContents() {
    final form = _form;
    if (form == null) return;
    // A refresh can flip setupRequired while the form is mounted. Rebuild the
    // fields for the new mode; the operator's half-typed values are dropped
    // on purpose rather than being posted to a different endpoint.
    form.textContent = '';
    form.append(web.HTMLStyleElement()..textContent = _css);

    final fields = web.HTMLDivElement()..className = 'gc-admin-fields';
    _email = _addField(
      fields,
      id: 'gc-admin-email',
      label: 'Email',
      type: 'email',
      autocomplete: 'username',
      icon: _iconEmail,
      maxLength: adminEmailMaxLength,
    );
    if (widget.setup) {
      _name = _addField(
        fields,
        id: 'gc-admin-name',
        label: 'Name (optional)',
        autocomplete: 'name',
        icon: _iconBadge,
      );
    }
    _password = _addField(
      fields,
      id: 'gc-admin-password',
      label: 'Password',
      type: 'password',
      autocomplete: widget.setup ? 'new-password' : 'current-password',
      icon: _iconLock,
      secret: true,
      maxLength: widget.setup ? adminPasswordMaxLength : null,
      minLength: widget.setup ? adminPasswordMinLength : null,
    );
    if (widget.setup) {
      // Password managers recognise the repeated `new-password` hint and fill
      // both fields with the same generated secret.
      _confirm = _addField(
        fields,
        id: 'gc-admin-confirm-password',
        label: 'Confirm password',
        type: 'password',
        autocomplete: 'new-password',
        icon: _iconLock,
        secret: true,
        maxLength: adminPasswordMaxLength,
        minLength: adminPasswordMinLength,
      );
      _token = _addField(
        fields,
        id: 'gc-admin-token',
        label: 'Setup token (server ADMIN_TOKEN)',
        type: 'password',
        autocomplete: 'off',
        icon: _iconKey,
        secret: true,
        ignoreManagers: true,
      );
    } else {
      _name = null;
      _confirm = null;
      _token = null;
    }
    form.append(fields);

    _message = web.HTMLSpanElement()..className = 'gc-admin-message';
    _message!
      ..setAttribute('role', 'status')
      ..setAttribute('aria-live', 'polite');
    form.append(_message!);
    _resetMessage();

    // Enter is routed here, not through the browser's default submit, so a
    // half-filled setup never posts and a failed sign-in never triggers the
    // save prompt. The hidden submit is the default button `requestSubmit`
    // uses after a successful auth.
    if (widget.setup) {
      _enterAdvances(_email, _name);
      _enterAdvances(_name, _password);
      _enterAdvances(_password, _confirm);
      _enterAdvances(_confirm, _token);
      _enterAdvances(_token, null);
    } else {
      _enterAdvances(_email, _password);
      _enterAdvances(_password, null);
    }
    final hidden = web.HTMLButtonElement()
      ..type = 'submit'
      ..className = 'gc-admin-hidden-submit'
      ..tabIndex = -1;
    hidden.setAttribute('aria-hidden', 'true');
    form.append(hidden);
    _setBusy(widget.busy);
  }

  List<web.HTMLInputElement?> get _inputs => [
    _email,
    _name,
    _password,
    _confirm,
    _token,
  ];

  void _resetMessage() {
    final message = _message;
    if (message == null) return;
    message.textContent = '';
    message.setAttribute('data-tone', 'none');
  }

  void _showError(String problem, web.HTMLInputElement? field) {
    final message = _message;
    if (message != null) {
      message.textContent = problem;
      message.setAttribute('data-tone', 'error');
    }
    for (final input in _inputs) {
      input?.classList.remove('gc-admin-invalid');
      input?.setAttribute('aria-invalid', 'false');
    }
    field?.classList.add('gc-admin-invalid');
    field?.setAttribute('aria-invalid', 'true');
    field?.focus();
  }

  void _onInput(web.HTMLInputElement input) {
    input.classList.remove('gc-admin-invalid');
    input.setAttribute('aria-invalid', 'false');
    final anyInvalid = _inputs.any(
      (candidate) => candidate?.classList.contains('gc-admin-invalid') ?? false,
    );
    if (!anyInvalid) _resetMessage();
  }

  void _enterAdvances(web.HTMLInputElement? input, web.HTMLInputElement? next) {
    if (input == null) return;
    input.addEventListener(
      'keydown',
      ((web.KeyboardEvent event) {
        if (event.key != 'Enter') return;
        event.preventDefault();
        if (next != null) {
          next.focus();
        } else {
          _emit();
        }
      }).toJS,
    );
  }

  web.HTMLInputElement _addField(
    web.HTMLDivElement parent, {
    required String id,
    required String label,
    String type = 'text',
    required String autocomplete,
    required String icon,
    bool secret = false,
    bool ignoreManagers = false,
    int? maxLength,
    int? minLength,
  }) {
    final wrap = web.HTMLDivElement()..className = 'gc-admin-field';
    wrap.append(
      web.HTMLSpanElement()
        ..className = 'gc-admin-icon'
        ..innerHTML = icon.toJS,
    );

    final input = web.HTMLInputElement()
      ..id = id
      ..name = id
      ..type = type
      ..placeholder = ' '
      ..className = 'gc-admin-input';
    input.setAttribute('autocomplete', autocomplete);
    input.setAttribute('autocapitalize', 'off');
    input.setAttribute('autocorrect', 'off');
    input.setAttribute('spellcheck', 'false');
    if (maxLength != null) input.setAttribute('maxlength', '$maxLength');
    if (minLength != null) input.setAttribute('minlength', '$minLength');
    if (ignoreManagers) {
      // This is an operator secret, not a login credential. Extensions that
      // understand these attributes leave it out of their fill plan; the
      // browser itself ignores the unknown `data-*` attributes.
      input.setAttribute('data-1p-ignore', 'true');
      input.setAttribute('data-lpignore', 'true');
      input.setAttribute('data-bwignore', 'true');
      input.setAttribute('data-protonpass-ignore', 'true');
    }
    if (secret) input.style.paddingRight = '60px';
    input.addEventListener('input', ((web.Event _) => _onInput(input)).toJS);
    wrap.append(input);
    wrap.append(
      web.HTMLLabelElement()
        ..htmlFor = id
        ..className = 'gc-admin-label'
        ..textContent = label,
    );

    if (secret) {
      final reveal = web.HTMLButtonElement()
        ..type = 'button'
        ..className = 'gc-admin-reveal';
      // The affordance everyone knows: an eye while the secret is hidden,
      // an eye-off once it is shown. The button carries the same
      // aria-label as before, so screen readers keep their words even
      // though the pixels are now a picture.
      reveal.innerHTML = _iconEye.toJS;
      reveal.setAttribute('aria-label', 'Show $label');
      reveal.addEventListener(
        'click',
        ((web.Event _) {
          final showing = input.type == 'text';
          input.type = showing ? 'password' : 'text';
          reveal.innerHTML = (showing ? _iconEye : _iconEyeOff).toJS;
          reveal.setAttribute(
            'aria-label',
            '${showing ? 'Show' : 'Hide'} $label',
          );
        }).toJS,
      );
      wrap.append(reveal);
    }

    parent.append(wrap);
    return input;
  }

  void _emit() {
    final values = AdminFormValues(
      email: _email?.value.trim() ?? '',
      name: _name?.value.trim() ?? '',
      password: _password?.value ?? '',
      confirmPassword: _confirm?.value ?? '',
      setupToken: _token?.value.trim() ?? '',
    );

    final checks = <(String?, web.HTMLInputElement?)>[
      (adminEmailProblem(values.email), _email),
      if (widget.setup) ...[
        (adminNewPasswordProblem(values.password), _password),
        (
          adminPasswordConfirmProblem(values.password, values.confirmPassword),
          _confirm,
        ),
        (
          values.setupToken.isEmpty ? 'Enter the server ADMIN_TOKEN.' : null,
          _token,
        ),
      ] else
        (adminSignInPasswordProblem(values.password), _password),
    ];
    for (final (problem, field) in checks) {
      if (problem != null) {
        _showError(problem, field);
        return;
      }
    }

    _resetMessage();
    for (final input in _inputs) {
      input?.classList.remove('gc-admin-invalid');
      input?.setAttribute('aria-invalid', 'false');
    }
    widget.onSubmit(values);
  }

  void _setBusy(bool busy) {
    for (final input in _inputs) {
      input?.disabled = busy;
    }
  }

  static const _css = '''
.gc-admin-form, .gc-admin-form * { box-sizing: border-box; }
.gc-admin-fields { display: flex; flex-direction: column; gap: 12px; }
.gc-admin-field { position: relative; height: 56px; }
.gc-admin-input {
  width: 100%; height: 56px; margin: 0;
  padding: 20px 14px 6px 44px;
  border: 1.5px solid rgba(217, 164, 65, 0.28);
  border-radius: 14px;
  background: #0F2E20;
  color: #F5EFE0;
  font: 500 14px/20px Manrope, system-ui, sans-serif;
  outline: none;
  transition: border-color .12s ease, box-shadow .12s ease;
}
.gc-admin-input:hover { border-color: rgba(217, 164, 65, 0.5); }
.gc-admin-input:focus {
  border-color: #D9A441;
  box-shadow: 0 0 0 3px rgba(217, 164, 65, 0.14);
}
.gc-admin-input:disabled { opacity: .6; }
.gc-admin-input.gc-admin-invalid {
  border-color: #D46A5E;
  box-shadow: 0 0 0 3px rgba(212, 106, 94, 0.14);
}
.gc-admin-input:-webkit-autofill {
  -webkit-text-fill-color: #F5EFE0;
  -webkit-box-shadow: 0 0 0 1000px #0F2E20 inset;
  caret-color: #F5EFE0;
}
.gc-admin-label {
  position: absolute; left: 44px; top: 50%;
  transform: translateY(-50%);
  color: #B5B3A2;
  font: 500 14px Manrope, system-ui, sans-serif;
  pointer-events: none;
  transition: top .12s ease, font-size .12s ease, color .12s ease,
    transform .12s ease;
}
.gc-admin-input:focus ~ .gc-admin-label,
.gc-admin-input:not(:placeholder-shown) ~ .gc-admin-label {
  top: 11px; transform: none;
  font-size: 10.5px; font-weight: 700; letter-spacing: .25px;
  color: #D9A441;
}
.gc-admin-icon {
  position: absolute; left: 14px; top: 50%;
  width: 20px; height: 20px; margin-top: -10px;
  color: #B5B3A2; pointer-events: none;
}
.gc-admin-field:focus-within .gc-admin-icon { color: #D9A441; }
.gc-admin-reveal {
  position: absolute; right: 4px; top: 50%;
  transform: translateY(-50%);
  min-width: 44px; height: 44px; padding: 0 10px;
  display: flex; align-items: center; justify-content: center;
  border: 0; border-radius: 10px;
  background: transparent;
  color: #B5B3A2;
  cursor: pointer;
}
.gc-admin-reveal:hover { color: #F5EFE0; background: rgba(217, 164, 65, .08); }
.gc-admin-message {
  display: block; min-height: 15px; margin-top: 8px; padding-left: 2px;
  color: #D46A5E;
  font: 600 11.5px/15px Manrope, system-ui, sans-serif;
}
.gc-admin-hidden-submit {
  position: absolute; left: -9999px; top: -9999px;
  width: 1px; height: 1px; padding: 0; border: 0;
}
''';

  static const _iconEmail =
      '<svg viewBox="0 0 24 24" width="20" height="20" fill="currentColor">'
      '<path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10h5v-2h-5c-4.34 0-8-3.66'
      '-8-8s3.66-8 8-8 8 3.66 8 8v1.43c0 .79-.71 1.57-1.5 1.57s-1.5-.78-1.5'
      '-1.57V12c0-2.76-2.24-5-5-5s-5 2.24-5 5 2.24 5 5 5c1.38 0 2.64-.56 3.54'
      '-1.47.65.89 1.77 1.47 2.96 1.47 1.97 0 3.5-1.6 3.5-3.57V12c0-5.52-4.48'
      '-10-10-10zm0 13c-1.66 0-3-1.34-3-3s1.34-3 3-3 3 1.34 3 3-1.34 3-3 3z"/>'
      '</svg>';
  static const _iconBadge =
      '<svg viewBox="0 0 24 24" width="20" height="20" fill="currentColor">'
      '<path d="M20 7h-5V4c0-1.1-.9-2-2-2h-2c-1.1 0-2 .9-2 2v3H4c-1.1 0-2 .9'
      '-2 2v11c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V9c0-1.1-.9-2-2-2zm-9-3h2v5h-2V4z'
      'm9 16H4V9h5v2h2V9h2v2h2V9h5v11z"/>'
      '</svg>';
  static const _iconLock =
      '<svg viewBox="0 0 24 24" width="20" height="20" fill="currentColor">'
      '<path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2'
      'v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9'
      '-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1'
      ' 1.71 0 3.1 1.39 3.1 3.1v2z"/>'
      '</svg>';
  static const _iconKey =
      '<svg viewBox="0 0 24 24" width="20" height="20" fill="currentColor">'
      '<path d="M21 10h-8.35C11.83 7.67 9.61 6 7 6c-3.31 0-6 2.69-6 6s2.69'
      ' 6 6 6c2.61 0 4.83-1.67 5.65-4H13l2 2 2-2 2 2 4-4.04L21 10zM7 15'
      'c-1.66 0-3-1.34-3-3s1.34-3 3-3 3 1.34 3 3-1.34 3-3 3z"/>'
      '</svg>';
  static const _iconEye =
      '<svg viewBox="0 0 24 24" width="20" height="20" fill="currentColor">'
      '<path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 '
      '11-7.5c-1.73-4.39-6-7.5-11-7.5zM12 17c-2.76 0-5-2.24-5-5s2.24-5 5-5 '
      '5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 '
      '3-3-1.34-3-3-3z"/>'
      '</svg>';
  static const _iconEyeOff =
      '<svg viewBox="0 0 24 24" width="20" height="20" fill="currentColor">'
      '<path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 '
      '2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25'
      '-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 '
      '8.3 1.78 10.03 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 '
      '4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21'
      '-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33'
      '-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm11.88 '
      '5.58L11.13 7.1c.29-.06.57-.1.87-.1l.01 0a5 5 0 0 1 5 5c0 .3-.04.58-.1.87z"/>'
      '</svg>';
}
