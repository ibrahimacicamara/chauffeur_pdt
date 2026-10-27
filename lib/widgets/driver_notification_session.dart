import 'dart:async';

import 'package:chauffeur/screens/commande.dart';
import 'package:chauffeur/screens/current_com.dart';
import 'package:chauffeur/screens/driver_travel_alert_page.dart';
import 'package:chauffeur/services/firebase/driver_reminder_service.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/services/reminder_alarm_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String notificationActivationErrorMessage(Object error) {
  if (error is MissingPluginException) {
    return 'Réinstallez la version à jour de l’application pour activer les rappels sonores.';
  }
  if (error is FirebaseFunctionsException) {
    return switch (error.code) {
      'not-found' =>
        'Le service d’activation des notifications n’est pas déployé. '
            'Contactez l’administrateur.',
      'unauthenticated' => 'Votre session a expiré. Reconnectez-vous puis activez les notifications.',
      'permission-denied' =>
        error.message ?? 'Votre profil chauffeur ne permet pas l’activation.',
      'unavailable' || 'deadline-exceeded' =>
        'Le service de notifications est momentanément indisponible. '
            'Vérifiez votre connexion puis réessayez.',
      _ => 'Activation impossible (${error.code}). Réessayez.',
    };
  }
  if (error is FirebaseException) {
    return 'Notifications indisponibles (${error.code}). Réessayez.';
  }
  return 'Notifications indisponibles. Vérifiez les réglages et redémarrez l’application.';
}

class DriverNotificationSession extends StatefulWidget {
  const DriverNotificationSession({
    super.key,
    required this.driverId,
    required this.reminders,

    required this.onSignOut,
    this.orders,
    this.messaging,
    this.alarmService,
  });

  final String driverId;
  final DriverReminderService reminders;
  final FireService? orders;
  final FirebaseMessaging? messaging;
  final ReminderAlarmService? alarmService;
  final Future<void> Function() onSignOut;

  @override
  State<DriverNotificationSession> createState() =>
      _DriverNotificationSessionState();
}

class _DriverNotificationSessionState extends State<DriverNotificationSession> {
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _opened = <String>{};
  String? _token;
  final _registeredTokens = <String>{};
  Future<void>? _registration;
  String? _error;
  bool _enabled = false;
  bool _busy = false;
  bool _leaving = false;
  late final FireService _orders;
  late final FirebaseMessaging _messaging =
      widget.messaging ?? FirebaseMessaging.instance;
  late final ReminderAlarmService _alarms =
      widget.alarmService ?? ReminderAlarmService();

  bool get _supported =>
      !kIsWeb &&
      {
        TargetPlatform.android,
        TargetPlatform.iOS,
      }.contains(defaultTargetPlatform);

