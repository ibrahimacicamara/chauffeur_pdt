import 'dart:async';

import 'package:chauffeur/screens/commande.dart';
import 'package:chauffeur/services/firebase/driver_profile_service.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Profiles extends DriverProfileService {
  final updates = StreamController<MyDriver?>.broadcast();
  final requestedIds = <String>[];

  @override
  Stream<MyDriver?> watchDriver(String uid) {
    requestedIds.add(uid);
    return updates.stream;
  }

  void assign(List<String> categories) => updates.add(
    MyDriver(
      name: 'Jean',
      phone: '+33612345678',
      car: 'Mercedes',
      categories: categories,
      available: true,
    ),
  );
}

class _Orders extends FireService {
  _Orders(_Profiles profiles) : super(profileService: profiles);

  final updates = StreamController<List<DriverOrder>>.broadcast();

  @override
  Stream<List<DriverOrder>> getOrdersStream() => updates.stream;
}

void main() {
  late _Profiles profiles;
  late _Orders service;
  const orders = [
    DriverOrder(id: 'berline', category: 'Berline'),
    DriverOrder(id: 'van', category: 'Van'),
    DriverOrder(id: 'assigned-van', category: 'Van', driverId: 'driver-1'),
    DriverOrder(id: 'missing'),
    DriverOrder(id: 'empty', category: ''),
    DriverOrder(id: 'case', category: 'berline'),
  ];

  setUp(() {
    profiles = _Profiles();
    service = _Orders(profiles);
  });

  tearDown(() async {
    await profiles.updates.close();
    await service.updates.close();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CommandePage(driverId: 'driver-1', service: service),
      ),
    );
  }

  Finder card(String id) => find.byKey(ValueKey('order-card-$id'));

  testWidgets(
    'matches complete categories without case sensitivity including assigned courses',
    (tester) async {
      await open(tester);
      service.updates.add(orders);
      await tester.pump();
      expect(card('berline'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      profiles.assign(['Berline', 'Berline']);
      await tester.pumpAndSettle();
      expect(profiles.requestedIds, ['driver-1']);
      expect(card('berline'), findsOneWidget);
      expect(card('case'), findsOneWidget);
      for (final id in ['van', 'assigned-van', 'missing', 'empty']) {
        expect(card(id), findsNothing);
      }
      profiles.assign(['VAN']);
      await tester.pumpAndSettle();
      expect(card('berline'), findsNothing);
      expect(card('van'), findsOneWidget);
      expect(card('assigned-van'), findsNothing);
      await tester.tap(find.text('Courses attribuées'));
      await tester.pumpAndSettle();
      expect(card('assigned-van'), findsOneWidget);
      expect(card('van'), findsNothing);
    },
  );

  test('category membership does not accept substrings', () async {
    final result = expectLater(
      service.getOrdersForDriverStream('driver-1'),
      emits(isEmpty),
    );
    profiles.assign(['premium van']);
    service.updates.add([const DriverOrder(id: 'van', category: 'van')]);
    await result;
  });

  testWidgets(
    'admin changes and new orders immediately update displayed list',
    (tester) async {
      await open(tester);
      profiles.assign(['Berline', 'Van']);
      service.updates.add(orders.take(2).toList());
      await tester.pumpAndSettle();
      expect(card('berline'), findsOneWidget);
      expect(card('van'), findsOneWidget);
      profiles.assign(['Berline']);
      await tester.pumpAndSettle();
      expect(card('van'), findsNothing);
      service.updates.add([
        const DriverOrder(id: 'new', category: 'Berline'),
        const DriverOrder(id: 'hidden', category: 'Van'),
      ]);
      await tester.pumpAndSettle();
      expect(card('berline'), findsNothing);
      expect(card('new'), findsOneWidget);
      expect(card('hidden'), findsNothing);
      profiles.assign([]);
      await tester.pumpAndSettle();
      expect(card('new'), findsNothing);
      expect(
        find.text('Aucune course disponible pour le moment.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('empty categories never include uncategorized courses', (
    tester,
  ) async {
    await open(tester);
    profiles.assign(['']);
    service.updates.add(orders);
    await tester.pumpAndSettle();
    expect(find.byType(Card), findsNothing);
    expect(
      find.text('Aucune course disponible pour le moment.'),
      findsOneWidget,
    );
  });

  testWidgets('profile errors hide courses until profile recovers', (
    tester,
  ) async {
    await open(tester);
    profiles.assign(['Berline']);
    service.updates.add(orders);
    await tester.pumpAndSettle();
    expect(card('berline'), findsOneWidget);
    profiles.updates.addError(
      FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
    );
    await tester.pumpAndSettle();
    expect(card('berline'), findsNothing);
    expect(find.textContaining('permission-denied'), findsOneWidget);
    service.updates.add(orders);
    await tester.pumpAndSettle();
    expect(card('berline'), findsNothing);
    profiles.assign(['Van']);
    await tester.pumpAndSettle();
    expect(card('van'), findsOneWidget);
    expect(card('berline'), findsNothing);
  });

  testWidgets(
    'missing profile is an error and retry renews both subscriptions',
    (tester) async {
      await open(tester);
      profiles.updates.add(null);
      service.updates.add(orders);
      await tester.pumpAndSettle();
      expect(
        find.text('Votre profil chauffeur est introuvable.'),
        findsOneWidget,
      );
      expect(card('berline'), findsNothing);
      await tester.tap(find.text('Réessayer'));
      await tester.pump();
      profiles.assign(['Berline']);
      service.updates.add(orders);
      await tester.pumpAndSettle();
      expect(profiles.requestedIds, ['driver-1', 'driver-1']);
      expect(card('berline'), findsOneWidget);
    },
  );

  test('cancelling the filtered stream releases both listeners', () async {
    final subscription = service
        .getOrdersForDriverStream('driver-1')
        .listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(profiles.updates.hasListener, isTrue);
    expect(service.updates.hasListener, isTrue);
    await subscription.cancel();
    expect(profiles.updates.hasListener, isFalse);
    expect(service.updates.hasListener, isFalse);
  });

  test('financial source remains unfiltered', () async {
    final result = expectLater(service.getOrdersStream(), emits(orders));
    service.updates.add(orders);
    await result;
    expect(profiles.requestedIds, isEmpty);
  });
}
