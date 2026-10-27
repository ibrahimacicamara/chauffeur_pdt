import 'package:chauffeur/services/firebase/driver_finance.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final date = DateTime.utc(2026, 10, 12);
  Map<String, dynamic> payment() => {
    'type': 'onboard',
    'currency': 'EUR',
    'amountCents': 4567,
    'receivedAt': Timestamp.fromDate(date),
    'reference': 'COM-123',
  };

  test('formats exact cents, zero and negative balance', () {
    expect(formatEuros(4567), '45,67 EUR');
    expect(formatEuros(-1), '-0,01 EUR');
    expect(formatEuros(0), '0,00 EUR');
    expect(formatEuros(125050), '1250,50 EUR');
  });

  test(
    'balance deducts all confirmed receipts from completed driver earnings',
    () {
      final orders = [
        const DriverOrder(
          id: 'done',
          driverId: 'me',
          status: 'Terminée',
          price: 19,
          paymentPlan: 'reservation_fee',
          checkoutAmountCents: 900,
        ),
        const DriverOrder(id: 'active', driverId: 'me', price: 1000),
        const DriverOrder(
          id: 'cancelled',
          driverId: 'me',
          status: 'Annulée',
          price: 1000,
        ),
        const DriverOrder(
          id: 'other',
          driverId: 'other',
          status: 'Terminée',
          price: 1000,
        ),
      ];
      final payments = [
        DriverPayment(
          id: 'onboard',
          type: DriverPaymentType.onboard,
          amountCents: 501,
          receivedAt: date,
        ),
        DriverPayment(
          id: 'transfer',
          type: DriverPaymentType.transfer,
          amountCents: 200,
          receivedAt: date,
        ),
      ];
      expect(
        calculateDriverBalance(
          driverId: 'me',
          orders: orders,
          payments: payments,
        ),
        320,
      );
      expect(
        calculateDriverBalance(driverId: 'me', orders: [], payments: payments),
        -200,
      );
      expect(
        calculateDriverBalance(driverId: 'me', orders: [], payments: []),
        0,
      );
    },
  );

  test('incomplete or invalid course data blocks a misleading balance', () {
    for (final order in [
      const DriverOrder(id: 'missing', driverId: 'me', status: 'Terminée'),
      const DriverOrder(
        id: 'negative',
        driverId: 'me',
        status: 'Terminée',
        price: -1,
      ),
      const DriverOrder(id: 'invalid', historyError: 'Invalid history'),
    ]) {
      expect(
        () => calculateDriverBalance(
          driverId: 'me',
          orders: [order],
          payments: [],
        ),
        throwsFormatException,
      );
    }
  });

  test('100 EUR with 9 EUR paid online deducts 91 EUR, not the 80 EUR driver share', () {
    final order = DriverOrder.fromFirestore('reservation', {
      'driverId': 'me',
      'status': 'Terminée',
      'price': 100,
      'paymentPlan': 'reservation_fee',
      'checkoutAmountCents': 900,
    });
    expect(onboardAmountCents(order), 9100);
    expect(calculateDriverBalance(driverId: 'me', orders: [order], payments: []), -1100);
    expect(
      () => DriverOrder.fromFirestore('invalid', {'checkoutAmountCents': 9.5}),
      throwsFormatException,
    );
    for (final checkout in <int?>[null, -1, 10001]) {
      expect(
        () => calculateDriverBalance(
          driverId: 'me',
          orders: [
            DriverOrder(
              id: 'bad-checkout', driverId: 'me', status: 'Terminée',
              price: 100, paymentPlan: 'reservation_fee', checkoutAmountCents: checkout,
            ),
          ],
          payments: [],
        ),
        throwsFormatException,
      );
    }
    expect(onboardAmountCents(const DriverOrder(id: 'fully-paid', price: 100, checkoutAmountCents: 10000)), 0);
  });

  test('parses authoritative balance including debt', () {
    final account = DriverAccount.fromFirestore({
      'currency': 'EUR',
      'balanceCents': -12345,
      'updatedAt': Timestamp.fromDate(date),
    });
    expect(account.balanceCents, -12345);
    expect(account.updatedAt.toUtc(), date);
  });

  test('parses each received payment type', () {
    final onboard = DriverPayment.fromFirestore('p1', payment());
    expect(onboard.type, DriverPaymentType.onboard);
    expect(onboard.amountCents, 4567);
    expect(onboard.reference, 'COM-123');
    expect(onboard.receivedAt.toUtc(), date);
    final transfer = DriverPayment.fromFirestore('p2', {
      ...payment(),
      'type': 'transfer',
      'reference': null,
    });
    expect(transfer.type, DriverPaymentType.transfer);
    expect(transfer.reference, isNull);
  });

  test('rejects unknown, missing or invalid financial fields', () {
    for (final change in <Map<String, dynamic>>[
      {'amountCents': null},
      {'amountCents': 45.67},
      {'amountCents': -10},
      {'amountCents': 0},
      {'currency': 'USD'},
      {'type': 'pending'},
      {'receivedAt': '2026-10-12'},
      {'reference': 42},
    ]) {
      expect(
        () => DriverPayment.fromFirestore('bad', {...payment(), ...change}),
        throwsFormatException,
      );
    }
    expect(() => DriverAccount.fromFirestore({}), throwsFormatException);
    expect(
      () => DriverAccount.fromFirestore({
        'currency': 'EUR',
        'balanceCents': 12.5,
        'updatedAt': Timestamp.fromDate(date),
      }),
      throwsFormatException,
    );
  });

  test('rejects invalid driver document paths before accessing Firebase', () {
    final service = DriverFinanceService();
    expect(() => service.watchAccount(''), throwsArgumentError);
    expect(() => service.watchPayments('a/b'), throwsArgumentError);
  });
}
