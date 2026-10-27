import 'dart:async';

import 'package:chauffeur/screens/current_com.dart';
import 'package:chauffeur/services/firebase/driver_reminder_service.dart';
import 'package:chauffeur/services/reminder_alarm_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:chauffeur/services/location_service.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';

class DriverReminderPanel extends StatefulWidget {
  const DriverReminderPanel({
    super.key,
    required this.orderId,
    required this.driverId,
    required this.service,
    this.locationService,
    this.alarmService,
  });

  final String orderId;
  final String driverId;
  final DriverReminderService service;
  final LocationService? locationService;
  final ReminderAlarmService? alarmService;

  @override
  State<DriverReminderPanel> createState() => _DriverReminderPanelState();
}

class _DriverReminderPanelState extends State<DriverReminderPanel>
    with WidgetsBindingObserver {
  late Stream<DriverReminder?> _reminder;
  Timer? _clock;
  bool _busy = false;
  String? _error;
  final _stopped = <String>{};
  bool _silenced = false;
  String? _generation;
  late final ReminderAlarmService _alarms =
      widget.alarmService ?? ReminderAlarmService();

  Future<void> _stopAlarm(String generation) async {
    if (!_stopped.add(generation)) return;
    try {
      await _alarms.stop(widget.orderId, generation);
    } on PlatformException catch (error) {
      _alarmError(error);
    } on MissingPluginException catch (error) {
      _alarmError(error);
    }
  }

  void _alarmError(Object error) {
    debugPrint('Reminder alarm control failed: $error');
    if (!mounted) return;
    setState(() => _error =
        'La commande de sonnerie a échoué. La confirmation enregistrée reste valable. '
        'Utilisez la notification pour couper le son ou réinstallez la version à jour.');
  }

  DriverReminder? _syncAlarm(DriverReminder? reminder) {
    if (reminder?.generation != _generation) {
      _generation = reminder?.generation;
      _silenced = false;
    }
    if (reminder != null && reminder.driverId == widget.driverId &&
        {'confirmed', 'cancelled', 'unconfirmed'}.contains(reminder.state)) {
      unawaited(_stopAlarm(reminder.generation));
    }
    return reminder;
  }

  Future<void> _silence(DriverReminder reminder) async {
    try {
      final silenced = await _alarms.silence(widget.orderId, reminder.generation);
      if (!silenced) {
        throw PlatformException(code: 'alarm-silence-rejected');
      }
      if (mounted) setState(() => _silenced = true);
    } on PlatformException catch (error) {
      _alarmError(error);
    } on MissingPluginException catch (error) {
      _alarmError(error);
    }
  }

  Future<void> _confirm(DriverReminder reminder) async {
    if (_busy || !reminder.canConfirm(DateTime.now())) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final consent = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Confirmer ma disponibilité'),
          content: const Text(
            'Votre position GPS et le lieu de départ seront transmis à Google Maps '
            'pour estimer le temps de trajet avec le trafic. '
            'La position et le résultat seront enregistrés. '
            'Si le trajet dépasse une heure, une alerte sera envoyée à l’administrateur.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Partager ma position'),
            ),
          ],
        ),
      );
      if (consent != true || !mounted) return;
      final fix = await (widget.locationService ?? LocationService())
          .currentFix();
      if (!mounted) return;
      await widget.service.confirmAvailability(
        widget.orderId,
        reminder.generation,
        fix,
      );
      await _stopAlarm(reminder.generation);
    } on FirebaseFunctionsException catch (error) {
      if (mounted) {
        setState(
          () => _error =
              error.message ??
              'Confirmation impossible (${error.code}). Réessayez.',
        );
      }
    } on FirebaseException catch (error) {
      if (mounted) {
        setState(
          () => _error = 'Confirmation impossible (${error.code}). Réessayez.',
        );
      }
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = 'Localisation indisponible (${error.code}). Réessayez.',
        );
      }
    } on MissingPluginException {
      if (mounted) {
        setState(
          () =>
              _error = 'Redémarrez l’application pour activer la localisation.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _reminder = widget.service.watch(widget.orderId).map(_syncAlarm);
    WidgetsBinding.instance.addObserver(this);
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) setState(() {});
  }

  @override
  void dispose() {
    _clock?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<DriverReminder?>(
    stream: _reminder,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        final error = snapshot.error;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  error is FormatException
                      ? error.message
                      : error is FirebaseException
                      ? 'Rappel indisponible (${error.code}).'
                      : 'Impossible de charger le rappel.',
                ),
                TextButton(
                  onPressed: () => setState(
                    () => _reminder = widget.service.watch(widget.orderId).map(_syncAlarm),
                  ),
                  child: const Text('Réessayer'),
                ),
              ],
            ),
          ),
        );
      }
      if (!snapshot.hasData) return const SizedBox.shrink();
      final reminder = snapshot.data!;
      if (reminder.driverId != widget.driverId ||
          reminder.state == 'cancelled') {
        return const SizedBox.shrink();
      }
      final now = DateTime.now();
      return Card(
        color: const Color(0xFFFFF4DF),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Rappel avant la course',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              if (reminder.state == 'confirmed') ...[
                const Text('Disponibilité confirmée'),
                if (reminder.confirmedAt != null)
                  Text(
                    'Confirmation : ${formatCourseDate(reminder.confirmedAt!)}',
                  ),
                if (reminder.positionCapturedAt != null)
                  Text(
                    'Position mesurée : ${formatCourseDate(reminder.positionCapturedAt!)}',
                  ),
                if (reminder.distanceMeters != null)
                  Text(
                    'Distance à vol d’oiseau : ${(reminder.distanceMeters! / 1000).toStringAsFixed(1)} km',
                  ),
                if (reminder.distanceError != null)
                  Text(
                    reminder.distanceError!,
                    style: const TextStyle(color: Color(0xFFB42318)),
                  ),
                if (reminder.durationSeconds != null) ...[
                  Text(
                    'Temps de trajet estimé : ${(reminder.durationSeconds! / 60).ceil()} min (avec trafic)',
                  ),
                  if (reminder.routeDistanceMeters != null)
                    Text(
                      'Distance routière : ${(reminder.routeDistanceMeters! / 1000).toStringAsFixed(1)} km',
                    ),
                  if (reminder.estimatedArrivalAt != null)
                    Text(
                      'Arrivée estimée : ${formatCourseDate(reminder.estimatedArrivalAt!)}',
                    ),
                  if (reminder.adminAlertId != null)
                    const Text(
                      'Trajet supérieur à une heure : alerte administrateur enregistrée.',
                      style: TextStyle(color: Color(0xFFB42318)),
                    ),
                ],
              ] else if (reminder.canConfirm(now)) ...[
                FilledButton.icon(
                  key: const ValueKey('confirm-availability'),
                  onPressed: _busy ? null : () => _confirm(reminder),
                  icon: const Icon(Icons.location_on_outlined),
                  label: Text(
                    _busy ? 'Calcul du trajet…' : 'Confirmer ma disponibilité',
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Partagez votre position pour estimer votre trajet jusqu’au départ.',
                  style: TextStyle(color: Color(0xFF687787)),
                ),
                if (_alarms.supported && reminder.state == 'sent') ...[
                  TextButton.icon(
                    onPressed: _silenced ? null : () => _silence(reminder),
                    icon: const Icon(Icons.volume_off_outlined),
                    label: Text(_silenced ? 'Son coupé' : 'Couper le son'),
                  ),
                  const Text(
                    'Couper le son ne confirme pas votre disponibilité. '
                    'Sans confirmation après cinq minutes, l’administrateur sera alerté.',
                  ),
                ],
              ] else
                Text(
                  now.isBefore(reminder.dueAt)
                      ? 'Confirmation disponible le ${formatCourseDate(reminder.dueAt)}'
                      : 'Rappel non confirmé avant le départ.',
                ),
              if (_error != null)
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
          ),
        ),
      );
    },
  );
}
