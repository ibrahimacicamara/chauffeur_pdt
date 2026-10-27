import 'package:chauffeur/screens/driver_profile.dart';
import 'package:chauffeur/services/firebase/driver_profile_service.dart';
import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Profiles extends DriverProfileService {
  MyDriver? driver;
  FirebaseException? readError;
  FirebaseException? writeError;
  int writes = 0;
  String? savedUid;
  List<String> carNames = ['Mercedes Classe E', 'Peugeot 508'];
  FirebaseException? carsError;

  @override
  Future<List<String>> getCarNames() async {
    if (carsError != null) throw carsError!;
    return carNames;
  }

  @override
  Future<MyDriver?> getDriver(String uid) async {
    if (readError != null) throw readError!;
    return driver;
  }

  @override
  Future<MyDriver> createProfile(
    String uid, {
    required String name,
    required String phone,
    required String car,
    required String licensePlate,
  }) async {
    writes++;
    if (writeError != null) throw writeError!;
    savedUid = uid;
    return driver = MyDriver(
      name: name.trim(),
      phone: phone,
      car: car.trim(),
      licensePlate: licensePlate.trim().toUpperCase(),
      categories: [],
      available: true,
    );
  }
}

void main() {
  Future<void> open(WidgetTester tester, _Profiles profiles) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DriverProfileGate(
          driverId: 'driver-1',
          service: profiles,
          initialName: 'Jean',
          initialPhone: '+33612345678',
          onSignOut: () async {},
          child: const Scaffold(body: Text('Commandes disponibles')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Enregistrer mon profil'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer mon profil'));
    await tester.pumpAndSettle();
  }

  testWidgets('existing profiles bypass the form without writes', (
    tester,
  ) async {
    final profiles = _Profiles()
      ..driver = MyDriver(
        name: 'Jean',
        phone: '+33612345678',
        categories: ['VIP'],
        car: 'Mercedes',
        available: true,
      );
    await open(tester, profiles);
    expect(find.text('Commandes disponibles'), findsOneWidget);
    expect(profiles.writes, 0);
    expect(profiles.driver!.categories, ['VIP']);
  });

  testWidgets('validates and saves missing profile without category input', (
    tester,
  ) async {
    final profiles = _Profiles();
    await open(tester, profiles);
    expect(find.byType(TextFormField), findsNWidgets(4));
    await save(tester);
    expect(find.text('Saisissez votre véhicule.'), findsOneWidget);
    expect(
      find.text('Saisissez votre plaque d’immatriculation.'),
      findsOneWidget,
    );
    expect(profiles.writes, 0);
    await tester.enterText(find.byKey(const ValueKey('driver-name')), '');
    await tester.enterText(
      find.byKey(const ValueKey('driver-phone')),
      '0612345678',
    );
    await tester.enterText(
      find.byKey(const ValueKey('driver-car')),
      ' Mercedes ',
    );
    await save(tester);
    expect(find.text('Saisissez votre nom.'), findsOneWidget);
    expect(profiles.writes, 0);
    await tester.enterText(find.byKey(const ValueKey('driver-name')), ' Jean ');
    await tester.enterText(
      find.byKey(const ValueKey('driver-license-plate')),
      ' ab-123-cd ',
    );
    await tester.enterText(
      find.byKey(const ValueKey('driver-phone')),
      '+33612345678',
    );
    await save(tester);
    expect(profiles.savedUid, 'driver-1');
    expect(profiles.driver!.name, 'Jean');
    expect(profiles.driver!.car, 'Mercedes');
    expect(profiles.driver!.licensePlate, 'AB-123-CD');
    expect(profiles.driver!.categories, isEmpty);
    expect(find.text('Commandes disponibles'), findsOneWidget);
  });

  testWidgets('read failures do not expose form and support retry', (
    tester,
  ) async {
    final profiles = _Profiles()
      ..readError = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'unavailable',
      );
    await open(tester, profiles);
    expect(
      find.text('Impossible de charger votre profil chauffeur.'),
      findsOneWidget,
    );
    expect(find.byType(TextFormField), findsNothing);
    profiles.readError = null;
    await tester.tap(find.text('Réessayer'));
    await tester.pumpAndSettle();
    expect(find.text('Complétez votre profil'), findsOneWidget);
  });

  testWidgets('vehicle suggestions filter and fill the saved profile', (
    tester,
  ) async {
    final profiles = _Profiles();
    await open(tester, profiles);
    expect(find.text('Peugeot 508'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('driver-car')), 'mer');
    await tester.pumpAndSettle();
    expect(find.text('Peugeot 508'), findsNothing);
    await tester.tap(find.text('Mercedes Classe E'));
    await tester.enterText(
      find.byKey(const ValueKey('driver-license-plate')),
      'AB-123-CD',
    );
    await save(tester);
    expect(profiles.driver!.car, 'Mercedes Classe E');
  });

  testWidgets('vehicle suggestion failures allow retry and manual entry', (
    tester,
  ) async {
    final profiles = _Profiles()
      ..carsError = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
      );
    await open(tester, profiles);
    expect(find.textContaining('Suggestions indisponibles'), findsOneWidget);
    profiles.carsError = null;
    await tester.tap(find.text('Réessayer les suggestions'));
    await tester.pumpAndSettle();
    expect(find.text('Peugeot 508'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('driver-car')),
      'Autre véhicule',
    );
    await tester.enterText(
      find.byKey(const ValueKey('driver-license-plate')),
      'AB-123-CD',
    );
    await save(tester);
    expect(profiles.driver!.car, 'Autre véhicule');
  });

  testWidgets('write failures retain form and allow retry on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final profiles = _Profiles()
      ..writeError = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
      );
    await open(tester, profiles);
    await tester.enterText(
      find.byKey(const ValueKey('driver-car')),
      'Mercedes',
    );
    await tester.enterText(
      find.byKey(const ValueKey('driver-license-plate')),
      'AB-123-CD',
    );
    await save(tester);
    expect(find.textContaining('permission-denied'), findsOneWidget);
    expect(find.text('Commandes disponibles'), findsNothing);
    expect(tester.takeException(), isNull);
    profiles.writeError = null;
    await save(tester);
    expect(find.text('Commandes disponibles'), findsOneWidget);
  });
}
