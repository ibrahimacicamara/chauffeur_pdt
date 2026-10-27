import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

class TabletManagementPage extends StatefulWidget {
  const TabletManagementPage({super.key, required this.driverId});
  final String driverId;

  @override
  State<TabletManagementPage> createState() => _TabletManagementPageState();
}

class _TabletManagementPageState extends State<TabletManagementPage> {
  late Stream<QuerySnapshot<Map<String, dynamic>>> _tablets;
  bool _busy = false;
  String? _error;
  Future<void> Function()? _retryAction;

  @override
  void initState() {
    super.initState();
    _tablets = _watchTablets();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _watchTablets() =>
      FirebaseFirestore.instance
          .collection('TabletLinks')
          .where('driverId', isEqualTo: widget.driverId)
          .snapshots();

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _retryAction = null;
    });
    try {
      await action();
    } on Object catch (error) {
      debugPrint('Association tablette : $error');
      if (mounted) {
        setState(() {
          _error = _friendlyError(error);
          _retryAction = action;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retryActionRequest() async {
    final action = _retryAction;
    if (action != null) await _run(action);
  }

  void _retryLoadingTablets() {
    setState(() => _tablets = _watchTablets());
  }

  String _friendlyError(Object error) {
    if (error is FirebaseFunctionsException) {
      final serverMessage = error.message?.trim();
      return switch (error.code) {
        'unauthenticated' =>
          'Votre session a expiré. Reconnectez-vous puis réessayez.',
        'permission-denied' =>
          serverMessage?.isNotEmpty == true
              ? serverMessage!
              : 'Vous n’êtes pas autorisé à effectuer cette action.',
        'resource-exhausted' =>
          serverMessage?.isNotEmpty == true
              ? serverMessage!
              : 'Trop de demandes ont été envoyées. Patientez un instant.',
        'failed-precondition' =>
          serverMessage?.isNotEmpty == true
              ? serverMessage!
              : 'Cette action ne peut pas être effectuée pour le moment.',
        'invalid-argument' =>
          serverMessage?.isNotEmpty == true
              ? serverMessage!
              : 'Les informations envoyées sont invalides.',
        'unavailable' || 'deadline-exceeded' =>
          'Le service est momentanément indisponible. Vérifiez votre '
              'connexion puis réessayez.',
        _ =>
          'La demande n’a pas abouti. Vérifiez votre connexion puis '
              'réessayez.',
      };
    }
    if (error is FirebaseException) {
      return switch (error.code) {
        'unauthenticated' =>
          'Votre session a expiré. Reconnectez-vous puis réessayez.',
        'permission-denied' =>
          'Vous n’avez pas l’autorisation de consulter ces tablettes.',
        'unavailable' =>
          'Connexion au service impossible. Vérifiez votre réseau puis '
              'réessayez.',
        'failed-precondition' =>
          'Les données ne sont pas encore disponibles. Réessayez dans un '
              'instant.',
        _ =>
          'Impossible de charger les tablettes pour le moment. '
              'Réessayez.',
      };
    }
    if (error is FormatException) {
      return 'Le service a renvoyé une réponse invalide. Réessayez.';
    }
    return 'Une erreur inattendue est survenue. Vérifiez votre connexion '
        'puis réessayez.';
  }

  Future<void> _create() => _run(() async {
    final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('createTabletPairingCode')
        .call<Map<String, dynamic>>();
    final code = result.data['code'];
    if (code is! String) {
      throw const FormatException('Code de tablette invalide.');
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Associer une tablette'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              code,
              style: const TextStyle(fontSize: 30, letterSpacing: 3),
            ),
            const SizedBox(height: 12),
            const Text(
              'Saisissez ce code dans l’application client. Usage unique, valable 5 minutes. Un nouveau code remplace le précédent.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  });

  Future<void> _revoke(String id, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Déconnecter la tablette ?'),
        content: Text(
          '« $name » ne pourra plus accéder aux sessions clients. Un nouveau code sera nécessaire pour la réassocier.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Déconnecter'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('revokeTablet')
          .call<void>({'tabletId': id});
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF4F6F8),
    appBar: AppBar(
      title: const Text(
        'Tablettes associées',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
      backgroundColor: const Color(0xFFF4F6F8),
      surfaceTintColor: Colors.transparent,
    ),
    body: SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: const Color(0xFF142536),
                      borderRadius: BorderRadius.circular(24),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF142536), Color(0xFF203B54)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: const Color(0xFFD5B477)
                                .withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Icon(
                            Icons.tablet_mac_rounded,
                            color: Color(0xFFD5B477),
                            size: 28,
                          ),
                        ),
                        const SizedBox(width: 16),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Accès client sur tablette',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 19,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              SizedBox(height: 6),
                              Text(
                                'Gérez les appareils autorisés à accéder '
                                'aux sessions clients.',
                                style: TextStyle(
                                  color: Color(0xFFD7E0E8),
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (_busy) ...[
                    const LinearProgressIndicator(
                      minHeight: 3,
                      color: Color(0xFFD5B477),
                      backgroundColor: Color(0xFFE3E7EB),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (_error != null) ...[
                    _TabletErrorCard(
                      title: 'Action impossible',
                      message: _error!,
                      onRetry: _retryAction == null
                          ? null
                          : _retryActionRequest,
                      retrying: _busy,
                    ),
                    const SizedBox(height: 16),
                  ],
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: const Color(0xFFE7EBEF)),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x0A142536),
                          blurRadius: 18,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.add_link_rounded,
                              color: Color(0xFF142536),
                            ),
                            SizedBox(width: 10),
                            Text(
                              'Associer un appareil',
                              style: TextStyle(
                                color: Color(0xFF142536),
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Générez un code à usage unique, puis saisissez-le '
                          'dans l’application client sur la tablette.',
                          style: TextStyle(
                            color: Color(0xFF687787),
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _busy ? null : _create,
                            icon: const Icon(Icons.qr_code_2_rounded),
                            label: const Text('Créer un code d’association'),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF142536),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              textStyle: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    'Vos tablettes',
                    style: TextStyle(
                      color: Color(0xFF142536),
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _tablets,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return _TabletInfoCard(
                          icon: Icons.cloud_off_outlined,
                          title: 'Chargement impossible',
                          message: _friendlyError(snapshot.error!),
                          action: TextButton.icon(
                            onPressed: _retryLoadingTablets,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Réessayer'),
                          ),
                        );
                      }
                      if (!snapshot.hasData) {
                        return const _TabletInfoCard(
                          child: Padding(
                            padding: EdgeInsets.all(12),
                            child: Center(
                              child: CircularProgressIndicator(
                                color: Color(0xFF142536),
                              ),
                            ),
                          ),
                        );
                      }
                      final docs = snapshot.data!.docs;
                      if (docs.isEmpty) {
                        return const _TabletInfoCard(
                          icon: Icons.tablet_android_outlined,
                          title: 'Aucune tablette associée',
                          message:
                              'Créez un code d’association pour autoriser '
                              'une tablette à accéder aux sessions clients.',
                        );
                      }
                      return Column(
                        children: [
                          for (final doc in docs) ...[
                            _TabletDeviceCard(
                              name: doc.data()['name'] as String,
                              active: doc.data()['active'] == true,
                              busy: _busy,
                              onRevoke: () =>
                                  _revoke(doc.id, doc.data()['name'] as String),
                            ),
                            if (doc != docs.last) const SizedBox(height: 10),
                          ],
                        ],
                      );
                    },
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

class _TabletInfoCard extends StatelessWidget {
  const _TabletInfoCard({
    this.icon,
    this.title,
    this.message,
    this.child,
    this.action,
  });

  final IconData? icon;
  final String? title;
  final String? message;
  final Widget? child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFFE7EBEF)),
    ),
    child:
        child ??
        Column(
          children: [
            Icon(icon, color: const Color(0xFF9AA7B3), size: 34),
            const SizedBox(height: 12),
            Text(
              title!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF142536),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF687787), height: 1.45),
            ),
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
  );
}

class _TabletErrorCard extends StatelessWidget {
  const _TabletErrorCard({
    required this.title,
    required this.message,
    required this.onRetry,
    required this.retrying,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;
  final bool retrying;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF1F0),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFFFFD8D4)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline_rounded, color: Color(0xFFB42318)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Color(0xFF7A271A),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: const TextStyle(
                      color: Color(0xFF7A271A),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (onRetry != null) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: retrying ? null : onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Réessayer'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF8C2F27),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

class _TabletDeviceCard extends StatelessWidget {
  const _TabletDeviceCard({
    required this.name,
    required this.active,
    required this.busy,
    required this.onRevoke,
  });

  final String name;
  final bool active;
  final bool busy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFFE7EBEF)),
    ),
    child: Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: const Color(0xFFF1F4F6),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.tablet_mac_rounded, color: Color(0xFF42576A)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF142536),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF24936E)
                          : const Color(0xFF9AA7B3),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    active ? 'Associée et active' : 'Accès révoqué',
                    style: const TextStyle(
                      color: Color(0xFF687787),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (active)
          IconButton(
            tooltip: 'Révoquer l’accès de $name',
            onPressed: busy ? null : onRevoke,
            icon: const Icon(Icons.link_off_rounded),
            color: const Color(0xFF687787),
          ),
      ],
    ),
  );
}
