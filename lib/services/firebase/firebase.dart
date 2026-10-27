import 'dart:async';

import 'package:chauffeur/services/firebase/driver_profile_service.dart';
import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

extension DriverOrderStatus on OrderStatus {
  String get label => switch (this) {
    OrderStatus.PENDING_ASSIGNMENT => 'En attente d’attribution',
    OrderStatus.ASSIGNED => 'Attribuée',
    OrderStatus.EN_ROUTE => 'En route',
    OrderStatus.ON_SITE => 'Sur place',
    OrderStatus.CLIENT_ON_BOARD => 'Client à bord',
    OrderStatus.COMPLETED => 'Terminée',
    OrderStatus.CANCELLED => 'Annulée',
    OrderStatus.NO_SHOW => 'Client absent',
    OrderStatus.INTERRUPTED => 'Interrompue',
  };

  OrderStatus? get next => switch (this) {
    OrderStatus.ASSIGNED => OrderStatus.EN_ROUTE,
    OrderStatus.EN_ROUTE => OrderStatus.ON_SITE,
    OrderStatus.ON_SITE => OrderStatus.CLIENT_ON_BOARD,
    OrderStatus.CLIENT_ON_BOARD => OrderStatus.COMPLETED,
    _ => null,
  };
}

class DriverOrder {
  const DriverOrder({
    required this.id,
    this.departureAddress,
    this.departureDate,
    this.steps = const [],
    this.vehicule,
    this.personNumber,
    this.suitcaseNumber,
    this.precision,
    this.status,
    String? driverId,
    this.commandStatus = const [],
    this.historyError,
    this.price,
    this.customerEmail,
    this.category,
    this.disposal,
    this.paymentStatus,
    this.paymentPlan,
    this.checkoutAmountCents,
    this.clients = const [],
  }) : _driverId = driverId;

  final String id;
  final String? departureAddress;
  final DateTime? departureDate;
  final List<String> steps;
  final String? vehicule;
  final int? personNumber;
  final int? suitcaseNumber;
  final String? precision;
  final String? status;
  final String? _driverId;
  final List<CommandStatus> commandStatus;
  final String? historyError;
  final int? price;
  final String? customerEmail;
  final String? category;
  final bool? disposal;
  final String? paymentStatus;
  final String? paymentPlan;
  final int? checkoutAmountCents;

  bool get hasOnboardPayment => paymentPlan == 'reservation_fee';
  final List<MyClient> clients;

  String? get driverId {
    final reset = commandStatus.lastIndexWhere(
      (event) => event.status == OrderStatus.PENDING_ASSIGNMENT,
    );
    final activeHistory = commandStatus.skip(reset + 1);
    for (final item in activeHistory) {
      if (item.status == OrderStatus.ASSIGNED && item.id.trim().isNotEmpty) {
        return item.id.trim();
      }
    }
    for (final item in activeHistory) {
      if (item.id.trim().isNotEmpty) {
        return item.id.trim();
      }
    }
    return reset >= 0 ? null : _driverId;
  }

  OrderStatus get currentStatus {
    final error = historyError;
    if (error != null) throw FormatException(error);
    if (status == 'Terminée') return OrderStatus.COMPLETED;
    if (status == 'Annulée') return OrderStatus.CANCELLED;
    if (commandStatus.isNotEmpty &&
        commandStatus.last.status != OrderStatus.PENDING_ASSIGNMENT) {
      return commandStatus.last.status;
    }
    return driverId == null
        ? OrderStatus.PENDING_ASSIGNMENT
        : OrderStatus.ASSIGNED;
  }

  static List<CommandStatus> parseHistory(String id, Object? history) {
    if (history == null) return const [];
    if (history is! List) {
      throw FormatException('Commande $id : historique invalide.');
    }
    return history.map((entry) {
      if (entry is! Map) {
        throw FormatException('Commande $id : étape d’historique invalide.');
      }
      final date = entry['date'];
      final location = entry['location'];
      final rawStatus = entry['status'];
      final author = entry['id'];

      final statusStr = (rawStatus ?? '').toString();
      final normalizedStatus = statusStr
          .toUpperCase()
          .replaceAll('-', '_')
          .replaceAll(' ', '_');
      final matching = OrderStatus.values.where(
        (status) =>
            status.toString() == statusStr ||
            status.name == statusStr ||
            status.name == normalizedStatus ||
            status.name.toLowerCase() == statusStr.toLowerCase(),
      );

      DateTime? parsedDate;
      if (date is Timestamp) {
        parsedDate = date.toDate();
      } else if (date is DateTime) {
        parsedDate = date;
      } else if (date is String) {
        parsedDate = DateTime.tryParse(date);
      } else if (date is num) {
        parsedDate = DateTime.fromMillisecondsSinceEpoch(date.toInt());
      }

      if (parsedDate == null ||
          location is! Map ||
          matching.isEmpty ||
          author is! String) {
        throw FormatException('Commande $id : étape d’historique invalide.');
      }
      final latitude = location['latitude'];
      final longitude = location['longitude'];
      if (latitude is! num ||
          longitude is! num ||
          !latitude.isFinite ||
          !longitude.isFinite ||
          latitude < -90 ||
          latitude > 90 ||
          longitude < -180 ||
          longitude > 180) {
        throw FormatException('Commande $id : position GPS invalide.');
      }
      return CommandStatus(
        date: parsedDate,
        status: matching.first,
        id: author,
        location: GPSCoordinates(
          latitude: latitude.toDouble(),
          longitude: longitude.toDouble(),
        ),
      );
    }).toList();
  }

