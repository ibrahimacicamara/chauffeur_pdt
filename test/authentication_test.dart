import 'dart:async';

import 'package:chauffeur/screens/authentication.dart';
import 'package:chauffeur/services/firebase/fireAuth.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/services/firebase/driver_profile_service.dart';
import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestAuth extends Fireauth {
  String? phone;
  String? email;
  String? password;
  String? code;
  String? createdEmail;
  String? createdPassword;
  String? resetEmail;
  FirebaseAuthException? failure;

  @override
  Stream<User?> authStateChanges() => const Stream.empty();

  @override
  Future<void> createAccount(String email, String password) async {
    createdEmail = email;
    createdPassword = password;
    if (failure != null) throw failure!;
  }

  @override
  Future<void> resetPassword(String email) async {
    resetEmail = email;
    if (failure != null) throw failure!;
  }

  @override
  Future<void> signIn(String email, String password) async {
    this.email = email;
    this.password = password;
    if (failure != null) throw failure!;
  }

  @override
  Future<void> sendPhoneCode(
    String phone, {
    required VoidCallback onCodeSent,
    required VoidCallback onVerified,
    required void Function(FirebaseAuthException error) onError,
  }) async {
    this.phone = phone;
    onCodeSent();
  }

  @override
  Future<void> verifyPhoneCode(String code) async {
    this.code = code;
    if (failure != null) throw failure!;
  }
}

class _SessionAuth extends _TestAuth {
  final sessions = StreamController<User?>.broadcast();

  @override
  Stream<User?> authStateChanges() => sessions.stream;

  @override
  Future<void> signOut() async => sessions.add(null);
}

class _TestUser extends Fake implements User {
  @override
  String get uid => 'driver-1';

  @override
  String get email => 'client@exemple.com';

  @override
  String? get displayName => null;

  @override
  String? get phoneNumber => null;
}

class _ProfilesService extends DriverProfileService {
  @override
  Future<MyDriver?> getDriver(String uid) async => MyDriver(
    name: 'Chauffeur',
    phone: '+33612345678',
    categories: ['Berline'],
    car: 'Berline',
    available: true,
  );
}

class _OrdersService extends FireService {
  @override
  Stream<List<DriverOrder>> getOrdersStream() => Stream.value([]);

  @override
  Stream<List<DriverOrder>> getOrdersForDriverStream(String driverId) =>
      Stream.value([]);
}

