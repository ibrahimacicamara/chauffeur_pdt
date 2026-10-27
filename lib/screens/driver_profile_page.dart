import 'package:chauffeur/services/firebase/driver_profile_service.dart';
import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

const _navy = Color(0xFF142536);
const _gold = Color(0xFFD5B477);

class DriverProfilePage extends StatefulWidget {
  const DriverProfilePage({super.key, required this.driverId, this.service});

  final String driverId;
  final DriverProfileService? service;

  @override
  State<DriverProfilePage> createState() => _DriverProfilePageState();
}

class _DriverProfilePageState extends State<DriverProfilePage> {
  late DriverProfileService _service;
  late Stream<MyDriver?> _profile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(DriverProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.driverId != widget.driverId ||
        oldWidget.service != widget.service) {
      _load();
    }
  }

  void _load() {
    _service = widget.service ?? DriverProfileService();
    _profile = _service.watchDriver(widget.driverId);
  }

  Widget _notice(String message, IconData icon) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: _gold),
          const SizedBox(height: 20),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () => setState(_load),
            icon: const Icon(Icons.refresh),
            label: const Text('Réessayer'),
          ),
        ],
      ),
    ),
  );

  Widget _section({
    required String title,
    required IconData icon,
    required Widget child,
  }) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFFE2E7EC)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, color: _navy, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: _navy,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        child,
      ],
    ),
  );

  Widget _information(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(color: Color(0xFF687787), fontSize: 13),
      ),
      const SizedBox(height: 6),
      SelectableText(
        value.trim().isEmpty ? 'Non renseigné' : value,
        style: const TextStyle(
          color: _navy,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );

  Widget _content(MyDriver driver) {
    final name = driver.name.trim();
    final parts = name.split(RegExp(r'\s+')).where((part) => part.isNotEmpty);
    final initials = parts.take(2).map((part) => part.characters.first).join();
    final categories = driver.categories
        .where((category) => category.trim().isNotEmpty)
        .toSet()
        .toList();
    final statusColor = driver.available
        ? const Color(0xFF226C47)
        : const Color(0xFF805500);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [_navy, Color(0xFF2B455C)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 42,
                      backgroundColor: _gold,
                      child: initials.isEmpty
                          ? const Icon(
                              Icons.person_outline,
                              size: 40,
                              color: _navy,
                            )
                          : Text(
                              initials.toUpperCase(),
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                                color: _navy,
                              ),
                            ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      name.isEmpty ? 'Chauffeur' : name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'VOTRE ESPACE CHAUFFEUR',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _gold,
                        fontSize: 11,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            driver.available
                                ? Icons.check_circle_outline
                                : Icons.pause_circle_outline,
                            size: 18,
                            color: statusColor,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              driver.available ? 'Disponible' : 'Indisponible',
                              style: TextStyle(
                                color: statusColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              _section(
                title: 'Informations personnelles',
                icon: Icons.person_outline,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _information('Nom complet', driver.name),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Divider(height: 1),
                    ),
                    _information('Téléphone', driver.phone),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _section(
                title: 'Mon véhicule',
                icon: Icons.directions_car_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _information('Véhicule enregistré', driver.car),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Divider(height: 1),
                    ),
                    _information(
                      'Plaque d’immatriculation',
                      driver.licensePlate,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _section(
                title: 'Mes catégories',
                icon: Icons.workspace_premium_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (categories.isEmpty)
                      const Text(
                        'Aucune catégorie attribuée pour le moment.',
                        style: TextStyle(color: Color(0xFF687787)),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final category in categories)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: _gold.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _gold.withValues(alpha: 0.4),
                                ),
                              ),
                              child: Text(
                                category,
                                style: const TextStyle(
                                  color: _navy,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    const SizedBox(height: 16),
                    const Text(
                      'Ces catégories sont attribuées par votre administrateur '
                      'et déterminent les courses visibles dans votre espace.',
                      style: TextStyle(
                        color: Color(0xFF687787),
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF5F7F9),
    appBar: AppBar(
      title: const Text('Mon profil'),
      backgroundColor: const Color(0xFFF5F7F9),
      foregroundColor: _navy,
      surfaceTintColor: Colors.transparent,
    ),
    body: SafeArea(
      child: StreamBuilder<MyDriver?>(
        key: ValueKey(widget.driverId),
        stream: _profile,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            final error = snapshot.error;
            return _notice(
              error is FirebaseException
                  ? 'Impossible de charger votre profil (${error.code}).'
                  : 'Impossible de charger votre profil. Réessayez.',
              Icons.cloud_off_outlined,
            );
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final driver = snapshot.data;
          if (driver == null) {
            return _notice(
              'Votre profil chauffeur est introuvable.',
              Icons.person_off_outlined,
            );
          }
          return _content(driver);
        },
      ),
    ),
  );
}
