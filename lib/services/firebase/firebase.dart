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

/// Modes de paiement reconnus comme « paiement à bord » par l'administrateur
/// (contrat ADMIN_DRIVER_ACCOUNT_HANDOFF.md), après normalisation
/// minuscules/accents/séparateurs.
const Set<String> onboardPaymentMethods = {
  'a bord',
  'paiement a bord',
  'onboard',
  'on board',
  'cash on delivery',
};

String normalizePaymentMethod(String raw) {
  var value = raw.toLowerCase();
  const accents = {
    'à': 'a',
    'â': 'a',
    'ä': 'a',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'î': 'i',
    'ï': 'i',
    'ô': 'o',
    'ö': 'o',
    'ù': 'u',
    'û': 'u',
    'ü': 'u',
    'ç': 'c',
  };
  accents.forEach((accented, plain) {
    value = value.replaceAll(accented, plain);
  });
  return value.replaceAll(RegExp(r'[\s\-_./]+'), ' ').trim();
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
    this.driverPrice,
    this.customerEmail,
    this.category,
    this.disposal,
    this.paymentStatus,
    this.paymentMethod,
    this.paidOnlineCents,
    this.paymentPlan,
    this.validatedForDriverAt,
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

  /// Prix client, en euros.
  final num? price;

  /// Rémunération chauffeur stockée par l'administrateur, en euros.
  /// Ne jamais la recalculer avec le pourcentage courant.
  final num? driverPrice;
  final String? customerEmail;
  final String? category;
  final bool? disposal;
  final String? paymentStatus;

  /// Mode de paiement client (ex. « à bord », « onboard »).
  final String? paymentMethod;

  /// Montant payé en ligne, en centimes. Absent vaut zéro.
  final int? paidOnlineCents;

  /// Ancien marqueur local de paiement à bord, conservé pour les anciennes
  /// courses ; l'avertissement visuel le prend encore en compte.
  final String? paymentPlan;
  final DateTime? validatedForDriverAt;
  bool get isValidatedForDriver => validatedForDriverAt != null;

  /// Rémunération chauffeur en centimes, dérivée du prix stocké.
  int? get driverPriceCents {
    final value = driverPrice;
    return value == null || !value.isFinite ? null : (value * 100).round();
  }

  int? get priceCents {
    final value = price;
    return value == null || !value.isFinite ? null : (value * 100).round();
  }

  /// Paiement à bord au sens comptable du contrat administrateur.
  bool get isOnboardPaymentMethod {
    final method = paymentMethod;
    return method != null &&
        onboardPaymentMethods.contains(normalizePaymentMethod(method));
  }

  bool get hasOnboardPayment =>
      isOnboardPaymentMethod || paymentPlan == 'reservation_fee';
  final List<MyClient> clients;

  CommandStatus? get latestHistoryEvent {
    if (commandStatus.isEmpty) return null;
    var latest = commandStatus.first;
    for (final event in commandStatus.skip(1)) {
      if (!event.date.isBefore(latest.date)) latest = event;
    }
    return latest;
  }

  String? get driverId {
    final latest = latestHistoryEvent;
    if (latest == null) return _driverId;
    if (latest.status == OrderStatus.PENDING_ASSIGNMENT) return null;
    final assigned =
        commandStatus
            .where(
              (event) =>
                  event.status != OrderStatus.PENDING_ASSIGNMENT &&
                  event.id.trim().isNotEmpty,
            )
            .toList()
          ..sort((a, b) => a.date.compareTo(b.date));
    return assigned.isEmpty ? null : assigned.last.id.trim();
  }

  OrderStatus get currentStatus {
    final error = historyError;
    if (error != null) throw FormatException(error);
    final latest = latestHistoryEvent;
    if (latest != null) return latest.status;
    if (status != null) {
      final normalized = status!
          .toLowerCase()
          .replaceAll(RegExp(r'[àâä]'), 'a')
          .replaceAll(RegExp(r'[éèêë]'), 'e')
          .replaceAll(RegExp(r'[îï]'), 'i')
          .replaceAll(RegExp(r'[ôö]'), 'o')
          .replaceAll(RegExp(r'[ùûü]'), 'u')
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim();
      final legacyStatus = switch (normalized) {
        'en attente' || 'pending' => OrderStatus.PENDING_ASSIGNMENT,
        'acceptee' || 'accepted' => OrderStatus.ASSIGNED,
        'en route' || 'en cours' || 'in progress' => OrderStatus.EN_ROUTE,
        'sur place' => OrderStatus.ON_SITE,
        'client a bord' => OrderStatus.CLIENT_ON_BOARD,
        'terminee' || 'completed' => OrderStatus.COMPLETED,
        'annulee' || 'cancelled' || 'canceled' => OrderStatus.CANCELLED,
        'client absent' || 'no show' => OrderStatus.NO_SHOW,
        'interrompue' || 'interrupted' => OrderStatus.INTERRUPTED,
        _ => null,
      };
      if (legacyStatus != null) return legacyStatus;
      for (final value in OrderStatus.values) {
        if (value.name.toLowerCase() == normalized.replaceAll(' ', '_')) {
          return value;
        }
      }
      throw FormatException('Commande $id : statut courant invalide.');
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
      price: field<num>('price'),
      driverPrice: field<num>('driverPrice'),
      customerEmail: field<String>('customerEmail'),
      category: field<String>('category'),
      disposal: data['disposal'] is bool ? data['disposal'] as bool : null,
      paymentStatus: field<String>('paymentStatus'),
      paymentMethod: field<String>('paymentMethod'),
      paidOnlineCents: field<int>('paidOnlineCents'),
      paymentPlan: field<String>('paymentPlan'),
      validatedForDriverAt: data['validatedForDriverAt'] is Timestamp
          ? (data['validatedForDriverAt'] as Timestamp).toDate()
          : null,
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
    return _database
        .collection('Orders')
        .doc(orderId)
        .snapshots(includeMetadataChanges: true)
        .map((snapshot) {
          if (snapshot.metadata.isFromCache) {
            throw StateError(
              'Vérification serveur de la course impossible. Réessayez.',
            );
          }
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

  bool _categoryMatches(DriverOrder order, MyDriver driver) {
    final category = order.category?.trim().toLowerCase();
    return category != null &&
        category.isNotEmpty &&
        driver.categories.any(
          (allowed) => allowed.trim().toLowerCase() == category,
        );
  }

  bool _isClosed(OrderStatus status) => {
    OrderStatus.COMPLETED,
    OrderStatus.CANCELLED,
    OrderStatus.NO_SHOW,
    OrderStatus.INTERRUPTED,
  }.contains(status);

  /// Performs a server-only read before opening a direct link or acting on a
  /// course. An available course is accepted only while still unassigned and
  /// pending; an assigned course must still belong to this driver.
  Future<DriverOrder> getPublishedOrderForDriver(
    String orderId,
    String driverId, {
    bool allowAvailable = false,
    bool activeOnly = false,
  }) async {
    if (orderId.trim().isEmpty || orderId.contains('/')) {
      throw ArgumentError.value(orderId, 'orderId', 'Identifiant invalide');
    }
    final user = (auth ?? FirebaseAuth.instance).currentUser;
    if (user == null || user.uid != driverId) {
      throw StateError('Connectez-vous avec le compte chauffeur attendu.');
    }
    final profile =
        await (profileService ?? DriverProfileService(firestore: firestore))
            .getDriver(driverId);
    if (profile == null) {
      throw StateError('Votre profil chauffeur est introuvable.');
    }
    final snapshot = await _database
        .collection('Orders')
        .doc(orderId)
        .get(const GetOptions(source: Source.server));
    final data = snapshot.data();
    if (data == null) throw StateError('Cette course n’existe plus.');
    final order = DriverOrder.fromFirestore(snapshot.id, data);
    if (!order.isValidatedForDriver) {
      throw StateError('Cette course n’est pas validée pour les chauffeurs.');
    }
    if (!_categoryMatches(order, profile)) {
      throw StateError('Cette course ne correspond pas à vos catégories.');
    }
    final status = order.currentStatus;
    final isAssignedToDriver = order.driverId == driverId;
    final isAvailable =
        order.driverId == null && status == OrderStatus.PENDING_ASSIGNMENT;
    if ((!isAssignedToDriver && !(allowAvailable && isAvailable)) ||
        (activeOnly && (isAvailable || _isClosed(status)))) {
      throw StateError('Cette course n’est plus disponible pour vous.');
    }
    return order;
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
    final driverProfile =
        await (profileService ?? DriverProfileService(firestore: firestore))
            .getDriver(user.uid);
    if (driverProfile == null) {
      throw StateError('Votre profil chauffeur est introuvable.');
    }
    await _database.runTransaction((transaction) async {
      final snapshot = await transaction.get(reference);
      final data = snapshot.data();
      if (data == null) throw StateError('Cette commande n’existe plus.');
      final order = DriverOrder.fromFirestore(orderId, data);
      if (order.historyError != null) {
        throw FormatException(order.historyError!);
      }
      if (!order.isValidatedForDriver) {
        throw StateError(
          'Cette course n’est plus validée pour les chauffeurs.',
        );
      }
      if (!_categoryMatches(order, driverProfile)) {
        throw StateError('Cette course ne correspond plus à vos catégories.');
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
    final driverProfile =
        await (profileService ?? DriverProfileService(firestore: firestore))
            .getDriver(user.uid);
    if (driverProfile == null) {
      throw StateError('Votre profil chauffeur est introuvable.');
    }
    await _database.runTransaction((transaction) async {
      final snapshot = await transaction.get(reference);
      final data = snapshot.data();
      if (data == null) throw StateError('Cette commande n’existe plus.');
      final order = DriverOrder.fromFirestore(orderId, data);
      if (!order.isValidatedForDriver) {
        throw StateError(
          'Cette course n’est plus validée pour les chauffeurs.',
        );
      }
      if (!_categoryMatches(order, driverProfile)) {
        throw StateError('Cette course ne correspond plus à vos catégories.');
      }
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
          final eligible = <DriverOrder>[];
          for (final order in current) {
            if (!order.isValidatedForDriver ||
                !allowed.contains(order.category?.trim().toLowerCase())) {
              continue;
            }
            if (order.historyError != null) {
              controller.addError(FormatException(order.historyError!));
              continue;
            }
            try {
              final status = order.currentStatus;
              if (order.driverId == driverId ||
                  (order.driverId == null &&
                      status == OrderStatus.PENDING_ASSIGNMENT)) {
                eligible.add(order);
              }
            } on FormatException catch (error, stackTrace) {
              controller.addError(error, stackTrace);
            }
          }
          controller.add(eligible);
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
        .snapshots(includeMetadataChanges: true)
        .map((snapshot) {
          if (snapshot.metadata.isFromCache) {
            throw StateError(
              'Vérification serveur des courses impossible. Réessayez.',
            );
          }
          return snapshot.docs.map((doc) {
            try {
              return DriverOrder.fromFirestore(doc.id, doc.data());
            } catch (e) {
              return DriverOrder(
                id: doc.id,
                historyError: e is FormatException ? e.message : e.toString(),
              );
            }
          }).toList();
        });
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
    final driverProfile =
        await (profileService ?? DriverProfileService(firestore: firestore))
            .getDriver(user.uid);
    if (driverProfile == null) {
      throw StateError('Votre profil chauffeur est introuvable.');
    }
    await _database.runTransaction((transaction) async {
      final snapshot = await transaction.get(reference);
      final data = snapshot.data();
      if (data == null) {
        throw StateError('Cette commande n’existe plus.');
      }
      final order = DriverOrder.fromFirestore(orderId, data);
      if (!order.isValidatedForDriver) {
        throw StateError(
          'Cette course n’est plus validée pour les chauffeurs.',
        );
      }
      if (!_categoryMatches(order, driverProfile)) {
        throw StateError('Cette course ne correspond pas à vos catégories.');
      }
      final assignedDriverId = order.driverId;
      if (assignedDriverId == user.uid) return;
      if (assignedDriverId != null && assignedDriverId.isNotEmpty) {
        throw StateError('Cette commande a déjà été choisie par un chauffeur.');
      }
      if (order.currentStatus != OrderStatus.PENDING_ASSIGNMENT) {
        throw StateError('Cette course n’est plus disponible.');
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
