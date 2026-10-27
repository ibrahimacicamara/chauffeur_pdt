import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive/hive.dart';

part 'hive_database.g.dart';

DateTime _parseDate(dynamic raw) {
  if (raw is Timestamp) return raw.toDate();
  if (raw is DateTime) return raw;
  if (raw is String) return DateTime.tryParse(raw) ?? DateTime.now();
  return DateTime.now();
}

//Definie car models

@HiveType(typeId: 0)
class MyOrder {
  @HiveField(0)
  final String id;
  @HiveField(1)
  final String userId;
  @HiveField(2)
  final String customerEmail;
  @HiveField(3)
  final String category;
  @HiveField(4)
  final bool disposal;
  @HiveField(5)
  final DateTime departureDate;
  @HiveField(6)
  final List<MyClient> clients;
  @HiveField(7)
  final String departureAddress;
  @HiveField(8)
  final List<String> steps;
  @HiveField(9)
  final int personNumber;
  @HiveField(10)
  final int suitcaseNumber;
  @HiveField(11)
  final PaymentStatus paymentStatus;
  @HiveField(12)
  final String vehicule;
  @HiveField(13)
  final int? price;
  @HiveField(14)
  final List<String>? carImages;
  @HiveField(15)
  final String precision;
  @HiveField(16)
  final List<CommandStatus> commandStatus;

  MyOrder({
    required this.userId,
    required this.id,
    required this.departureDate,
    required this.customerEmail,
    required this.category,
    required this.disposal,
    required this.clients,
    required this.precision,
    required this.departureAddress,
    required this.steps,
    required this.personNumber,
    required this.suitcaseNumber,
    required this.paymentStatus,
    required this.vehicule,
    required this.commandStatus,
    this.price,
    this.carImages,
  });

