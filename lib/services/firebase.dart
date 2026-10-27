import 'dart:async';

import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class FireService {
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

  // static Stream<List<MyCart>> getCommandStream() {
  //   try {
  //     return FirebaseFirestore.instance
  //         .collection('Commandes')
  //         .snapshots()
  //         .map(
  //           (snapshot) =>
  //               snapshot.docs.map((doc) => MyCart.fromFirestore(doc)).toList(),
  //         );
  //   } catch (e) {
  //     print("Error fetching commandes: $e");
  //     return Stream.empty(); // Return an empty stream on error
  //   }
  // }

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
