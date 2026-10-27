import 'dart:async';

import 'package:chauffeur/services/reminder_alarm_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 26, 11);
  final data = <String, dynamic>{
    'type': 'driver_reminder_alarm',
    'orderId': 'course',
    'driverId': 'driver',
    'generation': 'generation',
    'alarmNotBefore': '${now.millisecondsSinceEpoch}',
    'expiresAt': '${now.add(const Duration(hours: 1)).millisecondsSinceEpoch}',
  };

  test('alarm validates account, expiry and not-before bounds', () {
    final alarm = ReminderAlarmPayload.tryParse(data)!;
    expect(alarm.rejectionFor(currentUid: 'driver', now: now), isNull);
    expect(alarm.rejectionFor(currentUid: null, now: now), 'not_signed_in');
    expect(
      alarm.rejectionFor(currentUid: 'other', now: now),
      'driver_mismatch',
    );
    expect(
      alarm.rejectionFor(currentUid: 'driver', now: alarm.expiresAt!),
      'expired',
    );
    expect(
      alarm.rejectionFor(
        currentUid: 'driver',
        now: now.subtract(const Duration(seconds: 121)),
      ),
      'too_early',
    );
  });

  test(
    'malformed and overflowing alarm data do not crash the background isolate',
    () {
      expect(ReminderAlarmPayload.tryParse({}), isNull);
      for (final expires in [
        'invalid',
        '999999999999999999',
        '-999999999999999999',
        '-9223372036854775808',
      ]) {
        expect(
          ReminderAlarmPayload.tryParse({...data, 'expiresAt': expires}),
          isNull,
        );
      }
      expect(ReminderAlarmPayload.tryParse({...data, 'driverId': ''}), isNull);
    },
  );

  test('stop requires matching account but does not require a fresh alarm timestamp', () {
    final stop = ReminderAlarmPayload.tryParse({
      ...data,
      'type': 'driver_reminder_alarm_stop',
      'expiresAt': null,
      'alarmNotBefore': null,
    })!;
    expect(stop.isStop, isTrue);
    expect(stop.rejectionFor(currentUid: 'driver', now: now), isNull);
    expect(stop.rejectionFor(currentUid: 'other', now: now), 'driver_mismatch');
  });

  test('background handler validates alarm and stop without using a native channel', () async {
    await ReminderAlarmService.handleBackgroundMessage(
      RemoteMessage(data: data),
      currentUid: () => 'driver',
      now: () => now,
    );
    await ReminderAlarmService.handleBackgroundMessage(
      RemoteMessage(data: {...data, 'type': 'driver_reminder_alarm_stop'}),
      currentUid: () => 'other',
      now: () => now,
    );
  });

  const channel = MethodChannel('test/reminder_alarm_bridge');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'bindDriver' || 'stop' || 'silence' => true,
        'takePendingOpens' => [
          {
            'orderId': 'course',
            'driverId': 'driver',
            'generation': 'generation',
            'action': 'open',
          },
        ],
        _ => null,
      };
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('bridge keeps silence separate from confirmation and stop', () async {
    final service = ReminderAlarmService(channel: channel, supported: true);
    expect(await service.bindDriver('driver'), isTrue);
    expect(await service.silence('course', 'generation'), isTrue);
    expect(await service.stop('course', 'generation'), isTrue);
    await service.unbindDriver();
    expect(calls.map((call) => call.method), [
      'bindDriver',
      'silence',
      'stop',
      'unbindDriver',
    ]);
    expect(calls[1].arguments, {
      'orderId': 'course',
      'generation': 'generation',
    });
  });

  test(
    'notification opens are shared by session and panel bridge instances',
    () async {
      final session = ReminderAlarmService(channel: channel, supported: true);
      final panel = ReminderAlarmService(channel: channel, supported: true);
      final opened = session.openedAlarms.first;
      final alsoOpened = panel.openedAlarms.first;
      final reply = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('onAlarmOpened')),
        (_) => reply.complete(),
      );
      await reply.future;
      expect((await opened).orderId, 'course');
      expect((await alsoOpened).generation, 'generation');
    },
  );

  test(
    'missing native module is not reported as a successful alarm command',
    () async {
      messenger.setMockMethodCallHandler(channel, null);
      final service = ReminderAlarmService(channel: channel, supported: true);
      await expectLater(
        service.stop('course', 'generation'),
        throwsA(isA<MissingPluginException>()),
      );
    },
  );
}
