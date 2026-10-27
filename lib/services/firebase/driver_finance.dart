import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/services/hive/hive_database.dart';

int calculateDriverEarnings({
  required String driverId,
  required List<DriverOrder> orders,
}) {
  var earnedCents = 0;
  for (final order in orders) {
    if (order.historyError != null) {
      throw const FormatException(
        'Solde indisponible : certaines commandes ont un historique invalide.',
      );
    }
    if (order.driverId != driverId ||
        order.currentStatus != OrderStatus.COMPLETED) {
      continue;
    }
    final price = order.price;
    if (price == null || price < 0) {
      throw FormatException(
        'Solde indisponible : prix manquant ou invalide pour la course ${order.id}.',
      );
    }
    earnedCents += price * 80;
  }
  return earnedCents;
}

int onboardAmountCents(DriverOrder order) {
  final price = order.price;
  final checkout = order.checkoutAmountCents;
  if (price == null || price < 0 ||
      checkout == null || checkout < 0 || checkout > price * 100) {
    throw FormatException(
      'Encaissement à bord indisponible : prix ou checkoutAmountCents '
      'manquant ou invalide pour la course ${order.id}.',
    );
  }
  return price * 100 - checkout;
}

List<DriverOrder> completedOnboardOrders(String driverId, List<DriverOrder> orders) {
  calculateDriverEarnings(driverId: driverId, orders: orders);
  final onboard = orders.where(
    (order) => order.driverId == driverId &&
        order.currentStatus == OrderStatus.COMPLETED &&
        order.hasOnboardPayment,
  ).toList();
  for (final order in onboard) {
    onboardAmountCents(order);
  }
  return onboard;
}

int calculateDriverBalance({
  required String driverId,
  required List<DriverOrder> orders,
  required List<DriverPayment> payments,
}) {
  final earnings = calculateDriverEarnings(driverId: driverId, orders: orders);
  final onboard = completedOnboardOrders(driverId, orders)
      .fold<int>(0, (sum, order) => sum + onboardAmountCents(order));
  final transfers = payments
      .where((payment) => payment.type == DriverPaymentType.transfer)
      .fold<int>(0, (sum, payment) => sum + payment.amountCents);
  return earnings - onboard - transfers;
}

String formatEuros(int cents) {
  final absolute = cents.abs();
  return '${cents < 0 ? '-' : ''}${absolute ~/ 100},'
      '${(absolute % 100).toString().padLeft(2, '0')} EUR';
}

int _cents(Map<String, dynamic> data, String field, String document) {
  final value = data[field];
  if (value is! int) {
    throw FormatException(
      '$document : $field doit être un entier en centimes.',
    );
  }
  return value;
}

DateTime _date(Object? value, String document) {
  if (value is Timestamp) return value.toDate();
  throw FormatException('$document : date Firestore invalide.');
}

class DriverAccount {
  const DriverAccount({required this.balanceCents, required this.updatedAt});

  final int balanceCents;
  final DateTime updatedAt;

  factory DriverAccount.fromFirestore(Map<String, dynamic> data) {
    if (data['currency'] != 'EUR') {
      throw const FormatException('Solde : devise EUR requise.');
    }
    return DriverAccount(
      balanceCents: _cents(data, 'balanceCents', 'Solde'),
      updatedAt: _date(data['updatedAt'], 'Solde'),
    );
  }
}

enum DriverPaymentType { onboard, transfer }

class DriverPayment {
  const DriverPayment({
    required this.id,
    required this.type,
    required this.amountCents,
    required this.receivedAt,
    this.reference,
  });

  final String id;
  final DriverPaymentType type;
  final int amountCents;
  final DateTime receivedAt;
  final String? reference;

  factory DriverPayment.fromFirestore(String id, Map<String, dynamic> data) {
    final type = switch (data['type']) {
      'onboard' => DriverPaymentType.onboard,
      'transfer' => DriverPaymentType.transfer,
      _ => throw FormatException('Paiement $id : type invalide.'),
    };
    if (data['currency'] != 'EUR') {
      throw FormatException('Paiement $id : devise EUR requise.');
    }
    final amount = _cents(data, 'amountCents', 'Paiement $id');
    if (amount <= 0) {
      throw FormatException(
        'Paiement $id : montant reçu strictement positif requis.',
      );
    }
    final reference = data['reference'];
    if (reference != null && reference is! String) {
      throw FormatException('Paiement $id : référence invalide.');
    }
    return DriverPayment(
      id: id,
      type: type,
      amountCents: amount,
      receivedAt: _date(data['receivedAt'], 'Paiement $id'),
      reference: reference as String?,
    );
  }
}

class DriverFinanceService {
  DriverFinanceService({FirebaseFirestore? firestore}) : _firestore = firestore;

  final FirebaseFirestore? _firestore;

  DocumentReference<Map<String, dynamic>> _driver(String driverId) {
    if (driverId.trim().isEmpty || driverId.contains('/')) {
      throw ArgumentError.value(driverId, 'driverId', 'UID chauffeur invalide');
    }
    return (_firestore ?? FirebaseFirestore.instance)
        .collection('Drivers')
        .doc(driverId);
  }

  Stream<DriverAccount?> watchAccount(String driverId) =>
      _driver(driverId)
          .collection('finance')
          .doc('summary')
          .snapshots()
          .map((snapshot) {
            final data = snapshot.data();
            return data == null ? null : DriverAccount.fromFirestore(data);
          });

  Stream<List<DriverPayment>> watchPayments(String driverId) =>
      _driver(driverId).collection('payments').snapshots().map((snapshot) {
        final payments = snapshot.docs
            .where((doc) => doc.data()['type'] != 'onboard')
            .map((doc) => DriverPayment.fromFirestore(doc.id, doc.data()))
            .toList();
        payments.sort((a, b) {
          final byDate = b.receivedAt.compareTo(a.receivedAt);
          return byDate == 0 ? a.id.compareTo(b.id) : byDate;
        });
        return payments;
      });
}
