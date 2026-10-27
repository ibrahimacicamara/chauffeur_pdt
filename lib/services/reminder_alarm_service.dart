import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// FCM data keys/types of the Android data-only reminder alarm messages.
abstract final class ReminderAlarmFcm {
  static const alarmType = 'driver_reminder_alarm';
  static const stopType = 'driver_reminder_alarm_stop';
  static const maxWindow = Duration(hours: 12);
  static const clockSkew = Duration(minutes: 2);
}

class ReminderAlarmPayload {
  const ReminderAlarmPayload({
    required this.type,
    required this.orderId,
    required this.driverId,
    required this.generation,
    this.expiresAt,
    this.alarmNotBefore,
  });

  final String type;
  final String orderId;
  final String driverId;
  final String generation;
  final DateTime? expiresAt;
  final DateTime? alarmNotBefore;

  bool get isStop => type == ReminderAlarmFcm.stopType;

  /// Returns null when [data] is not a well-formed reminder alarm/stop message.
  static ReminderAlarmPayload? tryParse(Map<String, dynamic> data) {
    final type = data['type'];
    if (type != ReminderAlarmFcm.alarmType && type != ReminderAlarmFcm.stopType) {
      return null;
    }
    String? id(String key) {
      final value = data[key];
      return value is String && value.trim().isNotEmpty && value.length <= 256
          ? value
          : null;
    }

    DateTime? millis(String key) {
      final value = data[key];
      final parsed = value is String ? int.tryParse(value.trim()) : null;
      if (parsed == null ||
          parsed < -8640000000000000 ||
          parsed > 8640000000000000) {
        return null;
      }
      return DateTime.fromMillisecondsSinceEpoch(parsed);
    }

    final orderId = id('orderId');
    final driverId = id('driverId');
    final generation = id('generation');
    if (orderId == null || driverId == null || generation == null) return null;
    if (type == ReminderAlarmFcm.stopType) {
      return ReminderAlarmPayload(
        type: type as String,
        orderId: orderId,
        driverId: driverId,
        generation: generation,
      );
    }
    final expiresAt = millis('expiresAt');
    final alarmNotBefore = millis('alarmNotBefore');
    if (expiresAt == null || alarmNotBefore == null) return null;
    return ReminderAlarmPayload(
      type: type as String,
      orderId: orderId,
      driverId: driverId,
      generation: generation,
      expiresAt: expiresAt,
      alarmNotBefore: alarmNotBefore,
    );
  }

  /// Same checks as the native receiver. Returns null when acceptable, otherwise a reason.
  String? rejectionFor({required String? currentUid, required DateTime now}) {
    if (currentUid == null) return 'not_signed_in';
    if (currentUid != driverId) return 'driver_mismatch';
    if (isStop) return null;
    final expires = expiresAt!;
    final notBefore = alarmNotBefore!;
    if (!expires.isAfter(now)) return 'expired';
    if (expires.difference(now) > ReminderAlarmFcm.maxWindow) {
      return 'invalid_time_bounds';
    }
    if (notBefore.isAfter(expires)) return 'invalid_time_bounds';
    if (notBefore.difference(now) > ReminderAlarmFcm.clockSkew) return 'too_early';
    return null;
  }
}

class ReminderAlarmOpen {
  const ReminderAlarmOpen({
    required this.orderId,
    required this.driverId,
    required this.generation,
    required this.action,
  });

  final String orderId;
  final String driverId;
  final String generation;

  /// Currently always `open` (notification tap).
  final String action;

  static ReminderAlarmOpen? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final orderId = raw['orderId'];
    final driverId = raw['driverId'];
    final generation = raw['generation'];
    final action = raw['action'];
    if (orderId is! String ||
        driverId is! String ||
        generation is! String ||
        action is! String) {
      return null;
    }
    return ReminderAlarmOpen(
      orderId: orderId,
      driverId: driverId,
      generation: generation,
      action: action,
    );
  }
}

class ReminderAlarmInfo {
  const ReminderAlarmInfo({
    required this.orderId,
    required this.driverId,
    required this.generation,
    required this.expiresAt,
    required this.alarmNotBefore,
    required this.silenced,
  });

  final String orderId;
  final String driverId;
  final String generation;
  final DateTime expiresAt;
  final DateTime alarmNotBefore;
  final bool silenced;

  static ReminderAlarmInfo? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final orderId = raw['orderId'];
    final driverId = raw['driverId'];
    final generation = raw['generation'];
    final expiresAt = raw['expiresAt'];
    final alarmNotBefore = raw['alarmNotBefore'];
    final silenced = raw['silenced'];
    if (orderId is! String ||
        driverId is! String ||
        generation is! String ||
        expiresAt is! int ||
        alarmNotBefore is! int ||
        silenced is! bool) {
      return null;
    }
    return ReminderAlarmInfo(
      orderId: orderId,
      driverId: driverId,
      generation: generation,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt),
      alarmNotBefore: DateTime.fromMillisecondsSinceEpoch(alarmNotBefore),
      silenced: silenced,
    );
  }
}

/// Native result codes: `start_requested`, `fallback_notification` (foreground service refused,
/// insistent notification posted instead), or a rejection (`already_active`, `stopped`,
/// `silenced`, `not_bound`, `driver_mismatch`, `expired`, `too_early`, `invalid_time_bounds`,
/// `invalid_identifiers`), or `unsupported_platform`.
class ReminderAlarmStartResult {
  const ReminderAlarmStartResult(this.code);

  final String code;

  bool get startRequested =>
      code == 'start_requested' || code == 'fallback_notification';
}

