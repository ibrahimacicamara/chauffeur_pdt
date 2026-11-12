import 'package:chauffeur/services/firebase/driver_finance.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final date = DateTime.utc(2026, 11, 7);
  Map<String, dynamic> payment() => {
    'method': 'transfer',
    'amountCents': 4567,
    'date': Timestamp.fromDate(date),
    'note': 'VIR-1',
    'administratorId': 'admin-1',
  };

  test('formats exact cents, zero and negative balance', () {
    expect(formatEuros(4567), '45,67 EUR');
    expect(formatEuros(-1), '-0,01 EUR');
    expect(formatEuros(0), '0,00 EUR');
    expect(formatEuros(125050), '1250,50 EUR');
  });

  test(
    'uses history dates, not array order, for assignment and current status',
    () {
      final order = DriverOrder.fromFirestore('dated', {
        'commandStatus': [
          {
            'status': 'OrderStatus.EN_ROUTE',
            'id': 'driver-new',
            'date': Timestamp.fromDate(DateTime.utc(2026, 11, 7)),
            'location': {'latitude': 48, 'longitude': 2},
          },
          {
            'status': 'OrderStatus.COMPLETED',
            'id': 'driver-old',
            'date': Timestamp.fromDate(DateTime.utc(2026, 11, 6)),
            'location': {'latitude': 48, 'longitude': 2},
          },
        ],
      });
      expect(order.driverId, 'driver-new');
      expect(order.currentStatus, OrderStatus.EN_ROUTE);

      final released = DriverOrder.fromFirestore('released', {
        'commandStatus': [
          {
            'status': 'OrderStatus.ASSIGNED',
            'id': 'driver-new',
            'date': Timestamp.fromDate(DateTime.utc(2026, 11, 6)),
            'location': {'latitude': 48, 'longitude': 2},
          },
          {
            'status': 'OrderStatus.PENDING_ASSIGNMENT',
            'id': '',
            'date': Timestamp.fromDate(DateTime.utc(2026, 11, 7)),
            'location': {'latitude': 48, 'longitude': 2},
          },
        ],
      });
      expect(released.driverId, isNull);
      expect(released.currentStatus, OrderStatus.PENDING_ASSIGNMENT);
    },
  );

  test('normalizes legacy statuses before filtering courses', () {
    expect(
      DriverOrder.fromFirestore('pending', {'status': 'pending'}).currentStatus,
      OrderStatus.PENDING_ASSIGNMENT,
    );
    expect(
      DriverOrder.fromFirestore('in-progress', {
        'status': 'En cours',
      }).currentStatus,
      OrderStatus.EN_ROUTE,
    );
  });

  test('balance derives the signed total from stored driver prices and the admin journal', () {
    final orders = [
      const DriverOrder(
        id: 'done',
        driverId: 'me',
        status: 'Terminée',
        price: 19,
        driverPrice: 3.8,
        paymentMethod: 'à bord',
        paidOnlineCents: 900,
      ),
      const DriverOrder(
        id: 'active',
        driverId: 'me',
        price: 1000,
        driverPrice: 200,
      ),
      const DriverOrder(
        id: 'cancelled',
        driverId: 'me',
        status: 'Annulée',
        price: 1000,
        driverPrice: 200,
      ),
      const DriverOrder(
        id: 'other',
        driverId: 'other',
        status: 'Terminée',
        price: 1000,
        driverPrice: 200,
      ),
    ];
    final payments = [
      DriverPayment(
        id: 'transfer',
        method: DriverPaymentMethod.transfer,
        amountCents: 200,
        date: date,
      ),
      DriverPayment(
        id: 'cash',
        method: DriverPaymentMethod.cash,
        amountCents: 150,
        date: date,
      ),
    ];
    final summary = summarizeDriverFinance(
      driverId: 'me',
      orders: orders,
      payments: payments,
    );
    expect(summary.earningsCents, 380);
    expect(summary.onboardCents, 0);
    expect(summary.transfersCents, 200);
    expect(summary.cashCents, 150);
    expect(summary.balanceCents, 30);
    expect(summary.isProvisional, isFalse);
    expect(summary.onboardOrders.map((order) => order.id), ['done']);
    final onlyPayments = summarizeDriverFinance(
      driverId: 'me',
      orders: [],
      payments: payments,
    );
    expect(onlyPayments.balanceCents, -350);
    final empty = summarizeDriverFinance(
      driverId: 'me',
      orders: [],
      payments: [],
    );
    expect(empty.balanceCents, 0);
    expect(empty.isProvisional, isFalse);
  });

  test('balance rounds stored driver prices and excludes unrelated or unfinished courses', () {
    final summary = summarizeDriverFinance(
      driverId: 'me',
      orders: [
        const DriverOrder(
          id: 'completed',
          driverId: 'me',
          status: 'Terminée',
          price: 1000,
          driverPrice: 3.335,
        ),
        const DriverOrder(
          id: 'active',
          driverId: 'me',
          price: 100,
          driverPrice: 90,
          paymentMethod: 'à bord',
        ),
        const DriverOrder(
          id: 'cancelled',
          driverId: 'me',
          status: 'Annulée',
          price: 100,
          driverPrice: 90,
          paymentMethod: 'à bord',
        ),
        const DriverOrder(
          id: 'other-driver',
          driverId: 'other',
          status: 'Terminée',
          price: 100,
          driverPrice: 90,
          paymentMethod: 'à bord',
        ),
        const DriverOrder(
          id: 'onboard-overpaid',
          driverId: 'me',
          status: 'Terminée',
          price: 10,
          driverPrice: 1,
          paymentMethod: 'cash on delivery',
          paidOnlineCents: 1500,
        ),
      ],
      payments: [
        DriverPayment(
          id: 'transfer',
          method: DriverPaymentMethod.transfer,
          amountCents: 100,
          date: date,
        ),
      ],
    );

    expect(summary.earningsCents, 434);
    expect(summary.onboardCents, 0);
    expect(summary.transfersCents, 100);
    expect(summary.balanceCents, 334);
    expect(summary.isProvisional, isFalse);
    expect(summary.onboardOrders.map((order) => order.id), [
      'onboard-overpaid',
    ]);
  });

  test('missing remuneration or history yields a provisional balance, never an invented one', () {
    final summary = summarizeDriverFinance(
      driverId: 'me',
      orders: [
        const DriverOrder(
          id: 'no-pay',
          driverId: 'me',
          status: 'Terminée',
          price: 50,
          paymentMethod: 'onboard',
        ),
        const DriverOrder(id: 'bad', historyError: 'Invalid history'),
        const DriverOrder(
          id: 'no-price',
          driverId: 'me',
          status: 'Terminée',
          driverPrice: 10,
          paymentMethod: 'à bord',
        ),
      ],
      payments: const [],
    );
    expect(summary.isProvisional, isTrue);
    expect(summary.issues, hasLength(3));
    expect(summary.issues.join(), contains('no-pay'));
    expect(summary.issues.join(), contains('bad'));
    expect(summary.issues.join(), isNot(contains('no-price')));
    expect(summary.earningsCents, 1000);
    expect(summary.onboardCents, 1000);
    expect(summary.balanceCents, 0);

    final negative = summarizeDriverFinance(
      driverId: 'me',
      orders: [
        const DriverOrder(
          id: 'neg',
          driverId: 'me',
          status: 'Terminée',
          driverPrice: -1,
        ),
      ],
      payments: const [],
    );
    expect(negative.isProvisional, isTrue);
    expect(negative.earningsCents, 0);
  });

  test('onboard amount uses the driver price, treats absent online payment as zero and never goes negative', () {
    expect(
      onboardAmountCents(
        const DriverOrder(
          id: 'r',
          price: 100,
          driverPrice: 20,
          paidOnlineCents: 900,
        ),
      ),
      1100,
    );
    expect(
      onboardAmountCents(
        const DriverOrder(id: 'full', price: 100, driverPrice: 20),
      ),
      2000,
    );
    expect(
      onboardAmountCents(
        const DriverOrder(
          id: 'over',
          price: 100,
          driverPrice: 20,
          paidOnlineCents: 2500,
        ),
      ),
      0,
    );
    expect(
      () => onboardAmountCents(const DriverOrder(id: 'no-driver-price')),
      throwsFormatException,
    );
    expect(
      () => onboardAmountCents(
        const DriverOrder(id: 'neg-driver-price', driverPrice: -1),
      ),
      throwsFormatException,
    );
    expect(
      () => onboardAmountCents(
        const DriverOrder(
          id: 'neg-paid',
          driverPrice: 100,
          paidOnlineCents: -1,
        ),
      ),
      throwsFormatException,
    );
  });

  test('recognizes onboard payment methods after normalization', () {
    for (final method in [
      'à bord',
      'Paiement À Bord',
      'ON-BOARD',
      'cash_on_delivery',
      'onboard',
      ' on  board ',
    ]) {
      expect(
        DriverOrder(id: 'm', paymentMethod: method).isOnboardPaymentMethod,
        isTrue,
        reason: method,
      );
    }
    for (final method in ['card', 'online', 'virement']) {
      expect(
        DriverOrder(id: 'm', paymentMethod: method).isOnboardPaymentMethod,
        isFalse,
        reason: method,
      );
    }
    expect(const DriverOrder(id: 'none').isOnboardPaymentMethod, isFalse);
    const legacy = DriverOrder(id: 'legacy', paymentPlan: 'reservation_fee');
    expect(legacy.isOnboardPaymentMethod, isFalse);
    expect(legacy.hasOnboardPayment, isTrue);
  });

  test('parses contract fields from Firestore orders', () {
    final order = DriverOrder.fromFirestore('done', {
      'driverId': 'me',
      'status': 'Terminée',
      'price': 100.006,
      'driverPrice': 20.5,
      'paymentMethod': 'paiement à bord',
      'paidOnlineCents': 900,
      'validatedForDriverAt': Timestamp.fromDate(date),
    });
    expect(order.isValidatedForDriver, isTrue);
    expect(order.priceCents, 10001);
    expect(order.driverPriceCents, 2050);
    expect(order.isOnboardPaymentMethod, isTrue);
    expect(onboardAmountCents(order), 1150);
    for (final invalidValidation in [null, '2026-11-07', date]) {
      expect(
        DriverOrder.fromFirestore('invalid', {
          'validatedForDriverAt': invalidValidation,
        }).isValidatedForDriver,
        isFalse,
      );
    }
    expect(
      () => DriverOrder.fromFirestore('bad', {'paidOnlineCents': 9.5}),
      throwsFormatException,
    );
    expect(
      () => DriverOrder.fromFirestore('bad', {'driverPrice': 'x'}),
      throwsFormatException,
    );
    expect(
      () => DriverOrder.fromFirestore('bad', {'paymentMethod': 42}),
      throwsFormatException,
    );
  });

  test('parses admin payment methods and optional notes', () {
    final transfer = DriverPayment.fromFirestore('p1', payment());
    expect(transfer.method, DriverPaymentMethod.transfer);
    expect(transfer.amountCents, 4567);
    expect(transfer.note, 'VIR-1');
    expect(transfer.administratorId, 'admin-1');
    expect(transfer.date.toUtc(), date);
    final cash = DriverPayment.fromFirestore('p2', {
      ...payment(),
      'method': 'cash',
      'note': null,
    });
    expect(cash.method, DriverPaymentMethod.cash);
    expect(cash.note, isNull);
    expect(cash.administratorId, 'admin-1');
  });

  test('rejects unknown, missing or invalid payment fields', () {
    for (final change in <Map<String, dynamic>>[
      {'amountCents': null},
      {'amountCents': 45.67},
      {'amountCents': -10},
      {'amountCents': 0},
      {'method': 'onboard'},
      {'method': null},
      {'date': '2026-11-07'},
      {'date': Timestamp.fromDate(DateTime.now().add(const Duration(days: 1)))},
      {'note': 42},
      {'administratorId': 42},
      {'administratorId': null},
    ]) {
      expect(
        () => DriverPayment.fromFirestore('bad', {...payment(), ...change}),
        throwsFormatException,
      );
    }
  });

  test('rejects invalid driver document paths before accessing Firebase', () {
    final service = DriverFinanceService();
    expect(() => service.watchPayments(''), throwsArgumentError);
    expect(() => service.watchPayments('a/b'), throwsArgumentError);
  });
}
