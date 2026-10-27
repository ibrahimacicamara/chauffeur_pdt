import 'package:chauffeur/screens/current_com.dart';
import 'package:chauffeur/services/firebase/driver_reminder_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class DriverTravelAlertPage extends StatefulWidget {
  const DriverTravelAlertPage({
    super.key,
    required this.alertId,
    required this.service,
  });

  final String alertId;
  final DriverReminderService service;

  @override
  State<DriverTravelAlertPage> createState() => _DriverTravelAlertPageState();
}

class _DriverTravelAlertPageState extends State<DriverTravelAlertPage> {
  late Stream<Map<String, dynamic>?> _alert;

  @override
  void initState() {
    super.initState();
    _alert = widget.service.watchTravelAlert(widget.alertId);
  }

  Widget _details(Map<String, dynamic> data) {
    final noResponse = data['kind'] == 'no_response';
    final duration = data['durationSeconds'];
    final orderId = data['orderId'];
    final driverId = data['driverId'];
    final departure = data['departureDate'];
    final createdAt = data['createdAt'];
    final state = data['state'];
    if ((!noResponse &&
            (duration is! num || !duration.isFinite || duration <= 3600)) ||
        orderId is! String ||
        driverId is! String ||
        departure is! Timestamp ||
        createdAt is! Timestamp ||
        !{'pending', 'sent', 'failed', 'cancelled'}.contains(state)) {
      return const Text('Le format de cette alerte est invalide.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          noResponse
              ? 'Chauffeur sans réponse'
              : 'Trajet supérieur à une heure',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        Text('Course : $orderId'),
        Text('Chauffeur : $driverId'),
        if (!noResponse)
          Text(
            'Temps estimé avec trafic : ${((duration as num) / 60).ceil()} min',
          ),
        Text('Départ : ${formatCourseDate(departure.toDate())}'),
        Text(
          '${noResponse ? 'Alerte' : 'Confirmation'} : ${formatCourseDate(createdAt.toDate())}',
        ),
        const SizedBox(height: 16),
        Text(
          state == 'cancelled'
              ? 'Alerte annulée : la course ou son attribution a changé.'
              : noResponse
              ? 'Aucune confirmation enregistrée cinq minutes après le rappel.'
              : 'Le chauffeur a confirmé sa disponibilité mais son trajet dépasse 60 minutes.',
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Alerte chauffeur')),
    body: StreamBuilder<Map<String, dynamic>?>(
      stream: _alert,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Impossible de charger l’alerte.'),
                TextButton(
                  onPressed: () => setState(() {
                    _alert = widget.service.watchTravelAlert(widget.alertId);
                  }),
                  child: const Text('Réessayer'),
                ),
              ],
            ),
          );
        }
        final data = snapshot.data;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: data == null
              ? const Text('Cette alerte n’existe plus.')
              : _details(data),
        );
      },
    ),
  );
}
