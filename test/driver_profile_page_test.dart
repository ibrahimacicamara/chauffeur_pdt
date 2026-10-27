import 'dart:async';

import 'package:chauffeur/screens/commande.dart';
import 'package:chauffeur/screens/driver_profile_page.dart';
import 'package:chauffeur/services/firebase/driver_profile_service.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Profiles extends DriverProfileService {
  final profiles = StreamController<MyDriver?>.broadcast();
  final requests = <String>[];

  @override
  Stream<MyDriver?> watchDriver(String uid) {
    requests.add(uid);
    return profiles.stream;
  }
}

class _Orders extends FireService {
  _Orders(_Profiles profiles) : super(profileService: profiles);

  @override
  Stream<List<DriverOrder>> getOrdersForDriverStream(String driverId) =>
      Stream.value([]);
}

MyDriver _driver({
  String name = 'Jean Dupont',
  List<String> categories = const ['eco', 'VIP'],
  bool available = true,
}) => MyDriver(
  name: name,
  phone: '+33612345678',
  car: 'Mercedes Classe E',
  categories: categories,
  available: available,
  licensePlate: 'AB-123-CD',
);

void main() {
  late _Profiles service;

  setUp(() => service = _Profiles());
  tearDown(() async => service.profiles.close());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DriverProfilePage(driverId: 'driver-1', service: service),
      ),
    );
  }

  testWidgets(
    'displays driver details and live admin changes without editing',
    (tester) async {
      await open(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      service.profiles.add(_driver());
      await tester.pumpAndSettle();
      expect(service.requests, ['driver-1']);
      expect(find.text('JD'), findsOneWidget);
      expect(find.text('Jean Dupont'), findsNWidgets(2));
      expect(find.text('+33612345678'), findsOneWidget);
      expect(find.text('Mercedes Classe E'), findsOneWidget);
      expect(find.text('AB-123-CD'), findsOneWidget);
      expect(find.text('Disponible'), findsOneWidget);
      await tester.ensureVisible(find.text('Mes catégories'));
      expect(find.text('eco'), findsOneWidget);
      expect(find.text('VIP'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      service.profiles.add(_driver(categories: ['Van'], available: false));
      await tester.pumpAndSettle();
      expect(find.text('VIP'), findsNothing);
      expect(find.text('Van'), findsOneWidget);
      expect(find.text('Indisponible'), findsOneWidget);
      service.profiles.add(_driver(categories: []));
      await tester.pumpAndSettle();
      expect(
        find.text('Aucune catégorie attribuée pour le moment.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('handles missing profile and Firestore errors with retry', (
    tester,
  ) async {
    await open(tester);
    service.profiles.add(null);
    await tester.pumpAndSettle();
    expect(
      find.text('Votre profil chauffeur est introuvable.'),
      findsOneWidget,
    );
    service.profiles.addError(
      FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('permission-denied'), findsOneWidget);
    await tester.tap(find.text('Réessayer'));
    await tester.pump();
    expect(service.requests, ['driver-1', 'driver-1']);
    service.profiles.add(_driver());
    await tester.pumpAndSettle();
    expect(find.text('Jean Dupont'), findsNWidgets(2));
  });

  testWidgets('long fields and categories fit narrow screen with larger text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: DriverProfilePage(driverId: 'driver-1', service: service),
      ),
    );
    service.profiles.add(
      _driver(
        name: 'Jean Dupont avec un nom particulièrement long',
        categories: ['Transport de personnes à mobilité réduite', 'VIP'],
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('VIP'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    service.profiles.add(_driver(name: '  '));
    await tester.pumpAndSettle();
    expect(find.text('Non renseigné'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens own profile from orders and returns to orders', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CommandePage(driverId: 'driver-1', service: _Orders(service)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Mon profil'));
    await tester.pump();
    service.profiles.add(_driver());
    await tester.pumpAndSettle();
    expect(find.byType(DriverProfilePage), findsOneWidget);
    expect(service.requests, ['driver-1']);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Commandes'), findsOneWidget);
    expect(service.profiles.hasListener, isFalse);
  });
}
