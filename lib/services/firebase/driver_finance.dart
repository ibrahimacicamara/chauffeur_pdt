import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/services/hive/hive_database.dart';

/// Comptabilité chauffeur alignée sur le contrat administrateur
/// (ADMIN_DRIVER_ACCOUNT_HANDOFF.md, 7 novembre 2026).
///
/// Tous les calculs sont réalisés en centimes :
///   rémunération  = somme de round(driverPrice * 100) des courses terminées
///   encaissement  = max(0, round(driverPrice * 100) - paidOnlineCents)
///   solde         = rémunération - encaissements - virements - espèces
/// Aucun solde n'est stocké côté serveur : il est dérivé des deux sources.

/// Paiement saisi par l'administrateur dans
/// `Drivers/{driverId}/Payments/{paymentId}`. Lecture seule côté chauffeur.
enum DriverPaymentMethod { transfer, cash }

class DriverPayment {
  const DriverPayment({
    required this.id,
    required this.method,
    required this.amountCents,
    required this.date,
    this.note,
    this.administratorId,
  });

  final String id;
  final DriverPaymentMethod method;
  final int amountCents;
  final DateTime date;
  final String? note;
  final String? administratorId;

  factory DriverPayment.fromFirestore(String id, Map<String, dynamic> data) {
    final method = switch (data['method']) {
      'transfer' => DriverPaymentMethod.transfer,
      'cash' => DriverPaymentMethod.cash,
      _ => throw FormatException('Paiement $id : méthode invalide.'),
    };
    final amount = data['amountCents'];
    if (amount is! int || amount <= 0) {
      throw FormatException(
        'Paiement $id : montant en centimes strictement positif requis.',
      );
    }
    final date = data['date'];
    if (date is! Timestamp) {
      throw FormatException('Paiement $id : date Firestore invalide.');
    }
    final paidAt = date.toDate();
    if (paidAt.isAfter(DateTime.now())) {
      throw FormatException('Paiement $id : la date ne peut pas être future.');
    }
    final note = data['note'];
    if (note != null && note is! String) {
      throw FormatException('Paiement $id : note invalide.');
    }
    final administratorId = data['administratorId'];
    if (administratorId is! String || administratorId.trim().isEmpty) {
      throw FormatException('Paiement $id : administrateur invalide.');
    }
    return DriverPayment(
      id: id,
      method: method,
      amountCents: amount,
      date: paidAt,
      note: note as String?,
      administratorId: administratorId,
    );
  }
}

/// Montant encaissé à bord pour une course payable à bord, en centimes.
/// `paidOnlineCents` absent vaut zéro.
int onboardAmountCents(DriverOrder order) {
  final price = order.driverPriceCents;
  final paidOnline = order.paidOnlineCents ?? 0;
  if (price == null || price < 0 || paidOnline < 0) {
    throw FormatException(
      'Encaissement à bord indisponible : rémunération chauffeur ou paidOnlineCents '
      'manquant ou invalide pour la course ${order.id}.',
    );
  }
  return max(0, price - paidOnline);
}

class DriverFinanceSummary {
  const DriverFinanceSummary({
    required this.earningsCents,
    required this.onboardCents,
    required this.transfersCents,
    required this.cashCents,
    required this.onboardOrders,
    required this.issues,
  });

  /// Rémunérations stockées des courses terminées.
  final int earningsCents;

  /// Encaissements à bord des courses terminées payables à bord.
  final int onboardCents;

  /// Virements saisis par l'administrateur.
  final int transfersCents;

  /// Espèces remises par l'administrateur.
  final int cashCents;

  /// Courses terminées payables à bord dont l'encaissement est connu.
  final List<DriverOrder> onboardOrders;

  /// Données manquantes ou invalides : le solde est alors provisoire,
  /// jamais inventé ni remplacé par zéro.
  final List<String> issues;

  int get balanceCents =>
      earningsCents - onboardCents - transfersCents - cashCents;

  bool get isProvisional => issues.isNotEmpty;
}

/// Dérive le solde signé du chauffeur à partir des courses et du journal des
/// paiements administrateur. Un solde positif est dû au chauffeur ; un solde
/// négatif est à reverser à l'administrateur. Ne pas limiter le solde à zéro.
DriverFinanceSummary summarizeDriverFinance({
  required String driverId,
  required List<DriverOrder> orders,
  required List<DriverPayment> payments,
}) {
  var earnings = 0;
  var onboard = 0;
  final onboardOrders = <DriverOrder>[];
  final issues = <String>[];
  for (final order in orders) {
    if (order.historyError != null) {
      issues.add(
        'Commande ${order.id} : historique invalide, course non comptabilisée.',
      );
      continue;
    }
    final OrderStatus status;
    try {
      status = order.currentStatus;
    } on FormatException catch (error) {
      issues.add(error.message);
      continue;
    }
    if (order.driverId != driverId || status != OrderStatus.COMPLETED) {
      continue;
    }
    final earned = order.driverPriceCents;
    if (earned == null || earned < 0) {
      issues.add(
        'Commande ${order.id} : rémunération chauffeur inconnue ou invalide.',
      );
    } else {
      earnings += earned;
    }
    if (order.isOnboardPaymentMethod) {
      try {
        onboard += onboardAmountCents(order);
        onboardOrders.add(order);
      } on FormatException catch (error) {
        issues.add(error.message);
      }
    }
  }
  var transfers = 0;
  var cash = 0;
  for (final payment in payments) {
    switch (payment.method) {
      case DriverPaymentMethod.transfer:
        transfers += payment.amountCents;
      case DriverPaymentMethod.cash:
        cash += payment.amountCents;
    }
  }
  return DriverFinanceSummary(
    earningsCents: earnings,
    onboardCents: onboard,
    transfersCents: transfers,
    cashCents: cash,
    onboardOrders: onboardOrders,
    issues: issues,
  );
}

String formatEuros(int cents) {
  final absolute = cents.abs();
  return '${cents < 0 ? '-' : ''}${absolute ~/ 100},'
      '${(absolute % 100).toString().padLeft(2, '0')} EUR';
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

  /// Journal des paiements administrateur, trié par date côté client.
  /// Lecture seule : aucun paiement n'est saisi depuis cette application.
  Stream<List<DriverPayment>> watchPayments(String driverId) =>
      _driver(driverId).collection('Payments').snapshots().map((snapshot) {
        final payments = snapshot.docs
            .map((doc) => DriverPayment.fromFirestore(doc.id, doc.data()))
            .toList();
        payments.sort((a, b) {
          final byDate = b.date.compareTo(a.date);
          return byDate == 0 ? a.id.compareTo(b.id) : byDate;
        });
        return payments;
      });
}
