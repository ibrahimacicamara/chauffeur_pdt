import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class Fireauth {
  Fireauth([this._auth]);

  final FirebaseAuth? _auth;
  FirebaseAuth get _firebaseAuth => _auth ?? FirebaseAuth.instance;
  ConfirmationResult? _webConfirmation;
  String? _verificationId;
  int _phoneRequest = 0;

  void cancelPhoneVerification() {
    _phoneRequest++;
    _verificationId = null;
    _webConfirmation = null;
  }

  Stream<User?> authStateChanges() => _firebaseAuth.authStateChanges();

  Future<void> signIn(String email, String password) async {
    await _firebaseAuth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<void> createAccount(String email, String password) async {
    await _firebaseAuth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<void> resetPassword(String email) =>
      _firebaseAuth.sendPasswordResetEmail(email: email.trim());

  Future<void> sendPhoneCode(
    String phone, {
    required VoidCallback onCodeSent,
    required VoidCallback onVerified,
    required void Function(FirebaseAuthException error) onError,
  }) async {
    cancelPhoneVerification();
    final request = _phoneRequest;
    if (kIsWeb) {
      final confirmation = await _firebaseAuth.signInWithPhoneNumber(phone);
      if (request != _phoneRequest) return;
      _webConfirmation = confirmation;
      onCodeSent();
      return;
    }
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      throw UnsupportedError(
        'Phone authentication requires Android, iOS or web.',
      );
    }
    await _firebaseAuth.verifyPhoneNumber(
      phoneNumber: phone,
      verificationCompleted: (credential) async {
        if (request != _phoneRequest) return;
        try {
          await _firebaseAuth.signInWithCredential(credential);
          if (request == _phoneRequest) onVerified();
        } on FirebaseAuthException catch (error) {
          if (request == _phoneRequest) onError(error);
        }
      },
      verificationFailed: (error) {
        if (request == _phoneRequest) onError(error);
      },
      codeSent: (verificationId, resendToken) {
        if (request != _phoneRequest) return;
        _verificationId = verificationId;
        onCodeSent();
      },
      // Automatic retrieval ending does not invalidate manual code entry.
      codeAutoRetrievalTimeout: (verificationId) {
        if (request != _phoneRequest) return;
        _verificationId = verificationId;
      },
    );
  }

  Future<void> verifyPhoneCode(String code) async {
    final confirmation = _webConfirmation;
    if (confirmation != null) {
      await confirmation.confirm(code);
      return;
    }
    final verificationId = _verificationId;
    if (verificationId == null) {
      throw FirebaseAuthException(
        code: 'session-expired',
        message: 'Demandez un nouveau code SMS.',
      );
    }
    await _firebaseAuth.signInWithCredential(
      PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: code,
      ),
    );
  }

  Future<void> signOut() => _firebaseAuth.signOut();

  static String errorMessage(FirebaseAuthException error) {
    return switch (error.code) {
      'invalid-email' => 'Cette adresse email est invalide.',
      'email-already-in-use' => 'Un compte utilise déjà cet email. Connectez-vous ou réinitialisez votre mot de passe.',
      'weak-password' || 'password-does-not-meet-requirements' =>
        'Choisissez un mot de passe plus sécurisé (au moins 6 caractères).',
      'invalid-credential' ||
      'user-not-found' ||
      'wrong-password' => 'Email ou mot de passe incorrect.',
      'user-disabled' => 'Ce compte a été désactivé.',
      'invalid-phone-number' => 'Vérifiez le numéro et son indicatif pays.',
      'invalid-verification-code' => 'Le code SMS est incorrect.',
      'session-expired' || 'code-expired' =>
        'Le code a expiré. Revenez au numéro pour demander un nouveau code.',
      'too-many-requests' => 'Trop de tentatives. Réessayez plus tard.',
      'network-request-failed' => 'Vérifiez votre connexion internet.',
      'operation-not-allowed' =>
        'Ce mode de connexion doit être activé dans Firebase Authentication.',
      'quota-exceeded' => 'Le quota de SMS est atteint. Réessayez plus tard.',
      'app-not-authorized' ||
      'invalid-app-credential' ||
      'captcha-check-failed' ||
      'missing-client-identifier' => 'La vérification de l’application a échoué. Vérifiez la configuration Firebase.',
      _ => 'Connexion impossible (${error.code}). Réessayez.',
    };
  }
}
