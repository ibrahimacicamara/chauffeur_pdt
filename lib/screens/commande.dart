import 'package:chauffeur/screens/current_com.dart';
import 'package:chauffeur/screens/client_conversation_page.dart';
import 'package:chauffeur/screens/tablet_management_page.dart';
import 'package:chauffeur/screens/statistique.dart';
import 'package:chauffeur/screens/driver_profile_page.dart';
import 'package:chauffeur/services/firebase/driver_profile_service.dart';
import 'package:chauffeur/services/firebase/driver_reminder_service.dart';
import 'package:chauffeur/widgets/onboard_payment_warning.dart';
import 'package:chauffeur/services/firebase/driver_finance.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/services/location_service.dart';
import 'package:chauffeur/services/order_pdf_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class CommandePage extends StatefulWidget {
  const CommandePage({
    super.key,
    required this.driverId,
    this.service,
    this.locationService,
    this.onSignOut,
    this.onDownloadVoucher,
    this.reminderService,
  });

  final String driverId;
  final FireService? service;
  final LocationService? locationService;
  final DriverReminderService? reminderService;
  final Future<void> Function()? onSignOut;
  final Future<void> Function(BuildContext context, DriverOrder order)?
  onDownloadVoucher;

  @override
  State<CommandePage> createState() => _CommandePageState();
}

class _CommandePageState extends State<CommandePage> {
  late FireService _service;
  late LocationService _locationService;
  late Stream<List<DriverOrder>> _orders;
  final _pending = <String>{};
  final _chosen = <String>{};
  int _selectedTab = 0;

  bool _isMyOrder(DriverOrder order) =>
      order.driverId == widget.driverId ||
      (order.driverId == null &&
          order.commandStatus.isEmpty &&
          _chosen.contains(order.id));

  bool _isAssigned(DriverOrder order) =>
      order.driverId != null || _isMyOrder(order);

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? FireService();
    _locationService = widget.locationService ?? LocationService();
    _orders = _service.getOrdersForDriverStream(widget.driverId).map((orders) {
      for (final order in orders) {
        if (order.driverId != null || order.commandStatus.isNotEmpty) {
          _chosen.remove(order.id);
        }
      }
      return orders;
    });
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _downloadVoucher(DriverOrder order) async {
    if (widget.onDownloadVoucher != null) {
      await widget.onDownloadVoucher!(context, order);
      return;
    }
    OrderPdfService.showDownloadModal(context: context, order: order);
  }

  Future<void> _choose(DriverOrder order) async {
    if (_pending.contains(order.id) || _chosen.contains(order.id)) return;
    setState(() => _pending.add(order.id));
    try {
      final location = await _locationService.currentPosition();
      await _service.chooseOrder(order.id, location: location);
      if (!mounted) return;
      setState(() => _chosen.add(order.id));
      _message('La commande vous est attribuée.');
    } on StateError catch (error) {
      _message(error.message);
    } on FirebaseException catch (error) {
      _message(
        error.code == 'permission-denied'
            ? 'Vous n’avez pas l’autorisation de choisir cette commande.'
            : 'Attribution impossible (${error.code}). Réessayez.',
      );
    } catch (_) {
      _message('Impossible de récupérer la position GPS. Réessayez.');
    } finally {
      if (mounted) setState(() => _pending.remove(order.id));
    }
  }

