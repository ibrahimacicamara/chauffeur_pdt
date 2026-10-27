import 'package:chauffeur/screens/current_com.dart';
import 'package:chauffeur/services/firebase/driver_finance.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class StatistiquePage extends StatefulWidget {
  const StatistiquePage({
    super.key,
    required this.driverId,
    this.orderService,
    this.financeService,
  });

  final String driverId;
  final FireService? orderService;
  final DriverFinanceService? financeService;

  @override
  State<StatistiquePage> createState() => _StatistiquePageState();
}

class _StatistiquePageState extends State<StatistiquePage> {
  late FireService _ordersService;
  late DriverFinanceService _finance;
  late Stream<List<DriverOrder>> _orders;
  late Stream<List<DriverPayment>> _payments;

  @override
  void initState() {
    super.initState();
    _ordersService = widget.orderService ?? FireService();
    _finance = widget.financeService ?? DriverFinanceService();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant StatistiquePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.driverId != widget.driverId ||
        oldWidget.orderService != widget.orderService ||
        oldWidget.financeService != widget.financeService) {
      _ordersService = widget.orderService ?? FireService();
      _finance = widget.financeService ?? DriverFinanceService();
      _subscribe();
    }
  }

  void _subscribe() {
    _orders = _ordersService.getOrdersStream();
    _payments = _finance.watchPayments(widget.driverId);
  }

  Widget _error(Object? error, VoidCallback retry) {
    final message = error is FormatException
        ? error.message
        : error is FirebaseException
        ? 'Lecture impossible (${error.code}).'
        : 'Impossible de charger les données.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message, style: const TextStyle(color: Color(0xFFB42318))),
        TextButton(onPressed: retry, child: const Text('Réessayer')),
      ],
    );
  }

  Widget _panel({required String title, required Widget child}) => Card(
    color: Colors.white,
    elevation: 0,
    margin: const EdgeInsets.only(bottom: 16),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
      side: const BorderSide(color: Color(0xFFE2E7EC)),
    ),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );

  Widget _metric(IconData icon, String title, String value) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFFF4F6F8),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: const Color(0xFF9B783E)),
        const SizedBox(height: 12),
        Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(title, style: const TextStyle(color: Color(0xFF687787))),
      ],
    ),
  );

  Widget _grid(List<Widget> children) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 600 ? 3 : constraints.maxWidth >= 320 ? 2 : 1;
      final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: children.map((child) => SizedBox(width: width, child: child)).toList(),
      );
    },
  );

  Widget _courseStats(AsyncSnapshot<List<DriverOrder>> snapshot) => _panel(
    title: 'Mes courses',
    child: Builder(
      builder: (context) {
        if (snapshot.hasError) {
          return _error(snapshot.error, () => setState(() {
            _orders = _ordersService.getOrdersStream();
          }));
        }
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final orders = snapshot.data!;
        final mine = orders.where(
          (order) => order.historyError == null && order.driverId == widget.driverId,
        ).toList();
        final completed = mine.where((order) => order.currentStatus == OrderStatus.COMPLETED).length;
        final closed = {
          OrderStatus.COMPLETED,
          OrderStatus.CANCELLED,
          OrderStatus.NO_SHOW,
          OrderStatus.INTERRUPTED,
        };
        final active = mine.where((order) => !closed.contains(order.currentStatus)).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _grid([
              _metric(Icons.route_outlined, 'Courses attribuées', '${mine.length}'),
              _metric(Icons.check_circle_outline, 'Courses terminées', '$completed'),
              _metric(Icons.directions_car_outlined, 'Courses en cours', '$active'),
              _metric(Icons.cancel_outlined, 'Annulées / interrompues / absences', '${mine.length - completed - active}'),
            ]),
            if (orders.any((order) => order.historyError != null)) ...[
              const SizedBox(height: 12),
              const Text('Certaines commandes ont un historique invalide. Les statistiques peuvent être incomplètes.'),
            ],
            const SizedBox(height: 12),
            ExpansionTile(
              key: const ValueKey('course-details'),
              tilePadding: EdgeInsets.zero,
              title: const Text('Détail de mes courses'),
              children: [
                if (mine.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Aucune course attribuée.'),
                  ),
                for (final order in mine)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('Commande ${order.id}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(order.departureDate == null
                            ? 'Date non renseignée'
                            : formatCourseDate(order.departureDate!)),
                        Text(order.departureAddress ?? 'Départ non renseigné'),
                        for (var index = 0; index < order.steps.length; index++)
                          Text('${index + 1}. ${order.steps[index]}'),
                        Text('Statut : ${order.currentStatus.label}'),
                        Text(
                          order.price == null
                              ? 'Prix chauffeur non renseigné'
                              : order.price! < 0
                              ? 'Prix chauffeur invalide'
                              : 'Prix chauffeur : ${formatEuros(order.price! * 80)}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          order.currentStatus == OrderStatus.COMPLETED
                              ? 'Course incluse dans les gains.'
                              : 'Course non incluse dans les gains.',
                          style: const TextStyle(fontSize: 12, color: Color(0xFF687787)),
                        ),
                        const Divider(),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    ),
  );

  Widget _balance(
    AsyncSnapshot<List<DriverOrder>> orders,
    AsyncSnapshot<List<DriverPayment>> payments,
  ) {
    Widget content;
    if (orders.hasError || payments.hasError) {
      content = _error(
        orders.error ?? payments.error,
        () => setState(_subscribe),
      );
    } else if (!orders.hasData || !payments.hasData ||
        orders.connectionState == ConnectionState.waiting ||
        payments.connectionState == ConnectionState.waiting) {
      content = const Center(child: CircularProgressIndicator());
    } else {
      try {
        final cents = calculateDriverBalance(
          driverId: widget.driverId,
          orders: orders.data!,
          payments: payments.data!,
        );
        final earned = calculateDriverEarnings(
          driverId: widget.driverId,
          orders: orders.data!,
        );
        final onboard = completedOnboardOrders(widget.driverId, orders.data!)
            .fold<int>(0, (sum, order) => sum + onboardAmountCents(order));
        final transfers = payments.data!
            .where((payment) => payment.type == DriverPaymentType.transfer)
            .fold<int>(0, (sum, payment) => sum + payment.amountCents);
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              formatEuros(cents),
              key: const ValueKey('driver-balance'),
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w800,
                color: Color(0xFF142536),
              ),
            ),
            if (cents < 0)
              const Text('Montant à reverser à la société.'),
            ExpansionTile(
              key: const ValueKey('balance-details'),
              tilePadding: EdgeInsets.zero,
              title: const Text('Détail du solde'),
              childrenPadding: const EdgeInsets.only(bottom: 12),
              children: [
                _balanceLine('Gains des courses terminées (80 %)', earned),
                _balanceLine('Encaissements à bord déduits', -onboard),
                _balanceLine('Virements reçus déduits', -transfers),
                const Divider(),
                _balanceLine('Solde restant dû', cents),
              ],
            ),
          ],
        );
      } on FormatException catch (error) {
        content = _error(error, () => setState(_subscribe));
      }
    }
    return _panel(title: 'Solde restant dû', child: content);
  }

  Widget _balanceLine(String label, int cents) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text('$label : ${formatEuros(cents)}'),
    ),
  );

  Widget _paymentList(String title, List<DriverPayment> payments, String empty) => _panel(
    title: title,
    child: payments.isEmpty
        ? Text(empty)
        : Column(
            children: [
              for (final payment in payments)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    payment.type == DriverPaymentType.transfer
                        ? Icons.account_balance_outlined
                        : Icons.payments_outlined,
                    color: const Color(0xFF226C47),
                  ),
                  title: Text(formatEuros(payment.amountCents), style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                    '${formatCourseDate(payment.receivedAt)}'
                    '${payment.reference == null ? '' : '\nRéf. : ${payment.reference}'}',
                  ),
                  isThreeLine: payment.reference != null,
                ),
            ],
          ),
  );

  Widget _paymentStats(
    AsyncSnapshot<List<DriverPayment>> snapshot,
    AsyncSnapshot<List<DriverOrder>> orders,
  ) => Builder(
    builder: (context) {
      if (snapshot.hasError || orders.hasError) {
        return _panel(title: 'Mes paiements', child: _error(snapshot.error ?? orders.error, () => setState(_subscribe)));
      }
      if (!snapshot.hasData || !orders.hasData ||
          snapshot.connectionState == ConnectionState.waiting ||
          orders.connectionState == ConnectionState.waiting) {
        return _panel(title: 'Mes paiements', child: const Center(child: CircularProgressIndicator()));
      }
      final List<DriverOrder> onboard;
      try {
        onboard = completedOnboardOrders(widget.driverId, orders.data!);
      } on FormatException catch (error) {
        return _panel(title: 'Mes paiements', child: _error(error, () => setState(_subscribe)));
      }
      final transfers = snapshot.data!.where((p) => p.type == DriverPaymentType.transfer).toList();
      int total(List<DriverPayment> payments) => payments.fold(0, (sum, p) => sum + p.amountCents);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _panel(
            title: 'Argent reçu',
            child: _grid([
              _metric(Icons.payments_outlined, 'Encaissé à bord', formatEuros(
                onboard.fold<int>(0, (sum, order) => sum + onboardAmountCents(order)),
              )),
              _metric(Icons.account_balance_outlined, 'Virements reçus', formatEuros(total(transfers))),
            ]),
          ),
          _panel(
            title: 'Encaissements à bord',
            child: onboard.isEmpty
                ? const Text('Aucun encaissement à bord enregistré.')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final order in onboard)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Commande ${order.id}', style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text('Prix total : ${formatEuros(order.price! * 100)}'),
                              Text('Payé en ligne : ${formatEuros(order.checkoutAmountCents!)}'),
                              Text('Encaissé à bord : ${formatEuros(onboardAmountCents(order))}'),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          _paymentList('Virements de la société', transfers, 'Aucun virement reçu enregistré.'),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF4F6F8),
    appBar: AppBar(
      title: const Text('Mes statistiques'),
      backgroundColor: const Color(0xFF142536),
      foregroundColor: Colors.white,
      actions: [
        IconButton(
          tooltip: 'Actualiser',
          onPressed: () => setState(_subscribe),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: StreamBuilder<List<DriverOrder>>(
          key: ValueKey('orders-${widget.driverId}'),
          stream: _orders,
          builder: (context, orders) => StreamBuilder<List<DriverPayment>>(
            key: ValueKey('payments-${widget.driverId}'),
            stream: _payments,
            builder: (context, payments) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 20, top: 8),
              child: Text('Votre activité et vos finances\nDepuis le début • EUR', style: TextStyle(fontSize: 18, color: Color(0xFF687787))),
            ),
            _balance(orders, payments),
            _courseStats(orders),
            _paymentStats(payments, orders),
          ],
        ),
          ),
        ),
      ),
    ),
  );
}