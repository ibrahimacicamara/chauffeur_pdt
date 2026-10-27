import 'dart:async';

import 'package:chauffeur/services/firebase/driver_reminder_service.dart';
import 'package:chauffeur/services/reminder_alarm_service.dart';
import 'package:chauffeur/widgets/driver_reminder_panel.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chauffeur/services/location_service.dart';
import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:cloud_functions/cloud_functions.dart';

class _Reminders extends DriverReminderService {
  final reminders = StreamController<DriverReminder?>.broadcast();
  int confirmations = 0;
  LocationFix? fix;
  FirebaseFunctionsException? failure;

  @override
  Stream<DriverReminder?> watch(String orderId) => reminders.stream;

  @override
  Future<void> confirmAvailability(
    String orderId,
    String generation,
    LocationFix fix,
  ) async {
    confirmations++;
    this.fix = fix;
    if (failure != null) throw failure!;
    reminders.add(
      DriverReminder(
        driverId: 'driver',
        generation: generation,
        dueAt: DateTime.now().subtract(const Duration(minutes: 30)),
        departureDate: DateTime.now().add(const Duration(minutes: 30)),
        state: 'confirmed',
        durationSeconds: 1800,
        routeDistanceMeters: 10000,
      ),
    );
  }
}

class _Location extends LocationService {
  StateError? failure;
  int captures = 0;

  @override
  Future<LocationFix> currentFix() async {
    captures++;
    if (failure != null) throw failure!;
    return LocationFix(
      coordinates: GPSCoordinates(latitude: 48, longitude: 2),
      capturedAt: DateTime.now().toUtc(),
    );
  }
}

class _Alarms extends ReminderAlarmService {
  final stops = <String>[];
  final silences = <String>[];
  PlatformException? failure;

  @override
  bool get supported => true;

  @override
  Future<bool> stop(String orderId, String generation) async {
    stops.add('$orderId:$generation');
    if (failure != null) throw failure!;
    return true;
  }

  @override
  Future<bool> silence(String orderId, String generation) async {
    silences.add('$orderId:$generation');
    if (failure != null) throw failure!;
    return true;
  }
}

