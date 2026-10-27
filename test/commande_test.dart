import 'dart:async';

import 'package:chauffeur/screens/commande.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:chauffeur/services/location_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Service extends FireService {
  final orders = StreamController<List<DriverOrder>>();
  final requests = <String>[];
  GPSCoordinates? lastLocation;
  Completer<void>? result;

  @override
  Stream<List<DriverOrder>> getOrdersStream() => orders.stream;

  @override
  Stream<List<DriverOrder>> getOrdersForDriverStream(String driverId) =>
      orders.stream;

  @override
  Future<void> chooseOrder(
    String orderId, {
    required GPSCoordinates location,
  }) async {
    requests.add(orderId);
    lastLocation = location;
    await result?.future;
  }
}

class _Location extends LocationService {
  final position = const GPSCoordinates(latitude: 48.8566, longitude: 2.3522);
  StateError? failure;

  @override
  Future<GPSCoordinates> currentPosition() async {
    if (failure != null) throw failure!;
    return position;
  }
}

class _User extends Fake implements User {
  _User(this.uid);
  @override
  final String uid;
}

class _Auth extends Fake implements FirebaseAuth {
  _Auth(this.currentUser);
  @override
  final User? currentUser;
}

// These are test doubles only; production uses Firestore's document objects.
// ignore: subtype_of_sealed_class
class _Reference extends Fake
    implements DocumentReference<Map<String, dynamic>> {}

// ignore: subtype_of_sealed_class
class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final documentIds = <String?>[];
  String? get documentId => documentIds.last;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    documentIds.add(path);
    return _Reference();
  }
}

// ignore: subtype_of_sealed_class
class _Snapshot extends Fake implements DocumentSnapshot<Map<String, dynamic>> {
  _Snapshot(this.values);
  final Map<String, dynamic>? values;

  @override
  Map<String, dynamic>? data() => values;
}

class _Transaction extends Fake implements Transaction {
  _Transaction(this.values);
  final Map<String, dynamic>? values;
  Map<String, dynamic>? changes;

  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
    DocumentReference<T> documentReference,
  ) async => _Snapshot(values) as DocumentSnapshot<T>;

  @override
  Transaction update(
    DocumentReference documentReference,
    Map<Object, Object?> data,
  ) {
    changes = Map<String, dynamic>.from(data);
    values!.addAll(changes!);
    return this;
  }
}

class _Firestore extends Fake implements FirebaseFirestore {
  _Firestore(Map<String, dynamic>? values) : transaction = _Transaction(values);
  final _Transaction transaction;
  final orders = _Collection();
  String? collectionPath;
  int transactions = 0;

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    this.collectionPath = collectionPath;
    return orders;
  }

  @override
  Future<T> runTransaction<T>(
    Future<T> Function(Transaction) transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    transactions++;
    return transactionHandler(transaction);
  }
}