  factory DriverOrder.fromFirestore(String id, Map<String, dynamic> data) {
    T? field<T>(String name) {
      final value = data[name];
      if (value == null) return null;
      if (value is T) return value;
      throw FormatException('Commande $id : champ $name invalide.');
    }

    final rawSteps = field<List>('steps');
    if (rawSteps != null && rawSteps.any((step) => step is! String)) {
      throw FormatException('Commande $id : étapes invalides.');
    }
    final legacyDriverId = field<String>('driverId');
    if (legacyDriverId != null && legacyDriverId.trim().isEmpty) {
      throw FormatException('Commande $id : driverId invalide.');
    }
    List<CommandStatus> history = const [];
    String? historyError;
    try {
      history = parseHistory(id, data['commandStatus']);
    } on FormatException catch (error) {
      historyError = error.message;
    } catch (error) {
      historyError = error.toString();
    }

    DateTime? parseDepartureDate(Object? value) {
      if (value == null) return null;
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      if (value is String) {
        final parsed = DateTime.tryParse(value);
        if (parsed != null) return parsed;
      }
      throw FormatException('Commande $id : champ departureDate invalide.');
    }

    int? parseNumber(String name) {
      final value = data[name];
      if (value == null) return null;
      if (value is int) return value;
      if (value is num) return value.toInt();
      throw FormatException('Commande $id : champ $name invalide.');
    }

    List<MyClient> parseClients(Object? raw) {
      if (raw is! List) return const [];
      final list = <MyClient>[];
      for (final item in raw) {
        if (item is Map) {
          list.add(
            MyClient(
              name: (item['name'] ?? '').toString(),
              phone: (item['phone'] ?? '').toString(),
            ),
          );
        }
      }
      return list;
    }

    return DriverOrder(
      id: id,
      departureAddress: field<String>('departureAddress'),
      departureDate: parseDepartureDate(data['departureDate']),
      steps: rawSteps?.cast<String>() ?? const [],
      vehicule: field<String>('vehicule'),
      personNumber: parseNumber('personNumber'),
      suitcaseNumber: parseNumber('suitcaseNumber'),
      precision: field<String>('precision'),
      status: field<String>('status'),
      driverId: legacyDriverId,
      commandStatus: history,
      historyError: historyError,
      price: parseNumber('price'),
      customerEmail: field<String>('customerEmail'),
      category: field<String>('category'),
      disposal: data['disposal'] is bool ? data['disposal'] as bool : null,
      paymentStatus: field<String>('paymentStatus'),
      paymentPlan: field<String>('paymentPlan'),
      checkoutAmountCents: field<int>('checkoutAmountCents'),
      clients: parseClients(data['clients']),
    );
  }
}

class FireService {
  FireService({this.firestore, this.auth, this.profileService});

  final FirebaseFirestore? firestore;
  final FirebaseAuth? auth;
  final DriverProfileService? profileService;

  FirebaseFirestore get _database => firestore ?? FirebaseFirestore.instance;

  Stream<DriverOrder?> getOrderStream(String orderId) {
    return _database.collection('Orders').doc(orderId).snapshots().map((
      snapshot,
    ) {
      final data = snapshot.data();
      if (data == null) return null;
      try {
        return DriverOrder.fromFirestore(snapshot.id, data);
      } catch (e) {
        return DriverOrder(
          id: snapshot.id,
          historyError: e is FormatException ? e.message : e.toString(),
        );
      }
    });
  }

