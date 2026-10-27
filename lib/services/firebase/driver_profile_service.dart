import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class DriverProfileService {
  DriverProfileService({this.firestore});

  final FirebaseFirestore? firestore;
  FirebaseFirestore get _database => firestore ?? FirebaseFirestore.instance;

  Future<List<String>> getCarNames() async {
    final snapshot = await _database.collection('Cars').get();
    final names = <String>{};
    for (final document in snapshot.docs) {
      final name = document.data()['name'];
      if (name is! String || name.trim().isEmpty) {
        throw FormatException(
          'Le véhicule ${document.id} ne possède pas de nom valide.',
        );
      }
      names.add(name.trim());
    }
    return names.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  DocumentReference<Map<String, dynamic>> _driver(String uid) {
    if (uid.trim().isEmpty || uid.contains('/')) {
      throw ArgumentError.value(uid, 'uid', 'UID chauffeur invalide');
    }
    return _database.collection('Drivers').doc(uid);
  }

  Future<MyDriver?> getDriver(String uid) async {
    final snapshot = await _driver(uid)
        .get(const GetOptions(source: Source.server));
    final data = snapshot.data();
    return data == null ? null : MyDriver.fromJson(data);
  }

  Stream<MyDriver?> watchDriver(String uid) =>
      _driver(uid).snapshots().map((snapshot) {
        final data = snapshot.data();
        return data == null ? null : MyDriver.fromJson(data);
      });

  Future<MyDriver> createProfile(
    String uid, {
    required String name,
    required String phone,
    required String car,
    required String licensePlate,
  }) async {
    final driver = MyDriver(
      name: name.trim(),
      phone: phone.replaceAll(RegExp(r'[\s().-]'), ''),
      car: car.trim(),
      licensePlate: licensePlate.trim().toUpperCase(),
      categories: ["eco"],
      available: true,
    );
    if (driver.name.isEmpty || driver.car.isEmpty) {
      throw ArgumentError('Le nom et le véhicule sont obligatoires.');
    }
    if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(driver.phone)) {
      throw ArgumentError('Numéro de téléphone international invalide.');
    }
    if (driver.licensePlate.isEmpty) {
      throw ArgumentError('La plaque d’immatriculation est obligatoire.');
    }
    final reference = _driver(uid);
    return _database.runTransaction((transaction) async {
      final snapshot = await transaction.get(reference);
      final existing = snapshot.data();
      if (existing != null) return MyDriver.fromJson(existing);
      transaction.set(reference, MyDriver.toJson(driver));
      return driver;
    });
  }
}