  factory MyOrder.fromJson(Map<dynamic, dynamic> doc) {
    return MyOrder(
      userId: (doc['userId'] ?? '').toString(),
      id: (doc['id'] ?? '').toString(),
      departureDate: _parseDate(doc['departureDate']),
      customerEmail: (doc['customerEmail'] ?? '').toString(),
      category: (doc['category'] ?? '').toString(),
      disposal: doc['disposal'] as bool? ?? false,
      clients:
          (doc['clients'] as List<dynamic>?)
              ?.map((e) => MyClient.fromJson(e as Map<dynamic, dynamic>))
              .toList() ??
          const [],
      precision: (doc['precision'] ?? '').toString(),
      departureAddress: (doc['departureAddress'] ?? '').toString(),
      steps: doc['steps'] is List
          ? List<String>.from((doc['steps'] as List).map((e) => e.toString()))
          : const [],
      personNumber: (doc['personNumber'] as num?)?.toInt() ?? 0,
      suitcaseNumber: (doc['suitcaseNumber'] as num?)?.toInt() ?? 0,
      paymentStatus: PaymentStatus.fromString(doc['paymentStatus']),
      vehicule: (doc['vehicule'] ?? '').toString(),
      price: (doc['price'] as num?)?.toInt(),
      carImages: (doc['carImages'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList(),
      commandStatus:
          (doc['commandStatus'] as List<dynamic>?)
              ?.map((e) => CommandStatus.fromJson(e as Map<dynamic, dynamic>))
              .toList() ??
          const [],
    );
  }
  static Map<String, dynamic> toJson(MyOrder order) {
    return {
      'userId': order.userId,
      'id': order.id,
      'departureDate': order.departureDate,
      'customerEmail': order.customerEmail,
      'category': order.category,
      'disposal': order.disposal,
      'clients': order.clients.map((e) => MyClient.toJson(e)).toList(),
      'precision': order.precision,
      'departureAddress': order.departureAddress,
      'steps': order.steps,
      'personNumber': order.personNumber,
      'suitcaseNumber': order.suitcaseNumber,
      'commandStatus': order.commandStatus
          .map((e) => CommandStatus.toJson(e))
          .toList(),
      'vehicule': order.vehicule,
      'price': order.price,
      'carImages': order.carImages,
      'paymentStatus': order.paymentStatus.toString(),
    };
  }

  factory MyOrder.fromFirestore(DocumentSnapshot doc) {
    final data = (doc.data() as Map<String, dynamic>?) ?? {};
    return MyOrder(
      userId: (data['userId'] ?? '').toString(),
      id: (data['id'] ?? doc.id).toString(),
      departureDate: _parseDate(data['departureDate']),
      customerEmail: (data['customerEmail'] ?? '').toString(),
      category: (data['category'] ?? '').toString(),
      disposal: data['disposal'] as bool? ?? false,
      clients:
          (data['clients'] as List<dynamic>?)
              ?.map((e) => MyClient.fromJson(e as Map<dynamic, dynamic>))
              .toList() ??
          const [],
      precision: (data['precision'] ?? '').toString(),
      departureAddress: (data['departureAddress'] ?? '').toString(),
      steps: data['steps'] is List
          ? List<String>.from((data['steps'] as List).map((e) => e.toString()))
          : const [],
      personNumber: (data['personNumber'] as num?)?.toInt() ?? 0,
      suitcaseNumber: (data['suitcaseNumber'] as num?)?.toInt() ?? 0,
      commandStatus:
          (data['commandStatus'] as List<dynamic>?)
              ?.map((e) => CommandStatus.fromJson(e as Map<dynamic, dynamic>))
              .toList() ??
          const [],
      vehicule: (data['vehicule'] ?? '').toString(),
      price: (data['price'] as num?)?.toInt(),
      carImages: (data['carImages'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList(),
      paymentStatus: PaymentStatus.fromString(data['paymentStatus']),
    );
  }

  static Map<String, dynamic> toFirestore(MyOrder order) {
    return {
      'userId': order.userId,
      'id': order.id,
      'departureDate': order.departureDate,
      'customerEmail': order.customerEmail,
      'category': order.category,
      'disposal': order.disposal,
      'clients': order.clients.map((e) => MyClient.toJson(e)).toList(),
      'precision': order.precision,
      'departureAddress': order.departureAddress,
      'steps': order.steps,
      'personNumber': order.personNumber,
      'suitcaseNumber': order.suitcaseNumber,
      'commandStatus': order.commandStatus.map((e) => e.toString()).toList(),
      'vehicule': order.vehicule,
      'price': order.price,
      'carImages': order.carImages,
      'paymentStatus': order.paymentStatus.toString(),
    };
  }
}

enum PaymentStatus {
  cart,
  pending,
  confirmed,
  cancelled;

  static PaymentStatus fromString(
    dynamic raw, [
    PaymentStatus fallback = PaymentStatus.pending,
  ]) {
    if (raw == null) return fallback;
    final str = raw.toString().trim().toLowerCase();
    for (final value in PaymentStatus.values) {
      final name = value.name.toLowerCase();
      if (str == name ||
          str == 'paymentstatus.$name' ||
          str == value.toString().toLowerCase()) {
        return value;
      }
    }
    return fallback;
  }
}

@HiveType(typeId: 1)
class CommandStatus {
  @HiveField(0)
  final DateTime date;
  @HiveField(1)
  final OrderStatus status;
  @HiveField(2)
  final String id;
  @HiveField(3)
  final GPSCoordinates location;

  CommandStatus({
    required this.date,
    required this.status,
    required this.id,
    required this.location,
  });

  static Map<String, dynamic> toJson(CommandStatus status) {
    return {
      'date': status.date.toIso8601String(),
      'status': status.status.toString(),
      'id': status.id,
      'location': GPSCoordinates.toJson(status.location),
    };
  }

  factory CommandStatus.fromJson(Map<dynamic, dynamic> doc) {
    return CommandStatus(
      date: _parseDate(doc['date']),
      status: OrderStatus.fromString(doc['status']),
      id: (doc['id'] ?? '').toString(),
      location: doc['location'] is Map<dynamic, dynamic>
          ? GPSCoordinates.fromJson(doc['location'] as Map<dynamic, dynamic>)
          : const GPSCoordinates(latitude: 0, longitude: 0),
    );
  }

  static Map<String, dynamic> toFirestore(CommandStatus status) {
    return {
      'date': status.date.toIso8601String(),
      'status': status.status.toString(),
      'id': status.id,
      'location': GPSCoordinates.toJson(status.location),
    };
  }

  factory CommandStatus.fromFirestore(Map<dynamic, dynamic> doc) {
    return CommandStatus(
      date: _parseDate(doc['date']),
      status: OrderStatus.fromString(doc['status']),
      id: (doc['id'] ?? '').toString(),
      location: doc['location'] is Map<dynamic, dynamic>
          ? GPSCoordinates.fromJson(doc['location'] as Map<dynamic, dynamic>)
          : const GPSCoordinates(latitude: 0, longitude: 0),
    );
  }
}

@HiveType(typeId: 2)
class GPSCoordinates {
  @HiveField(0)
  final double latitude;
  @HiveField(1)
  final double longitude;

  const GPSCoordinates({required this.latitude, required this.longitude});
  static Map<String, dynamic> toJson(GPSCoordinates coordinates) {
    return {
      'latitude': coordinates.latitude,
      'longitude': coordinates.longitude,
    };
  }

  factory GPSCoordinates.fromJson(Map<dynamic, dynamic> doc) {
    return GPSCoordinates(
      latitude: (doc['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (doc['longitude'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

@HiveType(typeId: 3)
class MyClient {
  @HiveField(0)
  final String name;
  @HiveField(1)
  final String phone;
  MyClient({required this.name, required this.phone});
  factory MyClient.fromJson(Map<dynamic, dynamic> doc) {
    return MyClient(
      name: (doc['name'] ?? '').toString(),
      phone: (doc['phone'] ?? '').toString(),
    );
  }

  static Map<String, dynamic> toJson(MyClient client) {
    return {'name': client.name, 'phone': client.phone};
  }
}

enum OrderStatus {
  PENDING_ASSIGNMENT,
  ASSIGNED,
  EN_ROUTE,
  ON_SITE,
  CLIENT_ON_BOARD,
  COMPLETED,
  CANCELLED,
  NO_SHOW,
  INTERRUPTED;

  static OrderStatus fromString(
    dynamic raw, [
    OrderStatus fallback = OrderStatus.PENDING_ASSIGNMENT,
  ]) {
    if (raw == null) return fallback;
    final str = raw.toString().trim().toLowerCase();
    for (final value in OrderStatus.values) {
      final name = value.name.toLowerCase();
      if (str == name ||
          str == 'orderstatus.$name' ||
          str == value.toString().toLowerCase()) {
        return value;
      }
    }
    return fallback;
  }
}

@HiveType(typeId: 4)
class MyDriver {
  @HiveField(0)
  final String name;
  @HiveField(1)
  final String phone;
  @HiveField(2)
  final List<String> categories;
  @HiveField(3)
  final String car;
  @HiveField(4)
  final bool available;
  @HiveField(5, defaultValue: '')
  final String licensePlate;

  MyDriver({
    required this.name,
    required this.phone,
    required this.categories,
    required this.car,
    required this.available,
    this.licensePlate = '',
  });

  factory MyDriver.fromJson(Map<dynamic, dynamic> doc) {
    return MyDriver(
      name: (doc['name'] ?? '').toString(),
      phone: (doc['phone'] ?? '').toString(),
      categories:
          (doc['categories'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      car: (doc['car'] ?? '').toString(),
      available: (doc['available'] as bool?) ?? false,
      licensePlate: (doc['licensePlate'] ?? '').toString(),
    );
  }
  static Map<String, dynamic> toJson(MyDriver driver) {
    return {
      'name': driver.name,
      'phone': driver.phone,
      'categories': driver.categories,
      'car': driver.car,
      'available': driver.available,
      'licensePlate': driver.licensePlate,
    };
  }
}
