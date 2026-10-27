import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

// ignore: subtype_of_sealed_class
class _MockDocumentSnapshot extends Fake
    implements DocumentSnapshot<Map<String, dynamic>> {
  _MockDocumentSnapshot(this.docId, this.dataMap);

  final String docId;
  final Map<String, dynamic>? dataMap;

  @override
  String get id => docId;

  @override
  Map<String, dynamic>? data() => dataMap;
}

void main() {
  group('OrderStatus.fromString', () {
    test('parses exact enum string representation', () {
      expect(
        OrderStatus.fromString('OrderStatus.ASSIGNED'),
        OrderStatus.ASSIGNED,
      );
      expect(
        OrderStatus.fromString('OrderStatus.EN_ROUTE'),
        OrderStatus.EN_ROUTE,
      );
    });

    test('parses plain enum name case-insensitively', () {
      expect(OrderStatus.fromString('ASSIGNED'), OrderStatus.ASSIGNED);
      expect(OrderStatus.fromString('assigned'), OrderStatus.ASSIGNED);
      expect(OrderStatus.fromString('en_route'), OrderStatus.EN_ROUTE);
      expect(OrderStatus.fromString('COMPLETED'), OrderStatus.COMPLETED);
    });

    test('returns fallback for unknown or null values without throwing', () {
      expect(OrderStatus.fromString(null), OrderStatus.PENDING_ASSIGNMENT);
      expect(
        OrderStatus.fromString('UNKNOWN_STATUS'),
        OrderStatus.PENDING_ASSIGNMENT,
      );
      expect(OrderStatus.fromString(''), OrderStatus.PENDING_ASSIGNMENT);
      expect(
        OrderStatus.fromString('something', OrderStatus.CANCELLED),
        OrderStatus.CANCELLED,
      );
    });
  });

  group('PaymentStatus.fromString', () {
    test('parses exact enum string representation', () {
      expect(
        PaymentStatus.fromString('PaymentStatus.confirmed'),
        PaymentStatus.confirmed,
      );
      expect(
        PaymentStatus.fromString('PaymentStatus.pending'),
        PaymentStatus.pending,
      );
    });

    test('parses plain enum name case-insensitively', () {
      expect(PaymentStatus.fromString('confirmed'), PaymentStatus.confirmed);
      expect(PaymentStatus.fromString('PENDING'), PaymentStatus.pending);
      expect(PaymentStatus.fromString('cart'), PaymentStatus.cart);
      expect(PaymentStatus.fromString('cancelled'), PaymentStatus.cancelled);
    });

    test('returns fallback for unknown or null values without throwing', () {
      expect(PaymentStatus.fromString(null), PaymentStatus.pending);
      expect(PaymentStatus.fromString('unknown_status'), PaymentStatus.pending);
      expect(PaymentStatus.fromString(''), PaymentStatus.pending);
      expect(
        PaymentStatus.fromString('foo', PaymentStatus.confirmed),
        PaymentStatus.confirmed,
      );
    });
  });

  group('GPSCoordinates.fromJson', () {
    test('parses integer coordinates safely without type errors', () {
      final coords = GPSCoordinates.fromJson({'latitude': 48, 'longitude': 2});
      expect(coords.latitude, 48.0);
      expect(coords.longitude, 2.0);
    });

    test('handles missing or null coordinates safely', () {
      final coords = GPSCoordinates.fromJson({});
      expect(coords.latitude, 0.0);
      expect(coords.longitude, 0.0);
    });
  });

  group('CommandStatus deserialization', () {
    test('fromJson handles different status and date formats safely', () {
      final status = CommandStatus.fromJson({
        'date': '2026-10-12T10:00:00.000Z',
        'status': 'ASSIGNED',
        'id': 'driver-1',
        'location': {'latitude': 48.85, 'longitude': 2.35},
      });
      expect(status.status, OrderStatus.ASSIGNED);
      expect(status.id, 'driver-1');
      expect(status.location.latitude, 48.85);
    });

    test(
      'fromFirestore handles Timestamp, null values, and unknown status',
      () {
        final status = CommandStatus.fromFirestore({
          'date': Timestamp.fromDate(DateTime(2026, 10, 12, 10)),
          'status': 'non_existent_status',
          'id': 'driver-2',
          'location': null,
        });
        expect(status.status, OrderStatus.PENDING_ASSIGNMENT);
        expect(status.id, 'driver-2');
        expect(status.location.latitude, 0.0);
        expect(status.location.longitude, 0.0);
      },
    );
  });

  group('MyOrder deserialization', () {
    test('fromFirestore parses complete and partial documents safely', () {
      final snapshot = _MockDocumentSnapshot('order-42', {
        'userId': 'user-1',
        'departureDate': Timestamp.fromDate(DateTime(2026, 10, 12)),
        'customerEmail': 'client@test.com',
        'category': 'VIP',
        'disposal': false,
        'clients': [
          {'name': 'Jean Dupont', 'phone': '+33612345678'},
        ],
        'precision': 'Porte A',
        'departureAddress': 'Aéroport CDG',
        'steps': ['Hôtel Paris'],
        'personNumber': 2,
        'suitcaseNumber': 3,
        'commandStatus': [
          {
            'date': '2026-10-12T10:00:00.000Z',
            'status': 'ASSIGNED',
            'id': 'driver-7',
            'location': {'latitude': 48.85, 'longitude': 2.35},
          },
        ],
        'vehicule': 'Mercedes Classe E',
        'paymentStatus': 'confirmed',
      });

      final order = MyOrder.fromFirestore(snapshot);
      expect(order.id, 'order-42');
      expect(order.paymentStatus, PaymentStatus.confirmed);
      expect(order.commandStatus.length, 1);
      expect(order.commandStatus.first.status, OrderStatus.ASSIGNED);
      expect(order.commandStatus.first.id, 'driver-7');
      expect(order.clients.first.name, 'Jean Dupont');
    });

    test('fromFirestore handles missing/null paymentStatus and empty commandStatus without error', () {
      final snapshot = _MockDocumentSnapshot('order-empty', {
        'userId': 'user-2',
      });

      final order = MyOrder.fromFirestore(snapshot);
      expect(order.id, 'order-empty');
      expect(order.paymentStatus, PaymentStatus.pending);
      expect(order.commandStatus, isEmpty);
      expect(order.clients, isEmpty);
      expect(order.steps, isEmpty);
    });

    test('fromJson handles standard json payload', () {
      final order = MyOrder.fromJson({
        'id': 'json-order-1',
        'userId': 'user-3',
        'departureDate': '2026-10-12T10:00:00.000Z',
        'paymentStatus': 'PaymentStatus.cart',
        'commandStatus': <dynamic>[],
      });
      expect(order.id, 'json-order-1');
      expect(order.paymentStatus, PaymentStatus.cart);
      expect(order.commandStatus, isEmpty);
    });
  });
}
