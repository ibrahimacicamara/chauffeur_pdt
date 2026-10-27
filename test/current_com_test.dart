import 'dart:async';

import 'package:chauffeur/screens/commande.dart';
import 'package:chauffeur/screens/current_com.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:chauffeur/services/location_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

class _Service extends FireService {
  final order = StreamController<DriverOrder?>.broadcast();
  final requests = <OrderStatus>[];
  GPSCoordinates? position;
  StateError? failure;
  int releases = 0;

  @override
  Future<void> releaseOrder(
    String orderId, {
    required GPSCoordinates location,
  }) async {
    if (failure != null) throw failure!;
    releases++;
  }

  @override
  Stream<DriverOrder?> getOrderStream(String orderId) => order.stream;

  @override
  Stream<List<DriverOrder>> getOrdersStream() =>
      Stream.value([const DriverOrder(id: 'course', driverId: 'driver')]);

  @override
  Stream<List<DriverOrder>> getOrdersForDriverStream(String driverId) =>
      getOrdersStream();

  @override
  Future<void> advanceOrderStatus({
    required String orderId,
    required OrderStatus expectedStatus,
    required OrderStatus nextStatus,
    required GPSCoordinates location,
  }) async {
    if (failure != null) throw failure!;
    requests.add(nextStatus);
    position = location;
    order.add(
      DriverOrder(
        id: orderId,
        driverId: 'driver',
        commandStatus: [
          CommandStatus(
            date: DateTime(2026, 10, 11),
            status: nextStatus,
            id: 'driver',
            location: location,
          ),
        ],
      ),
    );
  }
}

class _Location extends LocationService {
  StateError? failure;
  Completer<GPSCoordinates>? pending;
  int calls = 0;

  @override
  Future<GPSCoordinates> currentPosition() async {
    calls++;
    if (failure != null) throw failure!;
    if (pending != null) return pending!.future;
    return GPSCoordinates(latitude: 48.8566, longitude: 2.3522);
  }
}

class _GeoPlatform extends GeolocatorPlatform {
  bool enabled = true;
  LocationPermission permission = LocationPermission.denied;
  LocationPermission granted = LocationPermission.whileInUse;
  int requests = 0;
  int positions = 0;
  Object? failure;

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      const Stream.empty();

  @override
  Future<bool> isLocationServiceEnabled() async => enabled;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return granted;
  }

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    positions++;
    if (failure != null) throw failure!;
    return Position(
      latitude: 48.8566,
      longitude: 2.3522,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
  }
}

