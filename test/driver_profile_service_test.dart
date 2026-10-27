import 'package:chauffeur/services/firebase/driver_profile_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

class _Database extends Fake implements FirebaseFirestore {
  String? path;
  Map<String, dynamic>? data;
  GetOptions? options;
  FirebaseException? failure;
  int writes = 0;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Collection(this, path);

  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    if (failure != null) throw failure!;
    return transactionHandler(_Transaction(this));
  }
}

// ignore: subtype_of_sealed_class
class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  _Collection(this.database, this.path);
  final _Database database;
  @override
  final String path;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) {
    database.path = '$path/$id';
    return _Document(database);
  }
}

// ignore: subtype_of_sealed_class
class _Document extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _Document(this.database);
  final _Database database;

  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) => database.failure != null
      ? Stream.error(database.failure!)
      : Stream.value(_Snapshot(database.data));

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async {
    database.options = options;
    if (database.failure != null) throw database.failure!;
    return _Snapshot(database.data);
  }
}

// ignore: subtype_of_sealed_class
class _Snapshot extends Fake implements DocumentSnapshot<Map<String, dynamic>> {
  _Snapshot(this.value);
  final Map<String, dynamic>? value;

  @override
  Map<String, dynamic>? data() => value;
}

class _Transaction extends Fake implements Transaction {
  _Transaction(this.database);
  final _Database database;

  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
    DocumentReference<T> reference,
  ) => reference.get();

  @override
  Transaction set<T>(
    DocumentReference<T> documentReference,
    T data, [
    SetOptions? options,
  ]) {
    database.writes++;
    database.data = data as Map<String, dynamic>;
    return this;
  }
}

void main() {
  test('watches categories on the selected driver document', () async {
    final database = _Database()
      ..data = {
        'name': 'Jean',
        'phone': '+33612345678',
        'car': 'Mercedes',
        'categories': ['Berline', 'Van'],
      };
    final service = DriverProfileService(firestore: database);
    expect((await service.watchDriver('driver-1').first)!.categories, [
      'Berline',
      'Van',
    ]);
    expect(database.path, 'Drivers/driver-1');
    database.data = null;
    expect(await service.watchDriver('driver-1').first, isNull);
    database.failure = FirebaseException(
      plugin: 'cloud_firestore',
      code: 'permission-denied',
    );
    await expectLater(
      service.watchDriver('driver-1'),
      emitsError(isA<FirebaseException>()),
    );
  });

  test(
    'reads own profile from server and serializes precisely MyDriver fields',
    () async {
      final database = _Database();
      final service = DriverProfileService(firestore: database);
      expect(await service.getDriver('driver-1'), isNull);
      expect(database.options!.source, Source.server);
      final driver = await service.createProfile(
        'driver-1',
        name: ' Jean ',
        phone: '+33 6 12 34 56 78',
        car: ' Mercedes ',
        licensePlate: ' ab-123-cd ',
      );
      expect(database.path, 'Drivers/driver-1');
      expect(database.data, {
        'name': 'Jean',
        'phone': '+33612345678',
        'categories': ['eco'],
        'car': 'Mercedes',
        'available': true,
        'licensePlate': 'AB-123-CD',
      });
      expect(driver.categories, ['eco']);
      expect(driver.licensePlate, 'AB-123-CD');
      expect((await service.getDriver('driver-1'))!.name, 'Jean');
    },
  );

  test(
    'transaction preserves concurrently created profile and admin fields',
    () async {
      final database = _Database()
        ..data = {
          'name': 'Existing',
          'phone': '+33612345678',
          'car': 'Van',
          'categories': ['VIP'],
          'remindersEnabled': true,
        };
      final service = DriverProfileService(firestore: database);
      final driver = await service.createProfile(
        'driver-1',
        name: 'Jean',
        phone: '+33612345678',
        car: 'Mercedes',
        licensePlate: 'AB-123-CD',
      );
      expect(database.writes, 0);
      expect(driver.categories, ['VIP']);
      expect(database.data!['remindersEnabled'], isTrue);
      expect(database.data!['name'], 'Existing');
      expect(driver.licensePlate, isEmpty);
    },
  );

  test(
    'invalid input does not write and Firestore failures propagate',
    () async {
      final database = _Database();
      final service = DriverProfileService(firestore: database);
      for (final uid in ['', 'bad/id']) {
        await expectLater(service.getDriver(uid), throwsArgumentError);
      }
      for (final values in [
        ('', '+33612345678', 'Mercedes'),
        ('Jean', '0612345678', 'Mercedes'),
        ('Jean', '+33612345678', ''),
      ]) {
        await expectLater(
          service.createProfile(
            'driver-1',
            name: values.$1,
            phone: values.$2,
            car: values.$3,
            licensePlate: 'AB-123-CD',
          ),
          throwsArgumentError,
        );
      }
      expect(database.writes, 0);
      await expectLater(
        service.createProfile(
          'driver-1',
          name: 'Jean',
          phone: '+33612345678',
          car: 'Mercedes',
          licensePlate: ' ',
        ),
        throwsArgumentError,
      );
      database.failure = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
      );
      await expectLater(
        service.getDriver('driver-1'),
        throwsA(isA<FirebaseException>()),
      );
      await expectLater(
        service.createProfile(
          'driver-1',
          name: 'Jean',
          phone: '+33612345678',
          car: 'Mercedes',
          licensePlate: 'AB-123-CD',
        ),
        throwsA(isA<FirebaseException>()),
      );
      expect(database.writes, 0);
    },
  );
}
