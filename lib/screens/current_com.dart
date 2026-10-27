import 'package:chauffeur/screens/client_name_board.dart';
import 'package:chauffeur/screens/client_conversation_page.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/services/firebase/driver_reminder_service.dart';
import 'package:chauffeur/widgets/driver_reminder_panel.dart';
import 'package:chauffeur/widgets/onboard_payment_warning.dart';
import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:chauffeur/services/location_service.dart';
import 'package:chauffeur/services/order_pdf_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String formatCourseDate(DateTime date) {
  final local = date.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year} '
      'à ${two(local.hour)}:${two(local.minute)}';
}

class CurrentCommandePage extends StatefulWidget {
  const CurrentCommandePage({
    super.key,
    required this.orderId,
    required this.driverId,
    required this.service,
    this.locationService,
    this.reminderService,
  });

  final String orderId;
  final String driverId;
  final FireService service;
  final LocationService? locationService;
  final DriverReminderService? reminderService;

  @override
  State<CurrentCommandePage> createState() => _CurrentCommandePageState();
}

class _CurrentCommandePageState extends State<CurrentCommandePage> {
  static const _navy = Color(0xFF142536);
  static const _gold = Color(0xFFD5B477);
  static const _stages = [
    OrderStatus.ASSIGNED,
    OrderStatus.EN_ROUTE,
    OrderStatus.ON_SITE,
    OrderStatus.CLIENT_ON_BOARD,
    OrderStatus.COMPLETED,
  ];
  late Stream<DriverOrder?> _order;
  late LocationService _location;
  var _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _order = widget.service.getOrderStream(widget.orderId);
    _location = widget.locationService ?? LocationService();
  }

  Future<void> _advance(DriverOrder order) async {
    final next = order.currentStatus.next;
    if (_busy || next == null) return;
    setState(() => _busy = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Passer à « ${next.label} » ?'),
          content: const Text(
            'Votre position GPS sera enregistrée avec cette étape. '
            'Le changement ne pourra pas être annulé depuis cette page.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Retour'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirmer'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _error = null);
      final position = await _location.currentPosition();
      if (!mounted) return;
      await widget.service.advanceOrderStatus(
        orderId: order.id,
        expectedStatus: order.currentStatus,
        nextStatus: next,
        location: position,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Statut enregistré : ${next.label}.')),
      );
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on FirebaseException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.code == 'permission-denied'
              ? 'Vous n’avez pas l’autorisation de modifier cette commande.'
              : 'Enregistrement impossible (${error.code}). Réessayez.';
        });
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _error =
              'Localisation impossible (${error.code}). Vérifiez les autorisations.';
        });
      }
    } on UnsupportedError {
      if (mounted) {
        setState(() {
          _error =
              'La localisation n’est pas prise en charge sur cette plateforme.';
        });
      }
    } on MissingPluginException {
      if (mounted) {
        setState(() {
          _error = 'Redémarrez l’application pour activer le service de localisation.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _release(DriverOrder order) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remettre la course en attente ?'),
          content: const Text(
            'Vous ne serez plus attribué à cette course. Elle pourra être '
            'choisie par un autre chauffeur. La commande ne sera pas supprimée. '
            'Votre position GPS sera enregistrée dans l’historique.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Garder la course'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remettre en attente'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final location = await _location.currentPosition();
      if (!mounted) return;
      await widget.service.releaseOrder(order.id, location: location);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('La course est en attente d’attribution.'),
        ),
      );
      Navigator.of(context).pop();
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on FirebaseException catch (error) {
      if (mounted) {
        setState(
          () => _error =
              'Remise en attente impossible (${error.code}). Réessayez.',
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _error =
              'Localisation impossible (${error.code}). Vérifiez les autorisations.',
        );
      }
    } on UnsupportedError {
      if (mounted) {
        setState(
          () => _error =
              'La localisation n’est pas prise en charge sur cette plateforme.',
        );
      }
    } on MissingPluginException {
      if (mounted) {
        setState(
          () => _error =
              'Service de localisation indisponible. Redémarrez l’application.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _panel(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFFE2E7EC)),
    ),
    child: child,
  );

  Widget _detail(IconData icon, String label, String value) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 22, color: _navy),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(color: Color(0xFF687787), fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _content(DriverOrder order) {
    final current = order.currentStatus;
    final currentIndex = _stages.indexOf(current);
    final next = current.next;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [_navy, Color(0xFF2C485D)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.directions_car_rounded,
                  color: _gold,
                  size: 36,
                ),
                const SizedBox(height: 20),
                const Text(
                  'VOTRE MISSION',
                  style: TextStyle(
                    color: _gold,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  current.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Commande ${order.id}',
                  style: const TextStyle(color: Color(0xFFCDD7DF)),
                ),
                const SizedBox(height: 24),
                if (currentIndex >= 0)
                  LinearProgressIndicator(
                    value: (currentIndex + 1) / _stages.length,
                    color: _gold,
                    backgroundColor: Colors.white24,
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(6),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (widget.reminderService != null)
            DriverReminderPanel(
              key: ValueKey('reminder-${order.id}'),
              orderId: order.id,
              driverId: widget.driverId,
              service: widget.reminderService!,
              locationService: _location,
            ),
          OnboardPaymentWarning(order: order),
          if (order.currentStatus == OrderStatus.CLIENT_ON_BOARD)
            FilledButton.icon(
              key: const ValueKey('current-client-conversation'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ClientConversationPage(
                    driverId: widget.driverId,
                    orderId: order.id,
                  ),
                ),
              ),
              icon: const Icon(Icons.forum_outlined),
              label: const Text('Conversation avec le client'),
            ),
          const SizedBox(height: 20),
          if (firstClientName(order) case final clientName?) ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey('show-client-name-board'),
                onPressed: () => ClientNameBoardPage.open(context, clientName),
                icon: const Icon(Icons.badge_outlined),
                label: const Text('Afficher la pancarte client'),
                style: FilledButton.styleFrom(
                  backgroundColor: _navy,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
          _panel(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Le déroulement de votre course',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                for (var index = 0; index < _stages.length; index++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: index <= currentIndex
                              ? _navy
                              : const Color(0xFFF0F3F6),
                          child: Icon(
                            index < currentIndex ||
                                    current == OrderStatus.COMPLETED
                                ? Icons.check_rounded
                                : index == currentIndex
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: index <= currentIndex ? _gold : Colors.grey,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            _stages[index].label,
                            style: TextStyle(
                              fontWeight: index == currentIndex
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (index == currentIndex)
                          const Text(
                            'Actuel',
                            style: TextStyle(
                              color: Color(0xFF687787),
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                if ({
                  OrderStatus.ASSIGNED,
                  OrderStatus.EN_ROUTE,
                  OrderStatus.ON_SITE,
                }.contains(current)) ...[
                  OutlinedButton.icon(
                    key: const ValueKey('release-order'),
                    onPressed: _busy ? null : () => _release(order),
                    icon: const Icon(Icons.assignment_return_outlined),
                    label: const Text('Remettre en attente'),
                  ),
                  const SizedBox(height: 12),
                ],
                if (next != null) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const ValueKey('advance-status'),
                      onPressed: _busy ? null : () => _advance(order),
                      style: FilledButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: _navy,
                        padding: const EdgeInsets.all(18),
                      ),
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_forward_rounded),
                      label: Text(
                        _busy
                            ? 'Mise à jour en cours…'
                            : 'Passer à « ${next.label} »',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Votre position est enregistrée uniquement lorsque vous confirmez une étape.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF687787),
                      height: 1.5,
                    ),
                  ),
                ] else
                  Text(
                    current == OrderStatus.COMPLETED
                        ? 'Merci pour votre trajet. Cette course est terminée.'
                        : 'Cette course est clôturée. Aucun changement n’est possible.',
                    style: const TextStyle(
                      color: Color(0xFF226C47),
                      height: 1.5,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _panel(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Votre trajet',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                _detail(
                  Icons.schedule,
                  'Départ prévu',
                  order.departureDate == null
                      ? 'Non renseigné'
                      : formatCourseDate(order.departureDate!),
                ),
                _detail(
                  Icons.trip_origin,
                  'Prise en charge',
                  order.departureAddress ?? 'Non renseignée',
                ),
                for (var index = 0; index < order.steps.length; index++)
                  _detail(
                    Icons.location_on_outlined,
                    'Étape ${index + 1}',
                    order.steps[index],
                  ),
                if (order.vehicule != null)
                  _detail(
                    Icons.directions_car_outlined,
                    'Véhicule',
                    order.vehicule!,
                  ),
                if (order.personNumber != null)
                  _detail(
                    Icons.people_outline,
                    'Passagers',
                    '${order.personNumber}',
                  ),
                if (order.suitcaseNumber != null)
                  _detail(
                    Icons.luggage_outlined,
                    'Bagages',
                    '${order.suitcaseNumber}',
                  ),
                if (order.precision != null && order.precision!.isNotEmpty)
                  _detail(Icons.notes, 'Instructions', order.precision!),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _panel(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Historique de la course',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                if (order.commandStatus.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Text('Aucune étape enregistrée pour le moment.'),
                  ),
                for (final event in order.commandStatus.reversed)
                  _detail(
                    Icons.history,
                    event.status.label,
                    '${formatCourseDate(event.date)}\n'
                    'GPS : ${event.location.latitude.toStringAsFixed(5)}, '
                    '${event.location.longitude.toStringAsFixed(5)}',
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const ValueKey('current-order-download-voucher'),
              onPressed: () => OrderPdfService.showDownloadModal(
                context: context,
                order: order,
              ),
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('Télécharger le bon de commande'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _navy,
                side: BorderSide(color: _navy),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF5F7F9),
    appBar: AppBar(
      title: const Text('Ma commande'),
      backgroundColor: _navy,
      foregroundColor: Colors.white,
    ),
    body: StreamBuilder<DriverOrder?>(
      stream: _order,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          final error = snapshot.error;
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off_outlined, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    error is FormatException
                        ? error.message
                        : error is FirebaseException
                        ? 'Chargement impossible (${error.code}).'
                        : 'Impossible de charger la commande.',
                    textAlign: TextAlign.center,
                  ),
                  TextButton(
                    onPressed: () => setState(
                      () => _order = widget.service.getOrderStream(
                        widget.orderId,
                      ),
                    ),
                    child: const Text('Réessayer'),
                  ),
                ],
              ),
            ),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final order = snapshot.data;
        if (order == null) {
          return const Center(child: Text('Cette commande n’existe plus.'));
        }
        if (order.historyError != null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                '${order.historyError}\n'
                'Les données doivent être corrigées avant de gérer cette commande.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        if (order.driverId != widget.driverId) {
          return const Center(
            child: Text('Cette commande ne vous est pas attribuée.'),
          );
        }
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: _content(order),
          ),
        );
      },
    ),
  );
}
