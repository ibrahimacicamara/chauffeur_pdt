import 'package:chauffeur/widgets/driver_notification_session.dart';
import 'package:chauffeur/services/firebase/driver_reminder_service.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/services/reminder_alarm_service.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Settings extends Fake implements NotificationSettings {
  _Settings(this.authorizationStatus);

  @override
  final AuthorizationStatus authorizationStatus;
}

class _Messaging extends Fake implements FirebaseMessaging {
  AuthorizationStatus status = AuthorizationStatus.notDetermined;
  AuthorizationStatus requestedStatus = AuthorizationStatus.authorized;
  int requests = 0;
  int tokenRequests = 0;

  @override
  Stream<String> get onTokenRefresh => const Stream.empty();

  @override
  Future<RemoteMessage?> getInitialMessage() async => null;

  @override
  Future<NotificationSettings> getNotificationSettings() async =>
      _Settings(status);

  @override
  Future<NotificationSettings> requestPermission({
    bool alert = true,
    bool announcement = false,
    bool badge = true,
    bool carPlay = false,
    bool criticalAlert = false,
    bool provisional = false,
    bool sound = true,
    bool providesAppNotificationSettings = false,
  }) async {
    requests++;
    return _Settings(status = requestedStatus);
  }

  @override
  Future<void> setForegroundNotificationPresentationOptions({
    bool alert = false,
    bool badge = false,
    bool sound = false,
  }) async {}

  @override
  Future<String?> getToken({
    String? vapidKey,
    String? serviceWorkerScriptPath,
  }) async {
    tokenRequests++;
    return 'test-notification-token';
  }
}

class _Reminders extends DriverReminderService {
  final tokens = <String>[];

  @override
  Future<void> registerToken(String token) async => tokens.add(token);
}

class _Orders extends FireService {
  @override
  Stream<List<DriverOrder>> getOrdersForDriverStream(String driverId) =>
      Stream.value([]);
}

class _Alarms extends ReminderAlarmService {
  final bound = <String>[];
  int unbinds = 0;

  @override
  Stream<ReminderAlarmOpen> get openedAlarms => const Stream.empty();

  @override
  Future<ReminderAlarmOpen?> takeInitialAlarm() async => null;

  @override
  Future<bool> bindDriver(String driverId) async {
    bound.add(driverId);
    return true;
  }

  @override
  Future<void> unbindDriver() async { unbinds++; }
}

void main() {
  late _Alarms alarms;
  setUp(() { alarms = _Alarms(); });
  Future<void> open(
    WidgetTester tester,
    _Messaging messaging,
    _Reminders reminders,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DriverNotificationSession(
            driverId: 'driver',
            reminders: reminders,
            orders: _Orders(),
            messaging: messaging,
            alarmService: alarms,
            onSignOut: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('requests permission automatically and registers the device', (
    tester,
  ) async {
    final messaging = _Messaging();
    final reminders = _Reminders();
    await open(tester, messaging, reminders);
    expect(messaging.requests, 1);
    expect(reminders.tokens, ['test-notification-token']);
    expect(alarms.bound, isNotEmpty);
    expect(alarms.bound.every((id) => id == 'driver'), isTrue);
    expect(find.text('Activer les notifications'), findsNothing);
  });

  testWidgets('leaving driver session clears native account and alarms', (tester) async {
    await open(tester, _Messaging(), _Reminders());
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(alarms.unbinds, 1);
  });

  testWidgets('existing permissions do not display another request', (
    tester,
  ) async {
    for (final status in [
      AuthorizationStatus.authorized,
      AuthorizationStatus.provisional,
    ]) {
      await tester.pumpWidget(const SizedBox());
      final messaging = _Messaging()..status = status;
      final reminders = _Reminders();
      await open(tester, messaging, reminders);
      expect(messaging.requests, 0);
      expect(reminders.tokens, ['test-notification-token']);
    }
  });

  testWidgets('denied permission shows guidance and allows manual retry', (
    tester,
  ) async {
    final messaging = _Messaging()
      ..status = AuthorizationStatus.denied
      ..requestedStatus = AuthorizationStatus.denied;
    final reminders = _Reminders();
    await open(tester, messaging, reminders);
    expect(messaging.requests, 1);
    expect(messaging.tokenRequests, 0);
    expect(reminders.tokens, isEmpty);
    expect(
      find.text('Autorisez les notifications dans les réglages de l’appareil.'),
      findsOneWidget,
    );
    messaging.requestedStatus = AuthorizationStatus.authorized;
    await tester.tap(find.text('Activer les notifications'));
    await tester.pumpAndSettle();
    expect(messaging.requests, 2);
    expect(reminders.tokens, ['test-notification-token']);
  });

  test('missing callable explains the required deployment', () {
    final message = notificationActivationErrorMessage(
      FirebaseFunctionsException(code: 'not-found', message: 'NOT FOUND'),
    );
    expect(message, contains('n’est pas déployé'));
    expect(message, isNot(contains('NOT FOUND')));
  });

  test('expired session asks the driver to sign in again', () {
    expect(
      notificationActivationErrorMessage(
        FirebaseFunctionsException(code: 'unauthenticated', message: 'Expired'),
      ),
      contains('Reconnectez-vous'),
    );
  });

  test('profile errors preserve the server explanation', () {
    expect(
      notificationActivationErrorMessage(
        FirebaseFunctionsException(
          code: 'permission-denied',
          message: 'Profil chauffeur introuvable.',
        ),
      ),
      'Profil chauffeur introuvable.',
    );
  });

  test('temporary failures provide an actionable retry message', () {
    for (final code in ['unavailable', 'deadline-exceeded']) {
      expect(
        notificationActivationErrorMessage(
          FirebaseFunctionsException(code: code, message: 'Unavailable'),
        ),
        contains('connexion puis réessayez'),
      );
    }
  });

  test('messaging errors retain their diagnostic code', () {
    expect(
      notificationActivationErrorMessage(
        FirebaseException(plugin: 'firebase_messaging', code: 'token-error'),
      ),
      contains('token-error'),
    );
  });
}
