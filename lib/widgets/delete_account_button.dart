import 'package:chauffeur/services/reminder_alarm_service.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Bouton « Supprimer mon compte » exigé par l'App Store (règle 5.1.1(v)).
///
/// La suppression est faite côté serveur par `deleteDriverAccount` : profil,
/// conversations, appareils et compte de connexion sont effacés ; les courses
/// passées sont conservées sous un pseudonyme et les courses à venir sont
/// remises en attente.
class DeleteAccountButton extends StatefulWidget {
  const DeleteAccountButton({super.key, this.functions, this.auth});

  final FirebaseFunctions? functions;
  final FirebaseAuth? auth;

  @override
  State<DeleteAccountButton> createState() => _DeleteAccountButtonState();
}

class _DeleteAccountButtonState extends State<DeleteAccountButton> {
  static const _red = Color(0xFFB3261E);
  bool _busy = false;

  Future<bool> _confirm() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer votre compte ?'),
        content: const Text(
          'Votre compte chauffeur, votre profil, vos conversations et vos '
          'appareils associés seront définitivement supprimés.\n\n'
          'Vos courses à venir seront remises en attente pour être '
          'réattribuées. L’historique de vos courses passées est conservé '
          'de façon anonyme pour la comptabilité de Pro du Transport.\n\n'
          'Cette action est irréversible.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: _red),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Supprimer définitivement'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _delete() async {
    if (_busy || !await _confirm() || !mounted) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await (widget.functions ??
              FirebaseFunctions.instanceFor(region: 'europe-west1'))
          .httpsCallable('deleteDriverAccount')
          .call<void>();
      try {
        await ReminderAlarmService().unbindDriver();
      } catch (_) {
        // Les alarmes locales ne doivent pas bloquer la suppression.
      }
      navigator.popUntil((route) => route.isFirst);
      await (widget.auth ?? FirebaseAuth.instance).signOut();
      messenger.showSnackBar(
        const SnackBar(content: Text('Votre compte a été supprimé.')),
      );
    } on FirebaseFunctionsException catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.code == 'failed-precondition' && error.message != null
                ? error.message!
                : 'Suppression impossible (${error.code}). Réessayez.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    style: OutlinedButton.styleFrom(
      foregroundColor: _red,
      side: const BorderSide(color: _red),
      padding: const EdgeInsets.symmetric(vertical: 14),
    ),
    onPressed: _busy ? null : _delete,
    icon: _busy
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.delete_forever_outlined),
    label: const Text('Supprimer mon compte'),
  );
}
