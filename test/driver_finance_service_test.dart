import 'package:chauffeur/services/firebase/driver_finance.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

class _Database extends Fake implements FirebaseFirestore {
  final paths = <String>[];
  List<_PaymentDocument> payments = [];

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Collection(this, path);
}

// Firestore references and snapshots are replaced only in these unit tests.
// ignore: subtype_of_sealed_class
class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  _Collection(this.database, this.path);
  final _Database database;
  @override
  final String path;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) =>
      _Document(database, '$path/$id');

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) {
    database.paths.add(path);
    return Stream.value(_PaymentsSnapshot(database.payments));
  }
}

// ignore: subtype_of_sealed_class
class _Document extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _Document(this.database, this.path);
  final _Database database;
  @override
  final String path;

  @override
  CollectionReference<Map<String, dynamic>> collection(String name) =>
      _Collection(database, '$path/$name');
}

// ignore: subtype_of_sealed_class
class _PaymentDocument extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _PaymentDocument(this.id, this.value);
  @override
  final String id;
  final Map<String, dynamic> value;
  @override
  Map<String, dynamic> data() => value;
}

// ignore: subtype_of_sealed_class
class _PaymentsSnapshot extends Fake
    implements QuerySnapshot<Map<String, dynamic>> {
  _PaymentsSnapshot(this.docs);
  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}

void main() {
  test('reads only the Payments journal of the selected driver', () async {
    final database = _Database();
    final service = DriverFinanceService(firestore: database);
    expect(await service.watchPayments('driver-a').first, isEmpty);
    expect(database.paths, ['Drivers/driver-a/Payments']);
  });

  test('parses admin payments and sorts them newest first', () async {
    final database = _Database();
    final date = DateTime.utc(2026, 11, 7);
    Map<String, dynamic> payment(DateTime paymentDate) => {
      'method': 'transfer',
      'amountCents': 3003,
      'date': Timestamp.fromDate(paymentDate),
      'note': '',
      'administratorId': 'admin-1',
    };
    database.payments = [
      _PaymentDocument('old', payment(date.subtract(const Duration(days: 2)))),
      _PaymentDocument('z', payment(date)),
      _PaymentDocument('a', payment(date)),
    ];
    final service = DriverFinanceService(firestore: database);
    expect((await service.watchPayments('driver').first).map((p) => p.id), [
      'a',
      'z',
      'old',
    ]);
  });

  test(
    'malformed documents emit an error rather than partial financial totals',
    () async {
      final database = _Database()
        ..payments = [_PaymentDocument('invalid', {})];
      final service = DriverFinanceService(firestore: database);
      await expectLater(
        service.watchPayments('driver'),
        emitsError(isA<FormatException>()),
      );
    },
  );
}