void main() {
  test('desktop does not require the Android alarm plugin', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final alarms = ReminderAlarmService();
    expect(alarms.supported, isFalse);
    expect(await alarms.bindDriver('driver'), isFalse);
    expect(await alarms.takeInitialAlarm(), isNull);
    expect(await alarms.stop('course', 'generation'), isFalse);
    expect(await alarms.silence('course', 'generation'), isFalse);
    await alarms.unbindDriver();
  });

  test('reminder parsing and exact H-1 confirmation window', () {
    final departure = DateTime.utc(2026, 10, 14, 10);
    final due = departure.subtract(const Duration(hours: 1));
    final reminder = DriverReminder.fromFirestore({
      'driverId': 'driver',
      'generation': 'gen',
      'state': 'pending',
      'dueAt': Timestamp.fromDate(due),
      'departureDate': Timestamp.fromDate(departure),
    });
    expect(reminder.canConfirm(due), isTrue);
    expect(
      reminder.canConfirm(due.subtract(const Duration(milliseconds: 1))),
      isFalse,
    );
    expect(reminder.canConfirm(departure), isFalse);
    expect(() => DriverReminder.fromFirestore({}), throwsFormatException);
    final data = {
      'driverId': 'driver',
      'generation': 'gen',
      'state': 'confirmed',
      'dueAt': Timestamp.fromDate(due),
      'departureDate': Timestamp.fromDate(departure),
      'durationSeconds': 3600.01,
      'routeDistanceMeters': 42000,
    };
    expect(DriverReminder.fromFirestore(data).durationSeconds, 3600.01);
    expect(
      () => DriverReminder.fromFirestore({
        ...data,
        'durationSeconds': double.nan,
      }),
      throwsFormatException,
    );
  });

  late _Reminders service;
  late _Location location;
  late _Alarms alarms;
  setUp(() {
    service = _Reminders();
    location = _Location();
    alarms = _Alarms();
  });
  tearDown(() async {
    await service.reminders.close();
  });

  DriverReminder pending({
    String driver = 'driver',
    Duration until = const Duration(minutes: 30),
  }) => DriverReminder(
    driverId: driver,
    generation: 'gen',
    dueAt: DateTime.now().add(until).subtract(const Duration(hours: 1)),
    departureDate: DateTime.now().add(until),
    state: 'sent',
  );

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DriverReminderPanel(
            orderId: 'course',
            driverId: 'driver',
            service: service,
            locationService: location,
            alarmService: alarms,
          ),
        ),
      ),
    );
    service.reminders.add(pending());
    await tester.pumpAndSettle();
  }

  testWidgets(
    'confirmation asks for consent before capturing GPS and sends the fix',
    (tester) async {
      await open(tester);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('confirm-availability')),
      );
      expect(button.onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('confirm-availability')));
      await tester.pumpAndSettle();
      expect(location.captures, 0);
      expect(find.textContaining('transmis à Google Maps'), findsOneWidget);
      await tester.tap(find.text('Partager ma position'));
      await tester.pumpAndSettle();
      expect(location.captures, 1);
      expect(service.confirmations, 1);
      expect(alarms.stops, ['course:gen']);
      expect(service.fix!.coordinates.latitude, 48);
      expect(find.byKey(const ValueKey('confirm-availability')), findsNothing);
      expect(find.text('Disponibilité confirmée'), findsOneWidget);
    },
  );

  testWidgets('silencing leaves availability unanswered and avoids GPS capture', (tester) async {
    await open(tester);
    await tester.tap(find.text('Couper le son'));
    await tester.pumpAndSettle();
    expect(alarms.silences, ['course:gen']);
    expect(alarms.stops, isEmpty);
    expect(service.confirmations, 0);
    expect(location.captures, 0);
    expect(find.text('Son coupé'), findsOneWidget);
    expect(find.byKey(const ValueKey('confirm-availability')), findsOneWidget);
  });

  testWidgets('failed local alarm stop never undoes a saved confirmation', (tester) async {
    await open(tester);
    alarms.failure = PlatformException(code: 'alarm-stop-failed');
    await tester.tap(find.byKey(const ValueKey('confirm-availability')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Partager ma position'));
    await tester.pumpAndSettle();
    expect(service.confirmations, 1);
    expect(find.text('Disponibilité confirmée'), findsOneWidget);
    expect(find.textContaining('La confirmation enregistrée reste valable'), findsOneWidget);
    expect(find.byKey(const ValueKey('confirm-availability')), findsNothing);
  });

  testWidgets('cancelled consent never captures or sends a position', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('confirm-availability')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(location.captures, 0);
    expect(service.confirmations, 0);
  });

  testWidgets('GPS and routing failures stay visible and allow retry', (
    tester,
  ) async {
    await open(tester);
    Future<void> confirm() async {
      await tester.tap(find.byKey(const ValueKey('confirm-availability')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Partager ma position'));
      await tester.pumpAndSettle();
    }

    location.failure = StateError('Activez la localisation pour continuer.');
    await confirm();
    expect(
      find.text('Activez la localisation pour continuer.'),
      findsOneWidget,
    );
    expect(service.confirmations, 0);
    location.failure = null;
    service.failure = FirebaseFunctionsException(
      code: 'unavailable',
      message: 'Calcul du trajet indisponible. Réessayez.',
    );
    await confirm();
    expect(
      find.text('Calcul du trajet indisponible. Réessayez.'),
      findsOneWidget,
    );
    service.failure = null;
    await confirm();
    expect(service.confirmations, 2);
    expect(
      find.text('Calcul du trajet indisponible. Réessayez.'),
      findsNothing,
    );
  });

  testWidgets('confirmed reminder displays route time and queued admin alert', (
    tester,
  ) async {
    await open(tester);
    service.reminders.add(
      DriverReminder(
        driverId: 'driver',
        generation: 'gen',
        dueAt: DateTime.now().subtract(const Duration(minutes: 30)),
        departureDate: DateTime.now().add(const Duration(minutes: 30)),
        state: 'confirmed',
        durationSeconds: 3601,
        routeDistanceMeters: 42000,
        adminAlertId: 'alert',
        confirmedAt: DateTime.now(),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Temps de trajet estimé : 61 min (avec trafic)'),
      findsOneWidget,
    );
    expect(find.text('Distance routière : 42.0 km'), findsOneWidget);
    expect(
      find.textContaining('alerte administrateur enregistrée'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('confirm-availability')), findsNothing);
  });

  testWidgets('foreign, future and expired reminders cannot be confirmed', (
    tester,
  ) async {
    await open(tester);
    for (final reminder in [
      pending(driver: 'other'),
      pending(until: const Duration(hours: 2)),
      pending(until: const Duration(minutes: -1)),
    ]) {
      service.reminders.add(reminder);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('confirm-availability')), findsNothing);
    }
    expect(find.text('Rappel non confirmé avant le départ.'), findsOneWidget);
  });
}