/// Android-only bridge to the native persistent reminder alarm.
///
/// Alarm start/stop from FCM is handled natively (works with the app killed); this bridge
/// binds the signed-in driver, stops/silences per (orderId, generation) and reports taps.
/// On non-Android platforms every method is a no-op returning false/null/empty.
class ReminderAlarmService {
  ReminderAlarmService({MethodChannel? channel, bool? supported})
    : _channel = channel ?? _defaultChannel,
      _supportedOverride = supported;

  static const _defaultChannel = MethodChannel(
    'com.example.chauffeur/reminder_alarm',
  );
  static final _opened = StreamController<ReminderAlarmOpen>.broadcast();
  static final _changed = StreamController<void>.broadcast();
  static final _handlerChannels = <MethodChannel>{};

  final MethodChannel _channel;
  final bool? _supportedOverride;

  bool get supported =>
      _supportedOverride ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  /// Notification taps received while the app is running.
  Stream<ReminderAlarmOpen> get openedAlarms {
    _ensureHandler();
    return _opened.stream;
  }

  /// Fires when native alarm state changes (started, silenced, stopped).
  Stream<void> get alarmsChanged {
    _ensureHandler();
    return _changed.stream;
  }

  void _ensureHandler() {
    if (!supported || !_handlerChannels.add(_channel)) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onAlarmOpened':
          for (final open in await _drainOpens()) {
            _opened.add(open);
          }
        case 'onAlarmsChanged':
          _changed.add(null);
      }
      return null;
    });
  }

  Future<List<ReminderAlarmOpen>> _drainOpens() async {
    final raw = await _channel.invokeListMethod<Object?>('takePendingOpens');
    return [
      for (final item in raw ?? const <Object?>[])
        ?ReminderAlarmOpen.fromMap(item),
    ];
  }

  /// Returns the latest unconsumed notification tap (launch or resume), once.
  Future<ReminderAlarmOpen?> takeInitialAlarm() async {
    if (!supported) return null;
    _ensureHandler();
    final opens = await _drainOpens();
    return opens.isEmpty ? null : opens.last;
  }

  /// Binds the signed-in Firebase UID; alarms for other UIDs are rejected natively.
  /// Throws [PlatformException] on native rejection.
  Future<bool> bindDriver(String driverId) async {
    if (!supported) return false;
    _ensureHandler();
    return await _channel.invokeMethod<bool>('bindDriver', {
          'driverId': driverId,
        }) ??
        false;
  }

  /// Unbinds the driver and stops every alarm (call at sign-out).
  Future<void> unbindDriver() async {
    if (!supported) return;
    await _channel.invokeMethod<void>('unbindDriver');
  }

  /// Stops every alarm of the bound driver (tombstoned) while keeping the binding.
  Future<void> stopAll() async {
    if (!supported) return;
    await _channel.invokeMethod<void>('stopAll');
  }

  /// Stops and tombstones exactly this order generation for the bound driver.
  /// Returns true once persisted (even if it was not ringing); throws
  /// [PlatformException] (`not_bound`, `invalid_argument`) otherwise.
  Future<bool> stop(String orderId, String generation) async {
    if (!supported) return false;
    return await _channel.invokeMethod<bool>('stop', {
          'orderId': orderId,
          'generation': generation,
        }) ??
        false;
  }

  /// "Couper le son": silences this generation without confirming it. A later alarm
  /// message for the same generation stays silent. Same return/throw contract as [stop].
  Future<bool> silence(String orderId, String generation) async {
    if (!supported) return false;
    return await _channel.invokeMethod<bool>('silence', {
          'orderId': orderId,
          'generation': generation,
        }) ??
        false;
  }

  Future<List<ReminderAlarmInfo>> activeAlarms() async {
    if (!supported) return const [];
    final raw = await _channel.invokeListMethod<Object?>('activeAlarms');
    return [
      for (final item in raw ?? const <Object?>[])
        ?ReminderAlarmInfo.fromMap(item),
    ];
  }

  Future<bool> notificationsEnabled() async {
    if (!supported) return false;
    return await _channel.invokeMethod<bool>('notificationsEnabled') ?? false;
  }

  /// Manual start (normally unnecessary: the native FCM receiver starts alarms).
  Future<ReminderAlarmStartResult> start(ReminderAlarmPayload payload) async {
    if (!supported || payload.isStop) {
      return const ReminderAlarmStartResult('unsupported_platform');
    }
    final code = await _channel.invokeMethod<String>('start', {
      'orderId': payload.orderId,
      'driverId': payload.driverId,
      'generation': payload.generation,
      'expiresAt': payload.expiresAt!.millisecondsSinceEpoch,
      'alarmNotBefore': payload.alarmNotBefore!.millisecondsSinceEpoch,
    });
    return ReminderAlarmStartResult(code ?? 'error');
  }

  /// Background-isolate handler. On Android the native receiver already started/stopped the
  /// alarm (no plugin channel exists in this isolate), so this only validates and logs.
  static Future<void> handleBackgroundMessage(
    RemoteMessage message, {
    String? Function()? currentUid,
    DateTime Function()? now,
  }) async {
    final payload = ReminderAlarmPayload.tryParse(message.data);
    if (payload == null) {
      if (message.data['type'] == ReminderAlarmFcm.alarmType ||
          message.data['type'] == ReminderAlarmFcm.stopType) {
        debugPrint('[ReminderAlarm] background ${message.data['type']}: malformed');
      }
      return;
    }
    final uid = currentUid != null
        ? currentUid()
        : FirebaseAuth.instance.currentUser?.uid;
    final rejection = payload.rejectionFor(
      currentUid: uid,
      now: (now ?? DateTime.now)(),
    );
    debugPrint(
      '[ReminderAlarm] background ${payload.type} ${payload.orderId}/'
      '${payload.generation} id=${message.messageId}: '
      '${rejection ?? 'valid'} (playback owned by native Android receiver)',
    );
  }
}