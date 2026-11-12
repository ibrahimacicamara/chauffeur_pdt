import 'dart:async';

import 'package:chauffeur/screens/statistique.dart';
import 'package:chauffeur/services/firebase/driver_finance.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Orders extends FireService {
  final controller = StreamController<List<DriverOrder>>.broadcast();
  @override
  Stream<List<DriverOrder>> getOrdersStream() => controller.stream;
}

class _Finance extends DriverFinanceService {
  final payments = StreamController<List<DriverPayment>>.broadcast();
  final requestedIds = <String>[];

  @override
  Stream<List<DriverPayment>> watchPayments(String driverId) {
    requestedIds.add(driverId);
    return payments.stream;
  }
}

void main() {
  late _Orders orders;
  late _Finance finance;
  final date = DateTime.utc(2026, 10, 12);

  setUp(() {
    orders = _Orders();
    finance = _Finance();
  });

  tearDown(() async {
    await orders.controller.close();
    await finance.payments.close();
  });

  Future<void> show(WidgetTester tester, {double width = 800}) async {
    tester.view.physicalSize = Size(width, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: StatistiquePage(
          driverId: 'me',
          orderService: orders,
          financeService: finance,
        ),
      ),
    );
    await tester.pump();
  }

  void emitEmpty() {
    orders.controller.add([]);
    finance.payments.add([]);
  }

  testWidgets('empty courses and receipts yield a zero calculated balance', (
    tester,
  ) async {
    await show(tester);
    expect(find.byType(CircularProgressIndicator), findsNWidgets(3));
    emitEmpty();
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('driver-balance'))).data,
      '0,00 EUR',
    );
    expect(find.text('Aucun encaissement à bord enregistré.'), findsOneWidget);
    expect(find.text('Aucun paiement enregistré.'), findsOneWidget);
    expect(finance.requestedIds, ['me']);
  });

  testWidgets(
    'live balance, exact received totals and only assigned driver courses',
    (tester) async {
      await show(tester);
      orders.controller.add([
        const DriverOrder(
          id: 'done',
          driverId: 'me',
          status: 'Terminée',
          price: 1000,
          driverPrice: 800,
          paymentMethod: 'à bord',
          paidOnlineCents: 96997,
        ),
        const DriverOrder(id: 'active', driverId: 'me'),
        const DriverOrder(id: 'cancelled', driverId: 'me', status: 'Annulée'),
        const DriverOrder(id: 'other', driverId: 'other', status: 'Terminée'),
        const DriverOrder(id: 'available'),
        DriverOrder(
          id: 'history',
          commandStatus: [
            CommandStatus(
              date: date,
              status: OrderStatus.ASSIGNED,
              id: 'me',
              location: const GPSCoordinates(latitude: 48, longitude: 2),
            ),
          ],
        ),
      ]);
      finance.payments.add([
        DriverPayment(
          id: 'transfer',
          method: DriverPaymentMethod.transfer,
          amountCents: 45678,
          date: date,
          note: 'VIR-1',
        ),
        DriverPayment(
          id: 'cash',
          method: DriverPaymentMethod.cash,
          amountCents: 1234,
          date: date,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('330,88 EUR'), findsOneWidget);
      expect(find.text('Montant dû par la société.'), findsOneWidget);
      expect(find.text('0,00 EUR'), findsWidgets);
      expect(find.text('456,78 EUR'), findsNWidgets(2));
      expect(find.text('12,34 EUR'), findsNWidgets(2));
      expect(find.textContaining('Note : VIR-1'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('1'), findsNWidgets(2));
      await tester.tap(find.text('Détail du solde'));
      await tester.pumpAndSettle();
      expect(
        find.text('Rémunération des courses terminées : 800,00 EUR'),
        findsOneWidget,
      );
      expect(
        find.text('Encaissements à bord déduits : 0,00 EUR'),
        findsOneWidget,
      );
      expect(find.text('Virements déduits : -456,78 EUR'), findsOneWidget);
      expect(find.text('Espèces déduites : -12,34 EUR'), findsOneWidget);
      expect(find.text('Solde : 330,88 EUR'), findsOneWidget);
      await tester.ensureVisible(find.text('Détail de mes courses'));
      await tester.tap(find.text('Détail de mes courses'));
      await tester.pumpAndSettle();
      expect(find.text('Commande done'), findsNWidgets(2));
      expect(
        find.text('Rémunération chauffeur : 800,00 EUR'),
        findsNWidgets(2),
      );
      expect(find.text('Payé en ligne : 969,97 EUR'), findsOneWidget);
      expect(find.text('Encaissé à bord : 0,00 EUR'), findsOneWidget);
      expect(
        find.text('Rémunération chauffeur non renseignée'),
        findsNWidgets(3),
      );
      expect(find.text('Course incluse dans les gains.'), findsOneWidget);
      expect(find.text('Course non incluse dans les gains.'), findsNWidgets(3));
      expect(find.text('Commande other'), findsNothing);
      expect(find.text('Commande available'), findsNothing);
      finance.payments.add([
        DriverPayment(
          id: 'updated',
          method: DriverPaymentMethod.cash,
          amountCents: 90000,
          date: date,
        ),
      ]);
      orders.controller.add([
        const DriverOrder(
          id: 'done',
          driverId: 'me',
          status: 'Terminée',
          price: 1000,
          driverPrice: 800,
          paymentMethod: 'à bord',
          paidOnlineCents: 10000,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('-800,00 EUR'), findsOneWidget);
      expect(find.text('Montant à reverser à la société.'), findsOneWidget);
      expect(find.text('300,85 EUR'), findsNothing);
      expect(find.text('Solde : -800,00 EUR'), findsOneWidget);
      expect(
        find.text('Encaissements à bord déduits : -700,00 EUR'),
        findsOneWidget,
      );
      expect(find.text('Espèces déduites : -900,00 EUR'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('errors replace stale amounts and retry resubscribes', (
    tester,
  ) async {
    await show(tester);
    emitEmpty();
    await tester.pumpAndSettle();
    finance.payments.addError(
      FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Lecture impossible (permission-denied).'),
      findsNWidgets(2),
    );
    expect(find.text('0,00 EUR'), findsNothing);
    await tester.tap(find.text('Réessayer').first);
    await tester.pump();
    orders.controller.add([
      const DriverOrder(
        id: 'done',
        driverId: 'me',
        status: 'Terminée',
        price: 100,
        driverPrice: 80,
      ),
    ]);
    finance.payments.add([
      DriverPayment(
        id: 'received',
        method: DriverPaymentMethod.transfer,
        amountCents: 3500,
        date: date,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('45,00 EUR'), findsOneWidget);
  });

  testWidgets(
    'completion deducts the onboard remainder with absent paidOnlineCents as zero',
    (tester) async {
      await show(tester);
      finance.payments.add([]);
      orders.controller.add([
        const DriverOrder(
          id: 'reservation',
          driverId: 'me',
          price: 100,
          driverPrice: 20,
          paymentMethod: 'à bord',
          paidOnlineCents: 900,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('driver-balance'))).data,
        '0,00 EUR',
      );
      orders.controller.add([
        const DriverOrder(
          id: 'reservation',
          driverId: 'me',
          price: 100,
          status: 'Terminée',
          driverPrice: 20,
          paymentMethod: 'à bord',
          paidOnlineCents: 900,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('9,00 EUR'), findsOneWidget);
      expect(find.text('Rémunération chauffeur : 20,00 EUR'), findsOneWidget);
      expect(find.text('Rémunération chauffeur : 91,00 EUR'), findsNothing);
      expect(find.text('Payé en ligne : 9,00 EUR'), findsOneWidget);
      expect(find.text('Encaissé à bord : 11,00 EUR'), findsOneWidget);
      orders.controller.add([
        const DriverOrder(
          id: 'reservation',
          driverId: 'me',
          price: 100,
          status: 'Terminée',
          driverPrice: 20,
          paymentMethod: 'à bord',
        ),
      ]);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('driver-balance'))).data,
        '0,00 EUR',
      );
      expect(find.byKey(const ValueKey('provisional-balance')), findsNothing);
      orders.controller.add([
        const DriverOrder(
          id: 'reservation',
          driverId: 'me',
          status: 'Terminée',
          driverPrice: 20,
          paymentMethod: 'à bord',
        ),
      ]);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('driver-balance'))).data,
        '0,00 EUR',
      );
      expect(find.byKey(const ValueKey('provisional-balance')), findsNothing);
    },
  );

  testWidgets(
    'missing remuneration keeps a provisional signed balance on screen',
    (tester) async {
      await show(tester);
      emitEmpty();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('driver-balance')), findsOneWidget);
      orders.controller.add([
        const DriverOrder(id: 'done', driverId: 'me', status: 'Terminée'),
      ]);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('driver-balance'))).data,
        '0,00 EUR',
      );
      expect(find.byKey(const ValueKey('provisional-balance')), findsOneWidget);
      expect(
        find.textContaining('rémunération chauffeur inconnue'),
        findsOneWidget,
      );
      orders.controller.add([
        const DriverOrder(id: 'bad', historyError: 'Invalid history'),
      ]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('driver-balance')), findsOneWidget);
      expect(
        find.textContaining('Commande bad : historique invalide'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'narrow screen and large text remain scrollable without overflow',
    (tester) async {
      await show(tester, width: 320);
      emitEmpty();
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: StatistiquePage(
            driverId: 'me',
            orderService: orders,
            financeService: finance,
          ),
        ),
      );
      await tester.pump();
      emitEmpty();
      await tester.pump();
      finance.payments.add([]);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Aucun paiement enregistré.'),
        200,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