void main() {
  test(
    'Location stream provides a first fix without waiting for movement',
    () async {
      final original = GeolocatorPlatform.instance;
      final platform = _GeoPlatform();
      GeolocatorPlatform.instance = platform;
      addTearDown(() => GeolocatorPlatform.instance = original);

      final positions = await LocationService().positionStream().toList();

      expect(platform.positions, 1);
      expect(positions, hasLength(1));
      expect(positions.single.latitude, 48.8566);
      expect(positions.single.longitude, 2.3522);
    },
  );

  test('Formats French dates and isolates malformed histories', () {
    expect(
      formatCourseDate(DateTime(2026, 10, 12, 9, 5)),
      '12/10/2026 à 09:05',
    );
    final order = DriverOrder.fromFirestore('bad', {
      'departureAddress': 'Paris',
      'commandStatus': 'invalid',
    });
    expect(order.departureAddress, 'Paris');
    expect(order.historyError, isNotNull);
    expect(() => order.currentStatus, throwsFormatException);
  });

  Future<void> open(
    WidgetTester tester,
    _Service service,
    _Location location,
  ) => tester.pumpWidget(
    MaterialApp(
      home: CurrentCommandePage(
        orderId: 'course',
        driverId: 'driver',
        service: service,
        locationService: location,
      ),
    ),
  );

  Future<void> confirm(WidgetTester tester) async {
    final button = find.byKey(const ValueKey('advance-status'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Confirmer'));
    await tester.pumpAndSettle();
  }

  testWidgets('Release is confirmed explicitly and hidden after boarding', (
    tester,
  ) async {
    final service = _Service();
    final location = _Location();
    addTearDown(service.order.close);
    await open(tester, service, location);
    for (final stage in [
      OrderStatus.ASSIGNED,
      OrderStatus.EN_ROUTE,
      OrderStatus.ON_SITE,
    ]) {
      service.order.add(
        DriverOrder(
          id: 'course',
          driverId: 'driver',
          commandStatus: [
            CommandStatus(
              date: DateTime(2026),
              status: stage,
              id: 'driver',
              location: const GPSCoordinates(latitude: 48, longitude: 2),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('release-order'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Garder la course'));
      await tester.pumpAndSettle();
      expect(service.releases, 0);
      expect(location.calls, 0);
    }
    service.failure = StateError('Attribution modifiée');
    final button = find.byKey(const ValueKey('release-order'));
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, 'Remettre en attente'));
    await tester.pumpAndSettle();
    expect(find.text('Attribution modifiée'), findsOneWidget);
    service.order.add(
      DriverOrder(
        id: 'course',
        driverId: 'driver',
        commandStatus: [
          CommandStatus(
            date: DateTime(2026),
            status: OrderStatus.CLIENT_ON_BOARD,
            id: 'driver',
            location: const GPSCoordinates(latitude: 48, longitude: 2),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('release-order')), findsNothing);
  });

  test(
    'Location permission, disabled service and timeout are explicit',
    () async {
      final original = GeolocatorPlatform.instance;
      final platform = _GeoPlatform();
      GeolocatorPlatform.instance = platform;
      addTearDown(() => GeolocatorPlatform.instance = original);
      final location = LocationService();
      final position = await location.currentPosition();
      expect(position.latitude, 48.8566);
      expect(platform.requests, 1);
      platform.enabled = false;
      await expectLater(location.currentPosition(), throwsStateError);
      platform.enabled = true;
      platform.permission = LocationPermission.deniedForever;
      await expectLater(location.currentPosition(), throwsStateError);
      expect(platform.positions, 1);
      platform.permission = LocationPermission.denied;
      platform.granted = LocationPermission.denied;
      await expectLater(location.currentPosition(), throwsStateError);
      platform.permission = LocationPermission.whileInUse;
      platform.failure = TimeoutException('GPS');
      await expectLater(location.currentPosition(), throwsStateError);
    },
  );

  testWidgets('Shows loading, deletion, access denial and stream errors', (
    tester,
  ) async {
    final service = _Service();
    addTearDown(service.order.close);
    await open(tester, service, _Location());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    service.order.add(null);
    await tester.pumpAndSettle();
    expect(find.text('Cette commande n’existe plus.'), findsOneWidget);
    service.order.add(const DriverOrder(id: 'course', driverId: 'other'));
    await tester.pumpAndSettle();
    expect(
      find.text('Cette commande ne vous est pas attribuée.'),
      findsOneWidget,
    );
    service.order.addError(
      FirebaseException(plugin: 'firestore', code: 'permission-denied'),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('permission-denied'), findsOneWidget);
    expect(find.text('Réessayer'), findsOneWidget);
  });

  testWidgets('Confirms a stage with GPS and displays the live history', (
    tester,
  ) async {
    final service = _Service();
    final location = _Location();
    addTearDown(service.order.close);
    await open(tester, service, location);
    service.order.add(
      const DriverOrder(
        id: 'course',
        driverId: 'driver',
        departureAddress: 'Paris',
        steps: ['Orly'],
      ),
    );
    await tester.pumpAndSettle();
    await confirm(tester);
    expect(service.requests, [OrderStatus.EN_ROUTE]);
    expect(service.position!.latitude, 48.8566);
    expect(location.calls, 1);
    expect(find.text('Passer à « Sur place »'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('GPS :'), 300);
    expect(find.textContaining('48.85660, 2.35220'), findsOneWidget);
  });

  testWidgets('Refuses updates without GPS and surfaces stale-status errors', (
    tester,
  ) async {
    final service = _Service();
    final location = _Location()
      ..failure = StateError('Autorisez la localisation.');
    addTearDown(service.order.close);
    await open(tester, service, location);
    service.order.add(const DriverOrder(id: 'course', driverId: 'driver'));
    await tester.pumpAndSettle();
    await confirm(tester);
    expect(find.text('Autorisez la localisation.'), findsOneWidget);
    expect(service.requests, isEmpty);
    location.failure = null;
    service.failure = StateError('Le statut a changé.');
    await confirm(tester);
    expect(find.text('Le statut a changé.'), findsOneWidget);
    expect(service.requests, isEmpty);
  });

  testWidgets('Cancelling confirmation neither locates nor writes', (
    tester,
  ) async {
    final service = _Service();
    final location = _Location();
    addTearDown(service.order.close);
    await open(tester, service, location);
    service.order.add(const DriverOrder(id: 'course', driverId: 'driver'));
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('advance-status'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Retour'));
    await tester.pumpAndSettle();
    expect(location.calls, 0);
    expect(service.requests, isEmpty);
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
  });

  testWidgets('Finished course has no action and fits a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _Service();
    addTearDown(service.order.close);
    await open(tester, service, _Location());
    service.order.add(
      const DriverOrder(id: 'course', driverId: 'driver', status: 'Terminée'),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('advance-status')), findsNothing);
    await tester.scrollUntilVisible(find.text('Historique de la course'), 300);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Malformed history blocks actions without inventing a stage', (
    tester,
  ) async {
    final service = _Service();
    addTearDown(service.order.close);
    await open(tester, service, _Location());
    service.order.add(
      DriverOrder.fromFirestore('bad', {
        'commandStatus': {'status': 'unknown'},
      }),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('historique invalide'), findsOneWidget);
    expect(find.byKey(const ValueKey('advance-status')), findsNothing);
    expect(service.requests, isEmpty);
  });

  testWidgets('Active course fits mobile and blocks taps while locating', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _Service();
    final location = _Location()..pending = Completer<GPSCoordinates>();
    addTearDown(service.order.close);
    await open(tester, service, location);
    service.order.add(const DriverOrder(id: 'course', driverId: 'driver'));
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('advance-status'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Confirmer'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.tap(button);
    expect(location.calls, 1);
    expect(service.requests, isEmpty);
    location.pending!.complete(GPSCoordinates(latitude: 48, longitude: 2));
    await tester.pumpAndSettle();
    expect(service.requests, [OrderStatus.EN_ROUTE]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Opens the current course from the orders page', (tester) async {
    final service = _Service();
    addTearDown(service.order.close);
    await tester.pumpWidget(
      MaterialApp(
        home: CommandePage(driverId: 'driver', service: service),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Courses attribuées'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gérer ma commande'));
    await tester.pump();
    service.order.add(const DriverOrder(id: 'course', driverId: 'driver'));
    await tester.pumpAndSettle();
    expect(find.text('Ma commande'), findsOneWidget);
    expect(find.text('VOTRE MISSION'), findsOneWidget);
  });

  testWidgets('CurrentCommandePage displays download voucher button', (
    tester,
  ) async {
    final service = _Service();
    addTearDown(service.order.close);
    await open(tester, service, _Location());
    service.order.add(const DriverOrder(id: 'course', driverId: 'driver'));
    await tester.pumpAndSettle();

    final voucherButton = find.byKey(
      const ValueKey('current-order-download-voucher'),
    );
    expect(voucherButton, findsOneWidget);
    expect(find.text('Télécharger le bon de commande'), findsOneWidget);
  });

  testWidgets('Shows the first client name on a full-screen board', (
    tester,
  ) async {
    final service = _Service();
    addTearDown(service.order.close);
    await open(tester, service, _Location());
    service.order.add(const DriverOrder(id: 'course', driverId: 'driver'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('show-client-name-board')), findsNothing);

    service.order.add(
      DriverOrder(
        id: 'course',
        driverId: 'driver',
        clients: [
          MyClient(name: '  ', phone: ''),
          MyClient(name: 'Jean Dupont', phone: '0600000000'),
          MyClient(name: 'Marie Martin', phone: ''),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('show-client-name-board'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    final board = find.byKey(const ValueKey('client-name-board-text'));
    expect(tester.widget<Text>(board).data, 'JEAN DUPONT');
    final logo = find.byKey(const ValueKey('client-name-board-logo'));
    expect(logo, findsOneWidget);
    final boardBounds = tester.getRect(find.byType(SafeArea).last);
    final logoBounds = tester.getRect(logo);
    expect(logoBounds.right, closeTo(boardBounds.right - 20, 1));
    expect(logoBounds.bottom, closeTo(boardBounds.bottom - 16, 1));
    expect(find.text('MARIE MARTIN'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('client-name-board-close')));
    await tester.pumpAndSettle();
    expect(board, findsNothing);
    expect(find.text('Ma commande'), findsOneWidget);
  });
}
