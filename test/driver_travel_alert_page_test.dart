import 'package:chauffeur/screens/driver_travel_alert_page.dart';
import 'package:chauffeur/services/firebase/driver_reminder_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Alerts extends DriverReminderService {
  Map<String, dynamic>? data;

  @override
  Stream<Map<String, dynamic>?> watchTravelAlert(String alertId) =>
      Stream.value(data);
}

void main() {
  testWidgets(
    'admin sees a missing confirmation alert without route duration',
    (tester) async {
      final service = _Alerts()
        ..data = {
          'kind': 'no_response',
          'orderId': 'course-test',
          'driverId': 'driver-test',
          'state': 'sent',
          'departureDate': Timestamp.fromDate(DateTime.utc(2026, 10, 26, 12)),
          'createdAt': Timestamp.fromDate(DateTime.utc(2026, 10, 26, 11)),
        };
      await tester.pumpWidget(
        MaterialApp(
          home: DriverTravelAlertPage(alertId: 'alert', service: service),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Chauffeur sans réponse'), findsOneWidget);
      expect(
        find.textContaining('Aucune confirmation enregistrée cinq minutes'),
        findsOneWidget,
      );
      expect(find.textContaining('Temps estimé avec trafic'), findsNothing);
    },
  );
  testWidgets(
    'admin can read alert duration, course and driver from the push destination',
    (tester) async {
      final service = _Alerts()
        ..data = {
          'orderId': 'course-test',
          'driverId': 'driver-test',
          'durationSeconds': 3601,
          'state': 'sent',
          'departureDate': Timestamp.fromDate(DateTime.utc(2026, 10, 26, 12)),
          'createdAt': Timestamp.fromDate(DateTime.utc(2026, 10, 26, 11)),
        };
      await tester.pumpWidget(
        MaterialApp(
          home: DriverTravelAlertPage(alertId: 'alert', service: service),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Temps estimé avec trafic : 61 min'), findsOneWidget);
      expect(find.text('Course : course-test'), findsOneWidget);
      expect(find.text('Chauffeur : driver-test'), findsOneWidget);
    },
  );

  testWidgets('missing and malformed alerts are explicitly displayed', (
    tester,
  ) async {
    for (final data in <Map<String, dynamic>?>[null, {}]) {
      await tester.pumpWidget(const SizedBox());
      final service = _Alerts()..data = data;
      await tester.pumpWidget(
        MaterialApp(
          home: DriverTravelAlertPage(alertId: 'alert', service: service),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          data == null
              ? 'Cette alerte n’existe plus.'
              : 'Le format de cette alerte est invalide.',
        ),
        findsOneWidget,
      );
    }
  });
}