void main() {
  final position = GPSCoordinates(latitude: 48.8566, longitude: 2.3522);

  test(
    'Release preserves history, removes ownership and allows reassignment',
    () async {
      final values = <String, dynamic>{
        'driverId': 'driver',
        'commandStatus': [
          {
            'status': 'OrderStatus.ON_SITE',
            'id': 'driver',
            'date': '2026-10-12T10:00:00.000Z',
            'location': {'latitude': 48, 'longitude': 2},
          },
        ],
      };
      final db = _Firestore(values);
      final service = FireService(firestore: db, auth: _Auth(_User('driver')));
      await service.releaseOrder('course', location: position);
      values.remove('driverId');
      final released = DriverOrder.fromFirestore('course', {
        ...values,
        'driverId': null,
      });
      expect(released.driverId, isNull);
      expect(released.currentStatus, OrderStatus.PENDING_ASSIGNMENT);
      expect(released.commandStatus.length, 2);
      final other = FireService(firestore: db, auth: _Auth(_User('other')));
      await other.chooseOrder('course', location: position);
      expect(DriverOrder.fromFirestore('course', values).driverId, 'other');
    },
  );

  test(
    'Release rejects foreign drivers and courses with client on board',
    () async {
      final values = <String, dynamic>{
        'driverId': 'driver',
        'commandStatus': [
          {
            'status': 'OrderStatus.CLIENT_ON_BOARD',
            'id': 'driver',
            'date': '2026-10-12T10:00:00.000Z',
            'location': {'latitude': 48, 'longitude': 2},
          },
        ],
      };
      for (final uid in ['driver', 'other']) {
        final db = _Firestore(values);
        await expectLater(
          FireService(
            firestore: db,
            auth: _Auth(_User(uid)),
          ).releaseOrder('course', location: position),
          throwsStateError,
        );
        expect(db.transaction.changes, isNull);
      }
    },
  );

  test('Appends GPS history and advances only to the next stage', () async {
    final values = <String, dynamic>{
      'status': 'Acceptée',
      'commandStatus': <Map<String, dynamic>>[
        {
          'status': 'OrderStatus.ASSIGNED',
          'id': 'driver',
          'date': '2026-10-12T10:00:00.000Z',
          'location': {'latitude': 48.8566, 'longitude': 2.3522},
        },
      ],
    };
    final database = _Firestore(values);
    final service = FireService(
      firestore: database,
      auth: _Auth(_User('driver')),
    );
    for (final expected in [
      OrderStatus.ASSIGNED,
      OrderStatus.EN_ROUTE,
      OrderStatus.ON_SITE,
      OrderStatus.CLIENT_ON_BOARD,
    ]) {
      final previous = List<Object?>.from(values['commandStatus'] as List);
      await service.advanceOrderStatus(
        orderId: 'course',
        expectedStatus: expected,
        nextStatus: expected.next!,
        location: position,
      );
      final history = DriverOrder.parseHistory(
        'course',
        values['commandStatus'],
      );
      expect(history.last.status, expected.next);
      expect(history.last.id, 'driver');
      expect(history.last.location.latitude, 48.8566);
      expect(history.last.location.longitude, 2.3522);
      expect((values['commandStatus'] as List).take(previous.length), previous);
      expect(values['status'], 'Acceptée');
      expect(values.containsKey('driverId'), isFalse);
      expect(DriverOrder.fromFirestore('course', values).driverId, 'driver');
      expect(values['commandStatusUpdatedAt'], isA<FieldValue>());
    }
    expect(
      DriverOrder.fromFirestore('course', values).currentStatus,
      OrderStatus.COMPLETED,
    );
  });

  test(
    'Rejects another driver, stale stages, jumps and finished courses',
    () async {
      final values = <String, dynamic>{
        'commandStatus': [
          {
            'status': 'OrderStatus.ASSIGNED',
            'id': 'driver',
            'date': '2026-10-12T10:00:00.000Z',
            'location': {'latitude': 48.8566, 'longitude': 2.3522},
          },
        ],
      };
      final database = _Firestore(values);
      Future<void> update(String uid, OrderStatus expected, OrderStatus next) =>
          FireService(
            firestore: database,
            auth: _Auth(_User(uid)),
          ).advanceOrderStatus(
            orderId: 'course',
            expectedStatus: expected,
            nextStatus: next,
            location: position,
          );
      await expectLater(
        update('other', OrderStatus.ASSIGNED, OrderStatus.EN_ROUTE),
        throwsStateError,
      );
      await expectLater(
        update('driver', OrderStatus.EN_ROUTE, OrderStatus.ON_SITE),
        throwsStateError,
      );
      await expectLater(
        update('driver', OrderStatus.ASSIGNED, OrderStatus.COMPLETED),
        throwsStateError,
      );
      values['status'] = 'Terminée';
      await expectLater(
        update('driver', OrderStatus.COMPLETED, OrderStatus.EN_ROUTE),
        throwsStateError,
      );
      expect(database.transaction.changes, isNull);
    },
  );

  test(
    'Rejects invalid GPS and histories without modifying the document',
    () async {
      final values = <String, dynamic>{
        'commandStatus': [
          {
            'status': 'OrderStatus.ASSIGNED',
            'id': 'driver',
            'date': '2026-10-12T10:00:00.000Z',
            'location': {'latitude': 48.8566, 'longitude': 2.3522},
          },
        ],
      };
      final database = _Firestore(values);
      final service = FireService(
        firestore: database,
        auth: _Auth(_User('driver')),
      );
      await expectLater(
        service.advanceOrderStatus(
          orderId: 'course',
          expectedStatus: OrderStatus.ASSIGNED,
          nextStatus: OrderStatus.EN_ROUTE,
          location: GPSCoordinates(latitude: double.nan, longitude: 2),
        ),
        throwsStateError,
      );
      expect(database.transactions, 0);
      values['commandStatus'] = [
        {'status': 'corrupted-history'},
      ];
      await expectLater(
        service.advanceOrderStatus(
          orderId: 'course',
          expectedStatus: OrderStatus.ASSIGNED,
          nextStatus: OrderStatus.EN_ROUTE,
          location: position,
        ),
        throwsFormatException,
      );
      expect(database.transaction.changes, isNull);
    },
  );

  test(
    'Reserves the document and appends ASSIGNED status with driver ID and GPS',
    () async {
      final values = <String, dynamic>{'status': 'En attente'};
      final database = _Firestore(values);
      await FireService(
        firestore: database,
        auth: _Auth(_User('driver-1')),
      ).chooseOrder('firestore-document-id', location: position);
      expect(database.collectionPath, 'Orders');
      expect(database.orders.documentId, 'firestore-document-id');
      expect(database.transactions, 1);
      expect(
        database.transaction.changes!.keys,
        unorderedEquals(['commandStatus', 'commandStatusUpdatedAt']),
      );
      expect(values.containsKey('driverId'), isFalse);
      expect(values['status'], 'En attente');
      expect(values['commandStatusUpdatedAt'], isA<FieldValue>());

      final history = DriverOrder.parseHistory(
        'firestore-document-id',
        values['commandStatus'],
      );
      expect(history.length, 1);
      expect(history.first.status, OrderStatus.ASSIGNED);
      expect(history.first.id, 'driver-1');
      expect(history.first.location.latitude, 48.8566);
      expect(history.first.location.longitude, 2.3522);

      final order = DriverOrder.fromFirestore('firestore-document-id', values);
      expect(order.driverId, 'driver-1');
    },
  );

  test('Rejects a second driver and allows an idempotent retry', () async {
    final values = <String, dynamic>{};
    final database = _Firestore(values);
    final first = FireService(firestore: database, auth: _Auth(_User('first')));
    await first.chooseOrder('course', location: position);
    final initialCount = (values['commandStatus'] as List).length;
    await first.chooseOrder('course', location: position);
    expect((values['commandStatus'] as List).length, initialCount);
    await expectLater(
      FireService(
        firestore: database,
        auth: _Auth(_User('second')),
      ).chooseOrder('course', location: position),
      throwsStateError,
    );
    final order = DriverOrder.fromFirestore('course', values);
    expect(order.driverId, 'first');
  });

  test(
    'Rejects second driver when assignment exists only in commandStatus',
    () async {
      final values = <String, dynamic>{
        'commandStatus': [
          {
            'status': 'OrderStatus.ASSIGNED',
            'id': 'first',
            'date': '2026-10-12T10:00:00.000Z',
            'location': {'latitude': 48.85, 'longitude': 2.35},
          },
        ],
      };
      final database = _Firestore(values);
      await expectLater(
        FireService(
          firestore: database,
          auth: _Auth(_User('second')),
        ).chooseOrder('course', location: position),
        throwsStateError,
      );
    },
  );

  test('Rejects missing orders and unauthenticated reservations', () async {
    final database = _Firestore(null);
    await expectLater(
      FireService(
        firestore: database,
        auth: _Auth(null),
      ).chooseOrder('course', location: position),
      throwsStateError,
    );
    expect(database.transactions, 0);
    await expectLater(
      FireService(
        firestore: database,
        auth: _Auth(_User('driver')),
      ).chooseOrder('course', location: position),
      throwsStateError,
    );
    expect(database.transaction.changes, isNull);
  });

  test('Uses the Firestore document ID and parses displayed fields', () {
    final order = DriverOrder.fromFirestore('document-id', {
      'id': 'legacy-id',
      'departureAddress': 'Paris',
      'departureDate': Timestamp.fromDate(DateTime(2026, 10, 12, 10)),
      'steps': ['Orly'],
      'personNumber': 2,
      'driverId': 'driver-1',
    });
    expect(order.id, 'document-id');
    expect(order.departureAddress, 'Paris');
    expect(order.steps, ['Orly']);
    expect(order.driverId, 'driver-1');
    expect(order.departureDate, DateTime(2026, 10, 12, 10));
    expect(
      () => DriverOrder.fromFirestore('bad', {
        'steps': [12],
      }),
      throwsFormatException,
    );
  });

  test(
    'Derives assigned driver from commandStatus without top-level driverId',
    () {
      final order = DriverOrder.fromFirestore('doc-1', {
        'departureAddress': 'Paris',
        'commandStatus': [
          {
            'status': 'OrderStatus.ASSIGNED',
            'id': 'driver-42',
            'date': '2026-10-12T10:00:00.000Z',
            'location': {'latitude': 48.85, 'longitude': 2.35},
          },
        ],
      });
      expect(order.driverId, 'driver-42');
      expect(order.currentStatus, OrderStatus.ASSIGNED);
    },
  );

  testWidgets('Shows loading, empty, live orders and stream errors', (
    tester,
  ) async {
    final service = _Service();
    addTearDown(service.orders.close);
    await tester.pumpWidget(
      MaterialApp(
        home: CommandePage(driverId: 'driver-1', service: service),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    service.orders.add([]);
    await tester.pumpAndSettle();
    expect(
      find.text('Aucune course disponible pour le moment.'),
      findsOneWidget,
    );
    service.orders.add([
      const DriverOrder(
        id: 'course-1',
        departureAddress: 'Paris',
        steps: ['Orly'],
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Paris'), findsOneWidget);
    expect(find.text('1. Orly'), findsOneWidget);
    service.orders.addError(
      FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('permission-denied'), findsOneWidget);
    expect(find.text('Réessayer'), findsOneWidget);
  });

  test('Parses the explicit reservation fee payment plan', () {
    final order = DriverOrder.fromFirestore('reservation', {
      'paymentPlan': 'reservation_fee',
    });
    expect(order.hasOnboardPayment, isTrue);
    expect(const DriverOrder(id: 'missing').hasOnboardPayment, isFalse);
    expect(
      const DriverOrder(
        id: 'pending',
        paymentStatus: 'pending',
      ).hasOnboardPayment,
      isFalse,
    );
    expect(
      () => DriverOrder.fromFirestore('bad', {'paymentPlan': 42}),
      throwsFormatException,
    );
  });

  testWidgets(
    'Warns for reservation fee plans without inventing a payable amount',
    (tester) async {
      final service = _Service();
      addTearDown(service.orders.close);
      await tester.pumpWidget(
        MaterialApp(
          home: CommandePage(driverId: 'driver-1', service: service),
        ),
      );
      service.orders.add([
        const DriverOrder(
          id: 'aboard',
          price: 100,
          paymentPlan: 'reservation_fee',
        ),
      ]);
      await tester.pumpAndSettle();
      expect(
        find.text('Attention: paiement à bord sur cette course'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Vérifiez les frais de réservation'),
        findsNothing,
      );
      expect(
        find.textContaining('Statut du paiement : non renseigné'),
        findsNothing,
      );
      service.orders.add([
        const DriverOrder(id: 'aboard', price: 100, paymentStatus: 'pending'),
      ]);
      await tester.pumpAndSettle();
      expect(
        find.text('Attention: paiement à bord sur cette course'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Shows fare, exact 20 percent commission and driver share', (
    tester,
  ) async {
    final service = _Service();
    addTearDown(service.orders.close);
    await tester.pumpWidget(
      MaterialApp(
        home: CommandePage(driverId: 'driver-1', service: service),
      ),
    );
    for (final values in [
      (100, '100,00 EUR', '20,00 EUR', '80,00 EUR'),
      (19, '19,00 EUR', '3,80 EUR', '15,20 EUR'),
      (0, '0,00 EUR', '0,00 EUR', '0,00 EUR'),
    ]) {
      service.orders.add([DriverOrder(id: 'fare', price: values.$1)]);
      await tester.pumpAndSettle();
      expect(find.text('Prix de la course : ${values.$2}'), findsNothing);
      expect(
        find.text('Commission société (20 %) : ${values.$3}'),
        findsNothing,
      );
      expect(find.text(values.$4.replaceFirst(' EUR', ' €')), findsOneWidget);
      expect(find.textContaining('Prix chauffeur'), findsNothing);
      expect(find.textContaining('Après commission'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('choose-fare')))
            .onPressed,
        isNotNull,
      );
    }
    service.orders.add([const DriverOrder(id: 'fare')]);
    await tester.pumpAndSettle();
    expect(find.text('Prix non renseigné'), findsOneWidget);
    expect(find.textContaining('Prix chauffeur'), findsNothing);
    service.orders.add([const DriverOrder(id: 'fare', price: -10)]);
    await tester.pumpAndSettle();
    expect(find.textContaining('Prix invalide'), findsOneWidget);
    expect(find.textContaining('Commission société'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Keeps a complete standard order card under 450 pixels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _Service();
    addTearDown(service.orders.close);
    await tester.pumpWidget(
      MaterialApp(
        home: CommandePage(driverId: 'driver-1', service: service),
      ),
    );
    service.orders.add([
      DriverOrder(
        id: 'compact',
        departureAddress: 'Paris',
        departureDate: DateTime(2026, 10, 12, 10),
        steps: const ['Orly'],
        vehicule: 'Mercedes V',
        personNumber: 2,
        suitcaseNumber: 3,
        category: 'berline',
        status: 'pending',
        price: 100,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('order-card-compact'))).height,
      lessThan(450),
    );
    for (final label in [
      'Paris',
      '1. Orly',
      'Mercedes V',
      '2 passager(s)',
      '3 bagage(s)',
      '80,00 €',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('choose-compact')), findsOneWidget);
    expect(find.text('Disponible'), findsNothing);
    expect(find.text('pending'), findsNothing);
    final summary = find.byKey(const ValueKey('available-summary-compact'));
    final summaryY = tester.getCenter(find.text('80,00 €')).dy;
    expect(find.text('berline'), findsNothing);
    for (final label in ['Mercedes V', '2 passager(s)', '3 bagage(s)']) {
      final field = find.descendant(of: summary, matching: find.text(label));
      expect(field, findsOneWidget);
      expect(tester.getCenter(field).dy, closeTo(summaryY, 1));
    }
    tester.view.physicalSize = const Size(320, 1000);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('3 bagage(s)'));
    await tester.pumpAndSettle();
    expect(find.text('3 bagage(s)').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Available summary falls back to category when vehicle is absent or blank',
    (tester) async {
      final service = _Service();
      addTearDown(service.orders.close);
      await tester.pumpWidget(
        MaterialApp(
          home: CommandePage(driverId: 'driver-1', service: service),
        ),
      );
      for (final vehicle in [null, '', '   ']) {
        service.orders.add([
          DriverOrder(
            id: 'category',
            vehicule: vehicle,
            category: 'eco',
            price: 100,
            personNumber: 2,
            suitcaseNumber: 1,
          ),
        ]);
        await tester.pumpAndSettle();
        final summary = find.byKey(
          const ValueKey('available-summary-category'),
        );
        expect(
          find.descendant(of: summary, matching: find.text('eco')),
          findsOneWidget,
        );
        expect(find.text('80,00 €'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'Compact layout preserves long details and warning at large text sizes',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _Service();
      addTearDown(service.orders.close);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: CommandePage(driverId: 'driver-1', service: service),
        ),
      );
      const address =
          'Une adresse de départ très longue pour vérifier le retour à la ligne';
      service.orders.add([
        const DriverOrder(
          id: 'long-order-identifier-without-truncation',
          driverId: 'driver-1',
          departureAddress: address,
          steps: ['Première étape', 'Destination finale'],
          vehicule: 'Mercedes Classe V grand véhicule',
          personNumber: 6,
          suitcaseNumber: 8,
          precision: 'Instructions importantes pour le chauffeur',
          price: 123,
          paymentPlan: 'reservation_fee',
        ),
      ]);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Courses attribuées'));
      await tester.pumpAndSettle();
      expect(find.text(address), findsOneWidget);
      expect(find.text('2. Destination finale'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Attention: paiement à bord sur cette course'),
        200,
      );
      expect(
        find.textContaining('Vérifiez les frais de réservation'),
        findsNothing,
      );
      await tester.scrollUntilVisible(
        find.byKey(
          const ValueKey(
            'download-voucher-long-order-identifier-without-truncation',
          ),
        ),
        200,
      );
      expect(find.text('Gérer ma commande'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Blocks duplicate taps and displays successful assignment', (
    tester,
  ) async {
    final service = _Service()..result = Completer<void>();
    addTearDown(service.orders.close);
    await tester.pumpWidget(
      MaterialApp(
        home: CommandePage(
          driverId: 'driver-1',
          service: service,
          locationService: _Location(),
        ),
      ),
    );
    service.orders.add([const DriverOrder(id: 'course-1')]);
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('choose-course-1'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    await tester.tap(button);
    expect(service.requests, ['course-1']);
    expect(service.lastLocation?.latitude, 48.8566);
    expect(service.lastLocation?.longitude, 2.3522);
    service.result!.complete();
    await tester.pumpAndSettle();
    expect(button, findsNothing);
    await tester.tap(find.text('Courses attribuées'));
    await tester.pumpAndSettle();
    expect(find.text('Commande choisie'), findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
  });

  testWidgets('Shows an assignment conflict and keeps the button usable', (
    tester,
  ) async {
    final service = _Service()..result = Completer<void>();
    addTearDown(service.orders.close);
    await tester.pumpWidget(
      MaterialApp(
        home: CommandePage(
          driverId: 'driver-1',
          service: service,
          locationService: _Location(),
        ),
      ),
    );
    service.orders.add([const DriverOrder(id: 'course-1')]);
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('choose-course-1'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    service.result!.completeError(StateError('Commande déjà choisie.'));
    await tester.pumpAndSettle();
    expect(find.text('Commande déjà choisie.'), findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
  });

  testWidgets(
    'Assigned tab only shows the current driver orders on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _Service();
      addTearDown(service.orders.close);
      await tester.pumpWidget(
        MaterialApp(
          home: CommandePage(driverId: 'driver-1', service: service),
        ),
      );
      service.orders.add([
        const DriverOrder(id: 'mine', driverId: 'driver-1'),
        const DriverOrder(id: 'other', driverId: 'driver-2'),
        const DriverOrder(id: 'available'),
      ]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('choose-mine')), findsNothing);
      expect(find.byKey(const ValueKey('order-card-other')), findsNothing);
      expect(
        find.byKey(const ValueKey('order-card-available')),
        findsOneWidget,
      );
      await tester.tap(find.text('Courses attribuées'));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('choose-mine'));
      await tester.scrollUntilVisible(button, 200);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(find.byKey(const ValueKey('order-card-other')), findsNothing);
      expect(find.byKey(const ValueKey('order-card-available')), findsNothing);
      service.orders.add([
        const DriverOrder(id: 'other', driverId: 'driver-2'),
      ]);
      await tester.pumpAndSettle();
      expect(
        find.text('Aucune course attribuée pour le moment.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('order-card-other')), findsNothing);
      expect(tester.takeException(), isNull);
      expect(service.requests, isEmpty);
    },
  );

  test('parseHistory handles Firestore Timestamp, DateTime, String, and integer coordinates', () {
    final timestamp = Timestamp.fromDate(DateTime(2026, 10, 12, 11, 5));
    final history = DriverOrder.parseHistory('doc-timestamp', [
      {
        'date': timestamp,
        'status': 'pending_assignment',
        'id': '',
        'location': {'latitude': 0, 'longitude': 0},
      },
      {
        'date': '2026-10-12T11:05:00.000Z',
        'status': 'assigned',
        'id': 'chauffeur-123',
        'location': {'latitude': 48.8698, 'longitude': 2.3075},
      },
      {
        'date': DateTime(2026, 10, 12, 11, 10),
        'status': 'en_route',
        'id': 'chauffeur-123',
        'location': {'latitude': 48.87, 'longitude': 2.31},
      },
    ]);
    expect(history.length, 3);
    expect(history[0].status, OrderStatus.PENDING_ASSIGNMENT);
    expect(history[0].date, DateTime(2026, 10, 12, 11, 5));
    expect(history[0].id, '');
    expect(history[0].location.latitude, 0.0);
    expect(history[1].status, OrderStatus.ASSIGNED);
    expect(history[1].id, 'chauffeur-123');
    expect(history[2].status, OrderStatus.EN_ROUTE);
  });

  test('fromFirestore correctly parses real Firestore payload with Timestamp and derives driverId', () {
    final realFirestoreData = <String, dynamic>{
      'category': 'berline',
      'price': 120,
      'personNumber': 1,
      'steps': ['Gare de Lyon Place Louis-Armand 75012 Paris'],
      'departureAddress': '25 Avenue des Champs-Élysées 75008 Paris',
      'vehicule': 'Mercedes-Benz Classe E',
      'departureDate': Timestamp.fromDate(DateTime(2026, 10, 16, 14, 0)),
      'status': 'pending',
      'suitcaseNumber': 2,
      'userId': 'client-uid',
      'commandStatus': [
        {
          'location': {'latitude': 0, 'longitude': 0},
          'date': Timestamp.fromDate(DateTime(2026, 10, 12, 11, 0)),
          'status': 'pending_assignment',
          'id': '',
        },
        {
          'date': Timestamp.fromDate(DateTime(2026, 10, 12, 11, 5)),
          'id': 'uNFtbGa5Dga4IOT2m1ZuEt4Vz383',
          'location': {'latitude': 48.8698, 'longitude': 2.3075},
          'status': 'assigned',
        },
      ],
    };

    final order = DriverOrder.fromFirestore(
      'PpRBpYwBT7qHVUhuhJ1B',
      realFirestoreData,
    );
    expect(order.id, 'PpRBpYwBT7qHVUhuhJ1B');
    expect(order.historyError, isNull);
    expect(order.driverId, 'uNFtbGa5Dga4IOT2m1ZuEt4Vz383');
    expect(order.currentStatus, OrderStatus.ASSIGNED);
    expect(order.commandStatus.length, 2);
    expect(order.departureDate, DateTime(2026, 10, 16, 14, 0));
    expect(order.personNumber, 1);
    expect(order.suitcaseNumber, 2);
  });

  testWidgets(
    'Displays download voucher button and triggers download callback',
    (tester) async {
      final service = _Service();
      addTearDown(service.orders.close);
      DriverOrder? downloadedOrder;

      await tester.pumpWidget(
        MaterialApp(
          home: CommandePage(
            driverId: 'driver-1',
            service: service,
            onDownloadVoucher: (context, order) async {
              downloadedOrder = order;
            },
          ),
        ),
      );

      const testOrder = DriverOrder(
        id: 'cmd-voucher-test',
        driverId: 'driver-1',
        departureAddress: '10 Place du Capitole 31000 Toulouse',
        steps: ['Gare Matabiau'],
        vehicule: 'Mercedes V',
        personNumber: 2,
      );
      service.orders.add([testOrder]);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Courses attribuées'));
      await tester.pumpAndSettle();

      final voucherButton = find.byKey(
        const ValueKey('download-voucher-cmd-voucher-test'),
      );
      expect(voucherButton, findsOneWidget);
      expect(find.text('Télécharger le bon de commande'), findsOneWidget);

      await tester.ensureVisible(voucherButton);
      await tester.tap(voucherButton);
      await tester.pumpAndSettle();

      expect(downloadedOrder, isNotNull);
      expect(downloadedOrder!.id, 'cmd-voucher-test');
    },
  );
}
