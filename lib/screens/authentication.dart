import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:chauffeur/services/firebase/driver_reminder_service.dart';
import 'package:chauffeur/widgets/driver_notification_session.dart';
import 'package:flutter/services.dart';
import 'package:chauffeur/services/firebase/fireAuth.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/screens/commande.dart';
import 'package:chauffeur/screens/driver_profile.dart';
import 'package:chauffeur/services/firebase/driver_profile_service.dart';

const _navy = Color(0xFF142536);
const _gold = Color(0xFFD5B477);

enum _Method { phone, email }

enum _EmailAction { signIn, createAccount, resetPassword }

class AuthenticationPage extends StatefulWidget {
  const AuthenticationPage({
    super.key,
    required this.auth,
    this.onAuthenticated,
  });

  final Fireauth auth;
  final VoidCallback? onAuthenticated;

  @override
  State<AuthenticationPage> createState() => _AuthenticationPageState();
}

class _AuthenticationPageState extends State<AuthenticationPage> {
  final _form = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passwordConfirmation = TextEditingController();
  final _code = TextEditingController();
  var _method = _Method.phone;
  var _emailAction = _EmailAction.signIn;
  var _hidePassword = true;
  var _busy = false;
  var _codeSent = false;
  String? _error;
  String? _notice;
  String _sentPhone = '';
  StreamSubscription<User?>? _authSubscription;
  var _authenticationHandled = false;

