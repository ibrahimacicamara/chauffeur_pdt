import 'package:chauffeur/services/firebase/driver_profile_service.dart';
import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class DriverProfileGate extends StatefulWidget {
  const DriverProfileGate({
    super.key,
    required this.driverId,
    required this.service,
    required this.child,
    required this.onSignOut,
    this.initialName,
    this.initialPhone,
  });

  final String driverId;
  final DriverProfileService service;
  final Widget child;
  final Future<void> Function() onSignOut;
  final String? initialName;
  final String? initialPhone;

  @override
  State<DriverProfileGate> createState() => _DriverProfileGateState();
}

class _DriverProfileGateState extends State<DriverProfileGate> {
  late Future<MyDriver?> _profile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _profile = widget.service.getDriver(widget.driverId);
  }

  Future<void> _signOut() async {
    try {
      await widget.onSignOut();
    } on FirebaseException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Déconnexion impossible (${error.code}).')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<MyDriver?>(
    future: _profile,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (!snapshot.hasError && snapshot.data != null) return widget.child;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Profil chauffeur'),
          actions: [
            IconButton(
              tooltip: 'Se déconnecter',
              onPressed: _signOut,
              icon: const Icon(Icons.logout),
            ),
          ],
        ),
        body: snapshot.hasError
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Impossible de charger votre profil chauffeur.',
                      textAlign: TextAlign.center,
                    ),
                    TextButton(
                      onPressed: () => setState(_load),
                      child: const Text('Réessayer'),
                    ),
                  ],
                ),
              )
            : _DriverProfileForm(
                driverId: widget.driverId,
                service: widget.service,
                initialName: widget.initialName,
                initialPhone: widget.initialPhone,
                onSaved: (driver) => setState(() {
                  _profile = Future.value(driver);
                }),
              ),
      );
    },
  );
}

class _DriverProfileForm extends StatefulWidget {
  const _DriverProfileForm({
    required this.driverId,
    required this.service,
    required this.onSaved,
    this.initialName,
    this.initialPhone,
  });

  final String driverId;
  final DriverProfileService service;
  final ValueChanged<MyDriver> onSaved;
  final String? initialName;
  final String? initialPhone;

  @override
  State<_DriverProfileForm> createState() => _DriverProfileFormState();
}

class _DriverProfileFormState extends State<_DriverProfileForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initialName);
  late final _phone = TextEditingController(text: widget.initialPhone);
  final _car = TextEditingController();
  final _licensePlate = TextEditingController();
  late Future<List<String>> _carNames;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _carNames = widget.service.getCarNames();
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _car.dispose();
    _licensePlate.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final driver = await widget.service.createProfile(
        widget.driverId,
        name: _name.text,
        phone: _phone.text,
        car: _car.text,
        licensePlate: _licensePlate.text,
      );
      if (mounted) widget.onSaved(driver);
    } on FirebaseException catch (error) {
      if (!mounted) return;
      setState(
        () => _error = 'Enregistrement impossible (${error.code}). Réessayez.',
      );
    } on ArgumentError catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Complétez votre profil',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const ValueKey('driver-name'),
                controller: _name,
                enabled: !_busy,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.name],
                decoration: const InputDecoration(labelText: 'Nom complet'),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'Saisissez votre nom.'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const ValueKey('driver-phone'),
                controller: _phone,
                enabled: !_busy,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.telephoneNumber],
                decoration: const InputDecoration(
                  labelText: 'Numéro de téléphone',
                  hintText: '+33 6 12 34 56 78',
                ),
                validator: (value) =>
                    RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(
                      (value ?? '').replaceAll(RegExp(r'[\s().-]'), ''),
                    )
                    ? null
                    : 'Indiquez un numéro avec indicatif pays (+33…).',
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const ValueKey('driver-car'),
                controller: _car,
                enabled: !_busy,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Véhicule'),
                onChanged: (_) => setState(() {}),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'Saisissez votre véhicule.'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const ValueKey('driver-license-plate'),
                controller: _licensePlate,
                enabled: !_busy,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Plaque d’immatriculation',
                  hintText: 'AB-123-CD',
                ),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'Saisissez votre plaque d’immatriculation.'
                    : null,
                onFieldSubmitted: (_) => _save(),
              ),
              FutureBuilder<List<String>>(
                future: _carNames,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    final error = snapshot.error;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          error is FormatException
                              ? error.message
                              : error is FirebaseException
                              ? 'Suggestions indisponibles (${error.code}).'
                              : 'Impossible de charger les suggestions.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _carNames = widget.service.getCarNames();
                                }),
                          child: const Text('Réessayer les suggestions'),
                        ),
                      ],
                    );
                  }
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('Chargement des véhicules…'),
                    );
                  }
                  final names = snapshot.data ?? const <String>[];
                  final query = _car.text.trim().toLowerCase();
                  final matches = names
                      .where((name) => name.toLowerCase().contains(query))
                      .toList();
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          names.isEmpty
                              ? 'Aucun véhicule disponible dans le catalogue.'
                              : matches.isEmpty
                              ? 'Aucun véhicule correspondant. La saisie libre reste possible.'
                              : 'Véhicules suggérés',
                        ),
                        if (matches.isNotEmpty)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 160),
                            child: SingleChildScrollView(
                              child: Wrap(
                                spacing: 8,
                                children: [
                                  for (final name in matches)
                                    ActionChip(
                                      label: Text(name),
                                      onPressed: _busy
                                          ? null
                                          : () => setState(() {
                                              _car.text = name;
                                              _car.selection =
                                                  TextSelection.collapsed(
                                                    offset: name.length,
                                                  );
                                            }),
                                    ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),
              const Text(
                'Vos catégories seront attribuées par l’administrateur.',
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Enregistrer mon profil'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
