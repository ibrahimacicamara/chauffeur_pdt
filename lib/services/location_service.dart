import 'dart:async';

import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:geolocator/geolocator.dart';

class LocationFix {
  const LocationFix({required this.coordinates, required this.capturedAt});

  final GPSCoordinates coordinates;
  final DateTime capturedAt;
}

class LocationService {
  static const _settings = LocationSettings(
    accuracy: LocationAccuracy.high,
    timeLimit: Duration(seconds: 20),
  );

  Future<void> _checkAccess() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Activez la localisation pour continuer.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw StateError(
        'Autorisez la localisation dans les réglages de l’application.',
      );
    }
    if (permission != LocationPermission.whileInUse &&
        permission != LocationPermission.always) {
      throw StateError('La permission de localisation est nécessaire.');
    }
  }

  Future<LocationFix> currentFix() async {
    await _checkAccess();
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: _settings,
      );
      return LocationFix(
        coordinates: _coordinates(position),
        capturedAt: position.timestamp.toUtc(),
      );
    } on TimeoutException {
      throw StateError('Position GPS indisponible. Réessayez en extérieur.');
    }
  }

  Future<GPSCoordinates> currentPosition() async =>
      (await currentFix()).coordinates;

  Stream<GPSCoordinates> positionStream() async* {
    yield await currentPosition();
    yield* Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).map(_coordinates);
  }

  GPSCoordinates _coordinates(Position position) => GPSCoordinates(
    latitude: position.latitude,
    longitude: position.longitude,
  );
}