void main() {
  Future<void> open(WidgetTester tester, _TestAuth auth) async {
    await tester.pumpWidget(MaterialApp(home: AuthenticationPage(auth: auth)));
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  testWidgets('Validates international phone and sends normalized number', (
    tester,
  ) async {
    final auth = _TestAuth();
    await open(tester, auth);
    final logo = tester.widget<Image>(find.byType(Image));
    expect(
      (logo.image as AssetImage).assetName,
      'assets/images/pro_du_transport.png',
    );
    expect(logo.semanticLabel, 'Pro du Transport');
    await tap(tester, 'Recevoir un code');
    expect(find.textContaining('Indiquez un numéro'), findsOneWidget);
    expect(auth.phone, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('phone')),
      '+33 6 12 34 56 78',
    );
    await tap(tester, 'Recevoir un code');
    expect(auth.phone, '+33612345678');
    expect(find.byKey(const ValueKey('sms-code')), findsOneWidget);
    await tap(tester, 'Se connecter');
    expect(find.text('Saisissez le code à 6 chiffres.'), findsOneWidget);
    expect(auth.code, isNull);
    await tester.enterText(find.byKey(const ValueKey('sms-code')), '123456');
    auth.failure = FirebaseAuthException(code: 'invalid-verification-code');
    await tap(tester, 'Se connecter');
    expect(auth.code, '123456');
    expect(find.text('Le code SMS est incorrect.'), findsOneWidget);
    await tap(tester, 'Modifier le numéro / renvoyer un code');
    expect(find.byKey(const ValueKey('phone')), findsOneWidget);
  });

  testWidgets('Validates email and password and displays Firebase errors', (
    tester,
  ) async {
    final auth = _TestAuth();
    await open(tester, auth);
    await tap(tester, 'Email');
    await tester.enterText(find.byKey(const ValueKey('email')), 'incorrect');
    await tap(tester, 'Se connecter');
    expect(find.text('Saisissez une adresse email valide.'), findsOneWidget);
    expect(find.text('Saisissez votre mot de passe.'), findsOneWidget);
    expect(auth.email, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('email')),
      'client@exemple.com',
    );
    await tester.enterText(find.byKey(const ValueKey('password')), 'secret');
    await tester.ensureVisible(find.byTooltip('Afficher le mot de passe'));
    await tester.tap(find.byTooltip('Afficher le mot de passe'));
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText).last).obscureText,
      isFalse,
    );
    auth.failure = FirebaseAuthException(code: 'invalid-credential');
    await tap(tester, 'Se connecter');
    expect(auth.email, 'client@exemple.com');
    expect(auth.password, 'secret');
    expect(find.text('Email ou mot de passe incorrect.'), findsOneWidget);
  });

  testWidgets('Fits a narrow screen in both modes', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, _TestAuth());
    expect(tester.takeException(), isNull);
    await tap(tester, 'Email');
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Se connecter'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('account creation validates passwords and authenticates', (
    tester,
  ) async {
    final auth = _TestAuth();
    var authenticated = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AuthenticationPage(
          auth: auth,
          onAuthenticated: () => authenticated++,
        ),
      ),
    );
    await tap(tester, 'Créer un compte');
    await tester.enterText(
      find.byKey(const ValueKey('email')),
      'new@example.com',
    );
    await tester.enterText(find.byKey(const ValueKey('password')), '123');
    await tap(tester, 'Créer mon compte');
    expect(find.text('Utilisez au moins 6 caractères.'), findsOneWidget);
    expect(auth.createdEmail, isNull);
    await tester.enterText(find.byKey(const ValueKey('password')), 'secret123');
    await tester.enterText(
      find.byKey(const ValueKey('password-confirmation')),
      'different',
    );
    await tap(tester, 'Créer mon compte');
    expect(
      find.text('Les mots de passe ne correspondent pas.'),
      findsOneWidget,
    );
    expect(auth.createdEmail, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('password-confirmation')),
      'secret123',
    );
    auth.failure = FirebaseAuthException(code: 'email-already-in-use');
    await tap(tester, 'Créer mon compte');
    expect(
      find.textContaining('Un compte utilise déjà cet email'),
      findsOneWidget,
    );
    expect(authenticated, 0);
    auth.failure = null;
    await tap(tester, 'Créer mon compte');
    expect(auth.createdEmail, 'new@example.com');
    expect(auth.createdPassword, 'secret123');
    expect(authenticated, 1);
  });

  testWidgets('password reset needs only email and preserves account privacy', (
    tester,
  ) async {
    final auth = _TestAuth();
    await open(tester, auth);
    await tap(tester, 'Email');
    await tap(tester, 'Mot de passe oublié ?');
    expect(find.byKey(const ValueKey('password')), findsNothing);
    await tap(tester, 'Envoyer le lien');
    expect(find.text('Saisissez une adresse email valide.'), findsOneWidget);
    expect(auth.resetEmail, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('email')),
      'driver@example.com',
    );
    auth.failure = FirebaseAuthException(code: 'network-request-failed');
    await tap(tester, 'Envoyer le lien');
    expect(find.text('Vérifiez votre connexion internet.'), findsOneWidget);
    auth.failure = FirebaseAuthException(code: 'user-not-found');
    await tap(tester, 'Envoyer le lien');
    expect(find.textContaining('Si un compte correspond'), findsOneWidget);
    expect(auth.resetEmail, 'driver@example.com');
    await tap(tester, 'Retour à la connexion');
    expect(find.byKey(const ValueKey('password')), findsOneWidget);
    expect(find.textContaining('Si un compte correspond'), findsNothing);
  });

  testWidgets('registration and reset fit a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, _TestAuth());
    await tap(tester, 'Créer un compte');
    await tester.ensureVisible(find.text('Créer mon compte'));
    expect(tester.takeException(), isNull);
    await tap(tester, 'Retour à la connexion');
    await tap(tester, 'Mot de passe oublié ?');
    await tester.ensureVisible(find.text('Envoyer le lien'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Displays an authenticated session and allows sign out', (
    tester,
  ) async {
    final auth = _SessionAuth();
    addTearDown(auth.sessions.close);
    await tester.pumpWidget(
      MaterialApp(
        home: AuthenticationGate(
          auth: auth,
          ordersService: _OrdersService(),
          profileService: _ProfilesService(),
        ),
      ),
    );
    auth.sessions.add(null);
    await tester.pumpAndSettle();
    expect(find.byType(AuthenticationPage), findsOneWidget);
    expect(find.text('Bienvenue à bord'), findsOneWidget);
    auth.sessions.add(_TestUser());
    await tester.pumpAndSettle();
    expect(find.text('Commandes'), findsOneWidget);
    expect(find.byTooltip('Tablettes associées'), findsOneWidget);
    expect(find.byTooltip('Conversation client'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('client-conversation-fab')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FloatingActionButton>(
            find.byKey(const ValueKey('client-conversation-fab')),
          )
          .tooltip,
      'Conversation client',
    );
    expect(
      find.text('Aucune course disponible pour le moment.'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Se déconnecter'));
    await tester.pumpAndSettle();
    expect(find.byType(AuthenticationPage), findsOneWidget);
    expect(find.byTooltip('Mode tablette client'), findsNothing);
    expect(find.byTooltip('Client en cours'), findsNothing);
  });
}