  @override
  void initState() {
    super.initState();
    _orders = widget.orders ?? FireService();
    if (_supported) {
      _subscriptions.add(FirebaseMessaging.onMessage.listen(_foreground));
      _subscriptions.add(FirebaseMessaging.onMessageOpenedApp.listen(_open));
      _subscriptions.add(_alarms.openedAlarms.listen(_openAlarm));
      _subscriptions.add(
        _messaging.onTokenRefresh.listen((token) {
          _registration = (_registration ?? Future<void>.value()).then(
            (_) => _register(token),
          );
        }),
      );
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_initialize()),
      );
    }
  }

  void _fail(Object error) {
    debugPrint('Driver notification setup failed: $error');
    if (!mounted) return;
    setState(() {
      _enabled = false;
      _error = notificationActivationErrorMessage(error);
    });
  }

  Future<void> _initialize() async {
    try {
      await _alarms.bindDriver(widget.driverId);
      final alarm = await _alarms.takeInitialAlarm();
      if (!mounted || _leaving) return;
      if (alarm != null) _openAlarm(alarm);
      final message = await _messaging.getInitialMessage();
      if (!mounted) return;
      if (message != null) _open(message);
      final settings = await _messaging.getNotificationSettings();
      if (!mounted || _leaving) return;
      await _enable(
        requestPermission:
            settings.authorizationStatus != AuthorizationStatus.authorized &&
            settings.authorizationStatus != AuthorizationStatus.provisional,
      );
    } on FirebaseException catch (error) {
      _fail(error);
    } on PlatformException catch (error) {
      _fail(error);
    } on MissingPluginException catch (error) {
      _fail(error);
    }
  }

  Future<void> _register(String token) async {
    if (_leaving || !mounted) return;
    try {
      await widget.reminders.registerToken(token);
      _token = token;
      _registeredTokens.add(token);
      if (_leaving || !mounted) return;
      setState(() {
        _enabled = true;
        _error = null;
      });
    } on FirebaseException catch (error) {
      _fail(error);
    } on PlatformException catch (error) {
      _fail(error);
    } on MissingPluginException catch (error) {
      _fail(error);
    }
  }

  Future<void> _enable({bool requestPermission = true}) async {
    if (!mounted || _busy || _leaving) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _alarms.bindDriver(widget.driverId);
      final messaging = _messaging;
      final settings = requestPermission
          ? await messaging.requestPermission()
          : await messaging.getNotificationSettings();
      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional) {
        if (mounted) {
          setState(
            () => _error =
                'Autorisez les notifications dans les réglages de l’appareil.',
          );
        }
        return;
      }
      await messaging.setForegroundNotificationPresentationOptions(
        alert: false,
        badge: false,
        sound: true,
      );
      final token = await messaging.getToken();
      if (token == null) {
        if (mounted) {
          setState(
            () => _error = 'Aucun jeton de notification disponible. Réessayez.',
          );
        }
        return;
      }
      await _register(token);
    } on FirebaseException catch (error) {
      _fail(error);
    } on PlatformException catch (error) {
      _fail(error);
    } on MissingPluginException catch (error) {
      _fail(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _mine(RemoteMessage message) {
    final type = message.data['type'];
    final orderId = message.data['orderId'];
    if (_leaving ||
        !mounted ||
        (type != 'driver_reminder' &&
            type != 'driver_reminder_alarm' &&
            type != 'driver_course' &&
            type != 'driver_travel_alert') ||
        message.data['driverId'] != widget.driverId ||
        orderId is! String ||
        orderId.isEmpty ||
        orderId.contains('/')) {
      return false;
    }
    if (type == 'driver_travel_alert') {
      final alertId = message.data['alertId'];
      return widget.driverId == 'YGE0x3Im8XUtmxWBtD740mszQ3B2' &&
          alertId is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(alertId);
    }
    return (type != 'driver_reminder' && type != 'driver_reminder_alarm') ||
        (message.data['generation'] is String &&
            (message.data['generation'] as String).isNotEmpty);
  }

  void _foreground(RemoteMessage message) {
    if (!_mine(message)) return;
    final isNewCourse = message.data['type'] == 'driver_course';
    final isAlert = message.data['type'] == 'driver_travel_alert';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 20),
        content: Text(
          isAlert
              ? message.data['alertKind'] == 'no_response'
                    ? 'Alerte : un chauffeur n’a pas confirmé sa disponibilité.'
                    : 'Alerte : le trajet d’un chauffeur dépasse une heure.'
              : isNewCourse
              ? 'Une nouvelle course correspondant à vos catégories est disponible.'
              : 'Votre course approche. Confirmez votre disponibilité.',
        ),
        action: SnackBarAction(
          label: isNewCourse ? 'Voir' : 'Ouvrir',
          onPressed: () => _open(message),
        ),
      ),
    );
  }

  void _openAlarm(ReminderAlarmOpen alarm) {
    if (alarm.action != 'open') return;
    _open(RemoteMessage(data: {
      'type': 'driver_reminder_alarm',
      'orderId': alarm.orderId,
      'driverId': alarm.driverId,
      'generation': alarm.generation,
    }));
  }

  void _open(RemoteMessage message) {
    if (!_mine(message)) return;
    final isNewCourse = message.data['type'] == 'driver_course';
    final isAlert = message.data['type'] == 'driver_travel_alert';
    final notificationId = isAlert
        ? 'alert:${message.data['alertId']}'
        : isNewCourse
        ? 'course:${message.data['orderId']}'
        : message.data['generation'] as String;
    if (!_opened.add(notificationId)) return;
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (context) => isAlert
                ? DriverTravelAlertPage(
                    alertId: message.data['alertId'] as String,
                    service: widget.reminders,
                  )
                : isNewCourse
                ? CommandePage(
                    driverId: widget.driverId,
                    service: _orders,
                    reminderService: widget.reminders,
                    onSignOut: _signOut,
                  )
                : CurrentCommandePage(
                    orderId: message.data['orderId'] as String,
                    driverId: widget.driverId,
                    service: _orders,
                    reminderService: widget.reminders,
                  ),
          ),
        )
        .whenComplete(() => _opened.remove(notificationId));
  }

  Future<void> _signOut() async {
    if (_leaving || _busy) return;
    _leaving = true;
    try {
      await _registration;
      if (_token != null) _registeredTokens.add(_token!);
      for (final token in _registeredTokens) {
        await widget.reminders.unregisterToken(token);
      }
      await _alarms.unbindDriver();
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      await widget.onSignOut();
    } on FirebaseException catch (error) {
      _fail(error);
    } on PlatformException catch (error) {
      _fail(error);
    } on MissingPluginException catch (error) {
      _fail(error);
    } finally {
      _leaving = false;
    }
  }

  @override
  void dispose() {
    _leaving = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_unbindAlarm());
    super.dispose();
  }

  Future<void> _unbindAlarm() async {
    try {
      await _alarms.unbindDriver();
    } on PlatformException catch (error) {
      debugPrint('Unable to clear driver alarm session: $error');
    } on MissingPluginException catch (error) {
      debugPrint('Native reminder alarm module is not installed: $error');
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (!_supported || !_enabled)
        SafeArea(
          bottom: false,
          child: Material(
            color: const Color(0xFFFFF4DF),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    !_supported
                        ? 'Les notifications push sont disponibles sur Android et iOS. La confirmation reste accessible dans la course.'
                        : _error ?? 'Activez les notifications pour recevoir les nouvelles courses et les rappels.',
                  ),
                  if (_supported)
                    TextButton(
                      onPressed: _busy ? null : () => _enable(),
                      child: Text(
                        _busy ? 'Activation…' : 'Activer les notifications',
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      Expanded(
        child: CommandePage(
          driverId: widget.driverId,
          service: _orders,
          reminderService: widget.reminders,
          onSignOut: _signOut,
        ),
      ),
    ],
  );
}