  Future<void> advanceOrderStatus({
    required String orderId,
    required OrderStatus expectedStatus,
    required OrderStatus nextStatus,
    required GPSCoordinates location,
  }) async {
    final user = (auth ?? FirebaseAuth.instance).currentUser;
    if (user == null) {
      throw StateError('Connectez-vous pour gérer votre commande.');
    }
    if (!location.latitude.isFinite ||
        !location.longitude.isFinite ||
        location.latitude < -90 ||
        location.latitude > 90 ||
        location.longitude < -180 ||
        location.longitude > 180) {
      throw StateError('La position GPS est invalide. Réessayez.');
    }
    final reference = _database.collection('Orders').doc(orderId);
    await _database.runTransaction((transaction) async {
      final snapshot = await transaction.get(reference);
      final data = snapshot.data();
      if (data == null) throw StateError('Cette commande n’existe plus.');
      final order = DriverOrder.fromFirestore(orderId, data);
      if (order.historyError != null) {
        throw FormatException(order.historyError!);
      }
      if (order.driverId != user.uid) {
        throw StateError('Cette commande ne vous est pas attribuée.');
      }
      if (order.currentStatus != expectedStatus) {
        throw StateError(
          'Le statut a changé. Consultez la mise à jour puis réessayez.',
        );
      }
      if (expectedStatus.next != nextStatus) {
        throw StateError('Ce changement de statut n’est pas autorisé.');
      }
      final event = CommandStatus(
        date: DateTime.now().toUtc(),
        status: nextStatus,
        id: user.uid,
        location: location,
      );
      transaction.update(reference, {
        'commandStatus': [
          ...?data['commandStatus'] as List?,
          CommandStatus.toFirestore(event),
        ],
        'commandStatusUpdatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<void> releaseOrder(
    String orderId, {
    required GPSCoordinates location,
  }) async {
    if (!location.latitude.isFinite ||
        !location.longitude.isFinite ||
        location.latitude.abs() > 90 ||
        location.longitude.abs() > 180) {
      throw StateError('Position GPS invalide.');
    }
    final user = (auth ?? FirebaseAuth.instance).currentUser;
    if (user == null) {
      throw StateError('Connectez-vous pour gérer votre commande.');
    }
    final reference = _database.collection('Orders').doc(orderId);
    await _database.runTransaction((transaction) async {
      final snapshot = await transaction.get(reference);
      final data = snapshot.data();
      if (data == null) throw StateError('Cette commande n’existe plus.');
      final order = DriverOrder.fromFirestore(orderId, data);
      if (order.driverId != user.uid) {
        throw StateError('Cette commande ne vous est plus attribuée.');
      }
      if (!{
        OrderStatus.ASSIGNED,
        OrderStatus.EN_ROUTE,
        OrderStatus.ON_SITE,
      }.contains(order.currentStatus)) {
        throw StateError(
          'Impossible de libérer une course après la prise en charge du client.',
        );
      }
      transaction.update(reference, {
        'driverId': FieldValue.delete(),
        'commandStatus': [
          ...?data['commandStatus'] as List?,
          CommandStatus.toFirestore(
            CommandStatus(
              date: DateTime.now().toUtc(),
              status: OrderStatus.PENDING_ASSIGNMENT,
              id: '',
              location: location,
            ),
          ),
        ],
        'commandStatusUpdatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Stream<List<DriverOrder>> getOrdersForDriverStream(String driverId) {
    final profiles =
        profileService ?? DriverProfileService(firestore: firestore);
    return Stream<List<DriverOrder>>.multi((controller) {
      Set<String>? categories;
      List<DriverOrder>? orders;

      void emit() {
        final allowed = categories;
        final current = orders;
        if (allowed == null) return;
        if (allowed.isEmpty) {
          controller.add([]);
        } else if (current != null) {
          controller.add(
            current
                .where(
                  (order) => allowed.contains(order.category?.toLowerCase()),
                )
                .toList(),
          );
        }
      }

      final profileSubscription = profiles
          .watchDriver(driverId)
          .listen(
            (driver) {
              if (driver == null) {
                categories = null;
                controller.addError(
                  StateError('Votre profil chauffeur est introuvable.'),
                );
                return;
              }
              categories = driver.categories
                  .where((value) => value.isNotEmpty)
                  .map((value) => value.toLowerCase())
                  .toSet();
              emit();
            },
            onError: (Object error, StackTrace stackTrace) {
              categories = null;
              controller.addError(error, stackTrace);
            },
          );
      final orderSubscription = getOrdersStream().listen(
        (value) {
          orders = value;
          emit();
        },
        onError: (Object error, StackTrace stackTrace) {
          orders = null;
          controller.addError(error, stackTrace);
        },
      );
      controller.onCancel = () async {
        await Future.wait([
          profileSubscription.cancel(),
          orderSubscription.cancel(),
        ]);
      };
    });
  }

  Stream<List<DriverOrder>> getOrdersStream() {
    return _database
        .collection('Orders')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs.map((doc) {
            try {
              return DriverOrder.fromFirestore(doc.id, doc.data());
            } catch (e) {
              return DriverOrder(
                id: doc.id,
                historyError: e is FormatException ? e.message : e.toString(),
              );
            }
          }).toList(),
        );
  }

  Future<void> chooseOrder(
    String orderId, {
    required GPSCoordinates location,
  }) async {
    final user = (auth ?? FirebaseAuth.instance).currentUser;
    if (user == null) {
      throw StateError('Connectez-vous pour choisir une commande.');
    }
    if (!location.latitude.isFinite ||
        !location.longitude.isFinite ||
        location.latitude < -90 ||
        location.latitude > 90 ||
        location.longitude < -180 ||
        location.longitude > 180) {
      throw StateError('La position GPS est invalide. Réessayez.');
    }
    final reference = _database.collection('Orders').doc(orderId);
    await _database.runTransaction((transaction) async {
      final snapshot = await transaction.get(reference);
      final data = snapshot.data();
      if (data == null) {
        throw StateError('Cette commande n’existe plus.');
      }
      final order = DriverOrder.fromFirestore(orderId, data);
      final assignedDriverId = order.driverId;
      if (assignedDriverId == user.uid) return;
      if (assignedDriverId != null && assignedDriverId.isNotEmpty) {
        throw StateError('Cette commande a déjà été choisie par un chauffeur.');
      }
      final newStatus = CommandStatus(
        date: DateTime.now().toUtc(),
        status: OrderStatus.ASSIGNED,
        id: user.uid,
        location: location,
      );
      transaction.update(reference, {
        'commandStatus': [
          ...?data['commandStatus'] as List?,
          CommandStatus.toFirestore(newStatus),
        ],
        'commandStatusUpdatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  static Future<void> updateCourseDetails({
    required String orderId,
    required DateTime departureDate,
    required String departureAddress,
    required List<String> steps,
    required String customerEmail,
    required String category,
    required String vehicule,
    required int personNumber,
    required int suitcaseNumber,
    required String precision,
    required bool disposal,
  }) async {
    if (departureAddress.trim().isEmpty ||
        (!disposal && steps.isEmpty) ||
        personNumber < 1 ||
        suitcaseNumber < 0) {
      throw ArgumentError('Détails de course invalides.');
    }
    final ref = FirebaseFirestore.instance.collection('Orders').doc(orderId);
    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);
      final data = snapshot.data();
      if (data == null) throw StateError('Course introuvable.');
      if ((data['cartCheckoutId'] != null || data['stripeSessionId'] != null) &&
          data['status'] == 'pending') {
        throw StateError('Un paiement est en cours pour cette course.');
      }
      transaction.update(ref, {
        'departureDate': Timestamp.fromDate(departureDate),
        'departureAddress': departureAddress,
        'steps': steps,
        'customerEmail': customerEmail,
        'category': category,
        'vehicule': vehicule,
        'personNumber': personNumber,
        'suitcaseNumber': suitcaseNumber,
        'precision': precision,
        'disposal': disposal,
      });
    });
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> getDemoOrdersStream() {
    return FirebaseFirestore.instance
        .collection('Orders')
        .where('isDemo', isEqualTo: true)
        .snapshots();
  }

  static Future<void> updateOrderStatus({
    required String orderId,
    required String status,
  }) async {
    const allowedStatuses = {
      'En attente',
      'Acceptée',
      'En cours',
      'Terminée',
      'Annulée',
    };
    if (!allowedStatuses.contains(status)) {
      throw ArgumentError.value(status, 'status', 'Statut non autorisé');
    }

    final reference = FirebaseFirestore.instance
        .collection('Orders')
        .doc(orderId);
    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final snapshot = await transaction.get(reference);
      if (!snapshot.exists || snapshot.data()?['isDemo'] != true) {
        throw StateError('Cette commande de démonstration est introuvable.');
      }
      transaction.update(reference, {'status': status});
    });
  }

  static Future<void> deleteCourse(String orderId) async {
    final ref = FirebaseFirestore.instance.collection('Orders').doc(orderId);
    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);
      final data = snapshot.data();
      if (data == null) throw StateError('Course introuvable.');
      if (data['stripeSessionId'] != null || data['cartCheckoutId'] != null) {
        throw StateError(
          'Cette course est liée à un paiement. Annulez-la plutôt que de la supprimer.',
        );
      }
      transaction.delete(ref);
    });
  }

  static StreamSubscription<List<MyOrder>> listenToOrders({
    required void Function(List<MyOrder> data) onData,
    required void Function(Object error, StackTrace stackTrace) onError,
  }) {
    return FirebaseFirestore.instance
        .collection('Orders')
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs.map((doc) => MyOrder.fromFirestore(doc)).toList(),
        )
        .listen(onData, onError: onError);
  }
}