  Widget _detail(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: const Color(0xFF687787)),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );

  Widget _badge(IconData icon, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFFF2F5F7),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: const Color(0xFF687787)),
        const SizedBox(width: 6),
        Flexible(child: Text(text, style: const TextStyle(fontSize: 12))),
      ],
    ),
  );

  Widget _card(DriverOrder order) {
    final isMyOrder = _isMyOrder(order);
    final isOtherDriver = !isMyOrder && order.driverId != null;
    final isAvailable = !_isAssigned(order);
    final vehicle = order.vehicule?.trim();
    final hasVehicle = vehicle != null && vehicle.isNotEmpty;
    final busy = _pending.contains(order.id);
    final statusColor = isMyOrder
        ? const Color(0xFF226C47)
        : isOtherDriver
        ? const Color(0xFF687787)
        : const Color(0xFF805500);
    return Card(
      key: ValueKey('order-card-${order.id}'),
      margin: EdgeInsets.zero,
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFE2E7EC)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Commande ${order.id}',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: Color(0xFF687787),
              ),
            ),
            const SizedBox(height: 8),
            if (!isAvailable)
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      isMyOrder
                          ? 'Votre commande'
                          : isOtherDriver
                          ? 'Déjà attribuée'
                          : 'Disponible',
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (order.historyError == null && order.driverId != null)
                    Text(
                      order.currentStatus.label,
                      style: const TextStyle(fontSize: 12),
                    )
                  else if (order.status != null)
                    Text(order.status!, style: const TextStyle(fontSize: 12)),
                ],
              ),
            _detail(
              Icons.schedule,
              order.departureDate == null
                  ? 'Date non renseignée'
                  : formatCourseDate(order.departureDate!),
            ),
            _detail(
              Icons.trip_origin,
              order.departureAddress ?? 'Départ non renseigné',
            ),
            for (var index = 0; index < order.steps.length; index++)
              _detail(
                Icons.location_on_outlined,
                '${index + 1}. ${order.steps[index]}',
              ),
            if (!isAvailable &&
                (order.vehicule != null ||
                    order.personNumber != null ||
                    order.suitcaseNumber != null)) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (order.vehicule != null)
                    _badge(Icons.directions_car_outlined, order.vehicule!),
                  if (!isAvailable && order.personNumber != null)
                    _badge(
                      Icons.people_outline,
                      '${order.personNumber} passager(s)',
                    ),
                  if (!isAvailable && order.suitcaseNumber != null)
                    _badge(
                      Icons.luggage_outlined,
                      '${order.suitcaseNumber} bagage(s)',
                    ),
                ],
              ),
            ],
            if (order.historyError != null)
              _detail(Icons.warning_amber_outlined, order.historyError!),
            if (order.precision != null && order.precision!.trim().isNotEmpty)
              _detail(Icons.notes, order.precision!),
            if (isAvailable)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    key: ValueKey('available-summary-${order.id}'),
                    children: [
                      _fare(order, compact: true),
                      const SizedBox(width: 8),
                      _badge(
                        hasVehicle
                            ? Icons.directions_car_outlined
                            : Icons.category_outlined,
                        hasVehicle
                            ? vehicle
                            : order.category ?? 'Catégorie non renseignée',
                      ),
                      const SizedBox(width: 8),
                      _badge(
                        Icons.people_outline,
                        order.personNumber == null
                            ? 'Passagers non renseignés'
                            : '${order.personNumber} passager(s)',
                      ),
                      const SizedBox(width: 8),
                      _badge(
                        Icons.luggage_outlined,
                        order.suitcaseNumber == null
                            ? 'Bagages non renseignés'
                            : '${order.suitcaseNumber} bagage(s)',
                      ),
                    ],
                  ),
                ),
              )
            else
              _fare(order),
            OnboardPaymentWarning(order: order, compact: true),
            const SizedBox(height: 10),
            if (isMyOrder)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    key: ValueKey('manage-${order.id}'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => CurrentCommandePage(
                          orderId: order.id,
                          driverId: widget.driverId,
                          service: _service,
                          locationService: _locationService,
                          reminderService: widget.reminderService,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.route_outlined, size: 18),
                    label: const Text('Gérer ma commande'),
                  ),
                  TextButton.icon(
                    key: ValueKey('download-voucher-${order.id}'),
                    onPressed: () => _downloadVoucher(order),
                    icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                    label: const Text('Télécharger le bon de commande'),
                  ),
                ],
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: ValueKey('choose-${order.id}'),
                onPressed: isMyOrder || isOtherDriver || busy
                    ? null
                    : () => _choose(order),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFD5B477),
                  foregroundColor: const Color(0xFF142536),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                icon: busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        isMyOrder
                            ? Icons.check_circle_outline
                            : isOtherDriver
                            ? Icons.lock_outline
                            : Icons.add_task,
                      ),
                label: Text(
                  busy
                      ? 'Attribution en cours…'
                      : isMyOrder
                      ? 'Commande choisie'
                      : isOtherDriver
                      ? 'Déjà attribuée'
                      : 'Choisir cette commande',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fare(DriverOrder order, {bool compact = false}) {
    final price = order.price;
    if (price == null) {
      return compact
          ? const Text('Prix non renseigné')
          : _detail(Icons.payments_outlined, 'Prix non renseigné');
    }
    if (price < 0) {
      if (compact) {
        return const Text(
          'Prix invalide : le montant de la course ne peut pas être négatif.',
        );
      }
      return _detail(
        Icons.warning_amber_outlined,
        'Prix invalide : le montant de la course ne peut pas être négatif.',
      );
    }
    final driverCents = price * 80;
    if (compact) {
      return Text(
        formatEuros(driverCents).replaceFirst(' EUR', ' €'),
        style: const TextStyle(
          color: Color(0xFF226C47),
          fontWeight: FontWeight.w700,
          fontSize: 17,
        ),
      );
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7F9),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        'Prix chauffeur : ${formatEuros(driverCents)}',
        style: const TextStyle(
          color: Color(0xFF226C47),
          fontWeight: FontWeight.w700,
          fontSize: 17,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      backgroundColor: const Color(0xFFF5F7F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFF142536),
        foregroundColor: Colors.white,
        title: const Text('Commandes'),
        bottom: TabBar(
          onTap: (index) => setState(() => _selectedTab = index),
          labelColor: const Color(0xFFD5B477),
          unselectedLabelColor: Colors.white70,
          indicatorColor: const Color(0xFFD5B477),
          tabs: const [
            Tab(
              text: 'Courses disponibles',
              icon: Icon(Icons.local_taxi_outlined),
            ),
            Tab(
              text: 'Courses attribuées',
              icon: Icon(Icons.assignment_outlined),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Tablettes associées',
            icon: const Icon(Icons.tablet_android),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => TabletManagementPage(driverId: widget.driverId),
            )),
          ),
          IconButton(
            tooltip: 'Mon profil',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => DriverProfilePage(
                  driverId: widget.driverId,
                  service:
                      _service.profileService ??
                      DriverProfileService(firestore: _service.firestore),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Mes statistiques',
            icon: const Icon(Icons.bar_chart_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => StatistiquePage(
                  driverId: widget.driverId,
                  orderService: _service,
                ),
              ),
            ),
          ),
          if (widget.onSignOut != null)
            IconButton(
              tooltip: 'Se déconnecter',
              icon: const Icon(Icons.logout),
              onPressed: widget.onSignOut,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey('client-conversation-fab'),
        tooltip: 'Conversation client',
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ClientConversationPage(driverId: widget.driverId),
        )),
        child: const Icon(Icons.forum_outlined),
      ),
      body: StreamBuilder<List<DriverOrder>>(
        stream: _orders,
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
                      error is StateError
                          ? error.message
                          : error is FormatException
                          ? error.message
                          : error is FirebaseException
                          ? 'Impossible de charger les commandes (${error.code}).'
                          : 'Impossible de charger les commandes. Réessayez.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: () => setState(
                        () => _orders = _service.getOrdersForDriverStream(
                          widget.driverId,
                        ),
                      ),
                      child: const Text('Réessayer'),
                    ),
                  ],
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final orders = snapshot.data!
              .where(
                (order) =>
                    _selectedTab == 1 ? _isMyOrder(order) : !_isAssigned(order),
              )
              .toList();
          if (orders.isEmpty) {
            return RefreshIndicator(
              onRefresh: () async {
                setState(
                  () => _orders = _service.getOrdersForDriverStream(
                    widget.driverId,
                  ),
                );
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const SizedBox(height: 120),
                  Center(
                    child: Text(
                      _selectedTab == 0
                          ? 'Aucune course disponible pour le moment.'
                          : 'Aucune course attribuée pour le moment.',
                      style: const TextStyle(
                        fontSize: 16,
                        color: Color(0xFF687787),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              setState(
                () => _orders = _service.getOrdersForDriverStream(
                  widget.driverId,
                ),
              );
            },
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  itemCount: orders.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) => _card(orders[index]),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}
