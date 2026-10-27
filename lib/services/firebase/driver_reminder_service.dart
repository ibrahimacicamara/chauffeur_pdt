import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:chauffeur/services/location_service.dart';

class DriverReminder {
  const DriverReminder({
    required this.driverId,
    required this.generation,
    required this.dueAt,
    required this.departureDate,
    required this.state,
    this.confirmedAt,
    this.positionCapturedAt,
    this.distanceMeters,
    this.distanceError,
    this.durationSeconds,
    this.routeDistanceMeters,
    this.estimatedArrivalAt,
    this.adminAlertId,
  });

  final String driverId;
  final String generation;
  final DateTime dueAt;
  final DateTime departureDate;
  final String state;
  final DateTime? confirmedAt;
  final DateTime? positionCapturedAt;
  final int? distanceMeters;
  final String? distanceError;
  final double? durationSeconds;
  final double? routeDistanceMeters;
  final DateTime? estimatedArrivalAt;
  final String? adminAlertId;

  bool canConfirm(DateTime now) =>
      state != 'confirmed' &&
      state != 'cancelled' &&
      !now.isBefore(dueAt) &&
      now.isBefore(departureDate);

  factory DriverReminder.fromFirestore(Map<String, dynamic> data) {
    T? optional<T>(String field) {
      final value = data[field];
      if (value == null) return null;
      if (value is T) return value;
      throw FormatException('Rappel : champ $field invalide.');
    }

    final driverId = optional<String>('driverId');
    final generation = optional<String>('generation');
    final state = optional<String>('state');
    final dueAt = optional<Timestamp>('dueAt');
    final departureDate = optional<Timestamp>('departureDate');
    final durationSeconds = optional<num>('durationSeconds');
    final routeDistanceMeters = optional<num>('routeDistanceMeters');
    if ((durationSeconds != null &&
            (!durationSeconds.isFinite || durationSeconds < 0)) ||
        (routeDistanceMeters != null &&
            (!routeDistanceMeters.isFinite || routeDistanceMeters < 0))) {
      throw const FormatException('Estimation du trajet invalide.');
    }
    if (driverId == null ||
        generation == null ||
        dueAt == null ||
        departureDate == null ||
        !{
          'pending',
          'sent',
          'confirmed',
          'cancelled',
          'unconfirmed',
          'failed',
        }.contains(state)) {
      throw const FormatException('Rappel de disponibilité invalide.');
    }
    return DriverReminder(
      driverId: driverId,
      generation: generation,
      dueAt: dueAt.toDate(),
      departureDate: departureDate.toDate(),
      state: state!,
      confirmedAt: optional<Timestamp>('confirmedAt')?.toDate(),
      positionCapturedAt: optional<Timestamp>('positionCapturedAt')?.toDate(),
      distanceMeters: optional<int>('distanceMeters'),
      distanceError: optional<String>('distanceError'),
      durationSeconds: durationSeconds?.toDouble(),
      routeDistanceMeters: routeDistanceMeters?.toDouble(),
      estimatedArrivalAt: optional<Timestamp>('estimatedArrivalAt')?.toDate(),
      adminAlertId: optional<String>('adminAlertId'),
    );
  }
}

class DriverReminderService {
  DriverReminderService({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
  }) : _firestore = firestore,
       _functions = functions;

  final FirebaseFirestore? _firestore;
  final FirebaseFunctions? _functions;
  FirebaseFunctions get functions =>
      _functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1');

  Stream<DriverReminder?> watch(String orderId) =>
      (_firestore ?? FirebaseFirestore.instance)
          .collection('DriverReminders')
          .doc(orderId)
          .snapshots()
          .map((snapshot) {
            final data = snapshot.data();
            return data == null ? null : DriverReminder.fromFirestore(data);
          });

  Future<void> registerToken(String token) async {
    await functions.httpsCallable('registerDriverPushToken').call<void>({
      'token': token,
    });
  }

  Future<void> unregisterToken(String token) async {
    await functions.httpsCallable('unregisterDriverPushToken').call<void>({
      'token': token,
    });
  }

  Future<void> confirmAvailability(
    String orderId,
    String generation,
    LocationFix fix,
  ) async {
    await functions
        .httpsCallable(
          'confirmDriverAvailability',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
        )
        .call<void>({
          'orderId': orderId,
          'generation': generation,
          'position': {
            'latitude': fix.coordinates.latitude,
            'longitude': fix.coordinates.longitude,
            'capturedAt': fix.capturedAt.millisecondsSinceEpoch,
          },
        });
  }

  Stream<Map<String, dynamic>?> watchTravelAlert(String alertId) =>
      (_firestore ?? FirebaseFirestore.instance)
          .collection('DriverTravelAlerts')
          .doc(alertId)
          .snapshots()
          .map((snapshot) => snapshot.data());
}