  @override
  void initState() {
    super.initState();
    if (widget.onAuthenticated != null) {
      _authSubscription = widget.auth.authStateChanges().listen((user) {
        if (user != null) _onAuthenticated();
      });
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    widget.auth.cancelPhoneVerification();
    _phone.dispose();
    _email.dispose();
    _password.dispose();
    _passwordConfirmation.dispose();
    _code.dispose();
    super.dispose();
  }

  void _onError(FirebaseAuthException error) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = Fireauth.errorMessage(error);
    });
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      if (_method == _Method.email) {
        switch (_emailAction) {
          case _EmailAction.signIn:
            await widget.auth.signIn(_email.text, _password.text);
          case _EmailAction.createAccount:
            await widget.auth.createAccount(_email.text, _password.text);
          case _EmailAction.resetPassword:
            try {
              await widget.auth.resetPassword(_email.text);
            } on FirebaseAuthException catch (error) {
              if (error.code != 'user-not-found') rethrow;
            }
            if (!mounted) return;
            setState(() {
              _busy = false;
              _notice =
                  'Si un compte correspond à cet email, un lien de réinitialisation '
                  'vous sera envoyé. Vérifiez aussi vos courriers indésirables.';
            });
            return;
        }
      } else if (_codeSent) {
        await widget.auth.verifyPhoneCode(_code.text.trim());
      } else {
        _sentPhone = _phone.text.replaceAll(RegExp(r'[\s().-]'), '');
        await widget.auth.sendPhoneCode(
          _sentPhone,
          onCodeSent: () {
            if (!mounted) return;
            setState(() {
              _codeSent = true;
              _busy = false;
            });
          },
          onVerified: () {
            _onAuthenticated();
          },
          onError: _onError,
        );
        return;
      }
      _onAuthenticated();
    } on FirebaseAuthException catch (error) {
      _onError(error);
    } on UnsupportedError {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error =
            'La connexion par téléphone n’est pas disponible '
            'sur cette plateforme. Utilisez l’email.';
      });
    }
  }

  void _selectEmailAction(_EmailAction action) {
    _form.currentState!.reset();
    widget.auth.cancelPhoneVerification();
    _password.clear();
    _passwordConfirmation.clear();
    setState(() {
      _method = _Method.email;
      _emailAction = action;
      _codeSent = false;
      _hidePassword = true;
      _error = null;
      _notice = null;
    });
  }

  void _onAuthenticated() {
    if (!mounted || _authenticationHandled) return;
    _authenticationHandled = true;
    setState(() => _busy = false);
    widget.onAuthenticated?.call();
  }

  InputDecoration _decoration(
    String label,
    String hint,
    IconData icon, {
    Widget? suffix,
  }) => InputDecoration(
    labelText: label,
    hintText: hint,
    prefixIcon: Icon(icon, size: 21),
    suffixIcon: suffix,
    filled: true,
    fillColor: const Color(0xFFF5F7F9),
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: Color(0xFFE2E7EC)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final isPhone = _method == _Method.phone;
    final isCreating = !isPhone && _emailAction == _EmailAction.createAccount;
    final isResetting = !isPhone && _emailAction == _EmailAction.resetPassword;
    return Scaffold(
      backgroundColor: _navy,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - 64).clamp(
                  0,
                  double.infinity,
                ),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.35),
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Image.asset(
                          'assets/images/pro_du_transport.png',
                          width: 320,
                          fit: BoxFit.contain,
                          semanticLabel: 'Pro du Transport',
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'ESPACE CHAUFFEUR',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Votre prochain trajet commence ici.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xFFB7C3CF)),
                      ),
                      const SizedBox(height: 32),
                      Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(
                          constraints.maxWidth < 380 ? 20 : 32,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 32,
                              offset: const Offset(0, 12),
                            ),
                          ],
                        ),
                        child: Form(
                          key: _form,
                          child: AutofillGroup(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _codeSent
                                      ? 'Vérifiez votre numéro'
                                      : isCreating
                                      ? 'Créer un compte'
                                      : isResetting
                                      ? 'Mot de passe oublié'
                                      : 'Bienvenue à bord',
                                  style: const TextStyle(
                                    color: _navy,
                                    fontSize: 28,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _codeSent
                                      ? 'Saisissez le code envoyé au $_sentPhone.'
                                      : isCreating
                                      ? 'Créez votre accès puis complétez votre profil chauffeur.'
                                      : isResetting
                                      ? 'Recevez un lien pour choisir un nouveau mot de passe.'
                                      : 'Connectez-vous à votre espace personnel.',
                                  style: const TextStyle(
                                    color: Color(0xFF687787),
                                    height: 1.5,
                                  ),
                                ),
                                const SizedBox(height: 28),
                                if (!_codeSent) ...[
                                  SizedBox(
                                    width: double.infinity,
                                    child: SegmentedButton<_Method>(
                                      segments: const [
                                        ButtonSegment(
                                          value: _Method.phone,
                                          icon: Icon(Icons.phone_outlined),
                                          label: Text('Téléphone'),
                                        ),
                                        ButtonSegment(
                                          value: _Method.email,
                                          icon: Icon(
                                            Icons.mail_outline_rounded,
                                          ),
                                          label: Text('Email'),
                                        ),
                                      ],
                                      selected: {_method},
                                      showSelectedIcon: false,
                                      style: SegmentedButton.styleFrom(
                                        selectedBackgroundColor: _navy,
                                        selectedForegroundColor: Colors.white,
                                        foregroundColor: _navy,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 14,
                                        ),
                                      ),
                                      onSelectionChanged: _busy
                                          ? null
                                          : (selection) {
                                              widget.auth
                                                  .cancelPhoneVerification();
                                              _form.currentState!.reset();
                                              setState(() {
                                                _method = selection.single;
                                                _emailAction =
                                                    _EmailAction.signIn;
                                                _error = null;
                                                _notice = null;
                                              });
                                            },
                                    ),
                                  ),
                                  const SizedBox(height: 28),
                                ],
                                if (_codeSent)
                                  TextFormField(
                                    key: const ValueKey('sms-code'),
                                    controller: _code,
                                    enabled: !_busy,
                                    keyboardType: TextInputType.number,
                                    textInputAction: TextInputAction.done,
                                    autofillHints: const [
                                      AutofillHints.oneTimeCode,
                                    ],
                                    inputFormatters: [
                                      FilteringTextInputFormatter.digitsOnly,
                                      LengthLimitingTextInputFormatter(6),
                                    ],
                                    decoration: _decoration(
                                      'Code SMS',
                                      '123456',
                                      Icons.sms_outlined,
                                    ),
                                    validator: (value) =>
                                        RegExp(r'^\d{6}$').hasMatch(value ?? '')
                                        ? null
                                        : 'Saisissez le code à 6 chiffres.',
                                    onFieldSubmitted: (_) => _submit(),
                                  )
                                else if (isPhone)
                                  TextFormField(
                                    key: const ValueKey('phone'),
                                    controller: _phone,
                                    enabled: !_busy,
                                    keyboardType: TextInputType.phone,
                                    textInputAction: TextInputAction.done,
                                    autofillHints: const [
                                      AutofillHints.telephoneNumber,
                                    ],
                                    decoration: _decoration(
                                      'Numéro de téléphone',
                                      '+33 6 12 34 56 78',
                                      Icons.phone_outlined,
                                    ),
                                    validator: (value) {
                                      final phone = (value ?? '').replaceAll(
                                        RegExp(r'[\s().-]'),
                                        '',
                                      );
                                      return RegExp(r'^\+[1-9]\d{7,14}$')
                                              .hasMatch(phone)
                                          ? null
                                          : 'Indiquez un numéro avec indicatif pays (+33…).';
                                    },
                                    onFieldSubmitted: (_) => _submit(),
                                  )
                                else ...[
                                  TextFormField(
                                    key: const ValueKey('email'),
                                    controller: _email,
                                    enabled: !_busy,
                                    keyboardType: TextInputType.emailAddress,
                                    textInputAction: isResetting
                                        ? TextInputAction.done
                                        : TextInputAction.next,
                                    autofillHints: const [
                                      AutofillHints.username,
                                    ],
                                    autocorrect: false,
                                    decoration: _decoration(
                                      'Adresse email',
                                      'vous@exemple.com',
                                      Icons.mail_outline_rounded,
                                    ),
                                    validator: (value) =>
                                        RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                            .hasMatch((value ?? '').trim())
                                        ? null
                                        : 'Saisissez une adresse email valide.',
                                    onFieldSubmitted: isResetting
                                        ? (_) => _submit()
                                        : null,
                                  ),
                                  if (!isResetting) ...[
                                    const SizedBox(height: 18),
                                    TextFormField(
                                      key: const ValueKey('password'),
                                      controller: _password,
                                      enabled: !_busy,
                                      obscureText: _hidePassword,
                                      autocorrect: false,
                                      enableSuggestions: false,
                                      textInputAction: isCreating
                                          ? TextInputAction.next
                                          : TextInputAction.done,
                                      autofillHints: [
                                        isCreating
                                            ? AutofillHints.newPassword
                                            : AutofillHints.password,
                                      ],
                                      decoration: _decoration(
                                        'Mot de passe',
                                        'Votre mot de passe',
                                        Icons.lock_outline_rounded,
                                        suffix: IconButton(
                                          tooltip: _hidePassword
                                              ? 'Afficher le mot de passe'
                                              : 'Masquer le mot de passe',
                                          onPressed: () => setState(
                                            () =>
                                                _hidePassword = !_hidePassword,
                                          ),
                                          icon: Icon(
                                            _hidePassword
                                                ? Icons.visibility_outlined
                                                : Icons.visibility_off_outlined,
                                          ),
                                        ),
                                      ),
                                      validator: (value) {
                                        if (value == null || value.isEmpty) {
                                          return 'Saisissez votre mot de passe.';
                                        }
                                        if (isCreating && value.length < 6) {
                                          return 'Utilisez au moins 6 caractères.';
                                        }
                                        return null;
                                      },
                                      onFieldSubmitted: (_) => _submit(),
                                    ),
                                    if (isCreating) ...[
                                      const SizedBox(height: 18),
                                      TextFormField(
                                        key: const ValueKey(
                                          'password-confirmation',
                                        ),
                                        controller: _passwordConfirmation,
                                        enabled: !_busy,
                                        obscureText: _hidePassword,
                                        autocorrect: false,
                                        enableSuggestions: false,
                                        autofillHints: const [
                                          AutofillHints.newPassword,
                                        ],
                                        textInputAction: TextInputAction.done,
                                        decoration: _decoration(
                                          'Confirmer le mot de passe',
                                          'Retapez votre mot de passe',
                                          Icons.lock_outline_rounded,
                                        ),
                                        validator: (value) =>
                                            value == _password.text ? null : 'Les mots de passe ne correspondent pas.',
                                        onFieldSubmitted: (_) => _submit(),
                                      ),
                                    ],
                                  ],
                                ],
                                const SizedBox(height: 16),
                                if (isPhone && !_codeSent)
                                  const Text(
                                    'Un code SMS vous sera envoyé pour vous connecter.',
                                    style: TextStyle(
                                      color: Color(0xFF687787),
                                      fontSize: 12,
                                      height: 1.5,
                                    ),
                                  ),
                                if (_error != null)
                                  Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      _error!,
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error,
                                        height: 1.5,
                                      ),
                                    ),
                                  ),
                                if (_notice != null)
                                  Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      _notice!,
                                      style: const TextStyle(
                                        color: _navy,
                                        height: 1.5,
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 24),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                    onPressed: _busy ? null : _submit,
                                    style: FilledButton.styleFrom(
                                      backgroundColor: _gold,
                                      foregroundColor: _navy,
                                      padding: const EdgeInsets.all(18),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                    ),
                                    child: _busy
                                        ? const SizedBox(
                                            width: 22,
                                            height: 22,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              semanticsLabel:
                                                  'Connexion en cours',
                                            ),
                                          )
                                        : Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  isCreating
                                                      ? 'Créer mon compte'
                                                      : isResetting
                                                      ? 'Envoyer le lien'
                                                      : _codeSent || !isPhone
                                                      ? 'Se connecter'
                                                      : 'Recevoir un code',
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 16,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              const Icon(
                                                Icons.arrow_forward_rounded,
                                                size: 20,
                                              ),
                                            ],
                                          ),
                                  ),
                                ),
                                if (!_codeSent) ...[
                                  if (!isPhone &&
                                      _emailAction == _EmailAction.signIn)
                                    Center(
                                      child: TextButton(
                                        onPressed: _busy
                                            ? null
                                            : () => _selectEmailAction(
                                                _EmailAction.resetPassword,
                                              ),
                                        child: const Text(
                                          'Mot de passe oublié ?',
                                        ),
                                      ),
                                    ),
                                  Center(
                                    child: TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _selectEmailAction(
                                              isCreating || isResetting
                                                  ? _EmailAction.signIn
                                                  : _EmailAction.createAccount,
                                            ),
                                      child: Text(
                                        isCreating || isResetting
                                            ? 'Retour à la connexion'
                                            : 'Créer un compte',
                                      ),
                                    ),
                                  ),
                                ],
                                if (_codeSent)
                                  Center(
                                    child: TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () {
                                              _form.currentState!.reset();
                                              widget.auth
                                                  .cancelPhoneVerification();
                                              _code.clear();
                                              setState(() {
                                                _codeSent = false;
                                                _error = null;
                                              });
                                            },
                                      child: const Text(
                                        'Modifier le numéro / renvoyer un code',
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'L’élégance du trajet. La simplicité de la connexion.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFFB7C3CF),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AuthenticationGate extends StatelessWidget {
  const AuthenticationGate({
    super.key,
    required this.auth,
    this.ordersService,
    this.reminderService,
    this.profileService,
  });

  final Fireauth auth;
  final FireService? ordersService;
  final DriverReminderService? reminderService;
  final DriverProfileService? profileService;

  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
    stream: auth.authStateChanges(),
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return const Scaffold(
          body: Center(
            child: Text('Impossible de récupérer la session Firebase.'),
          ),
        );
      }
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      final user = snapshot.data;
      if (user == null) {
        return AuthenticationPage(auth: auth);
      }
      return DriverProfileGate(
        key: ValueKey(user.uid),
        driverId: user.uid,
        initialName: user.displayName,
        initialPhone: user.phoneNumber,
        service: profileService ?? DriverProfileService(),
        onSignOut: () => auth.signOut(),
        child: reminderService != null
            ? DriverNotificationSession(
                key: ValueKey(user.uid),
                driverId: user.uid,
                reminders: reminderService!,
                orders: ordersService,
                onSignOut: () => auth.signOut(),
              )
            : CommandePage(
                key: ValueKey(user.uid),
                driverId: user.uid,
                service: ordersService,
                onSignOut: () async {
                  try {
                    await auth.signOut();
                  } on FirebaseAuthException catch (error) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(Fireauth.errorMessage(error))),
                    );
                  }
                },
              ),
      );
    },
  );
}
