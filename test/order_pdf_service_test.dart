import 'dart:convert';
import 'dart:io';

import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:chauffeur/services/hive/hive_database.dart';
import 'package:chauffeur/services/order_pdf_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('OrderPdfService generates valid PDF bytes for an order', () async {
    final order = DriverOrder(
      id: 'TEST-123',
      departureAddress: '19 Avenue Crampel 31400 Toulouse',
      departureDate: DateTime(2026, 10, 12, 14, 30),
      steps: const ['Gare de Toulouse Matabiau', 'Aéroport Toulouse-Blagnac'],
      vehicule: 'Mercedes Classe V',
      personNumber: 3,
      suitcaseNumber: 2,
      precision: 'Client VIP',
      price: 125,
      driverId: 'driver-999',
      commandStatus: [
        CommandStatus(
          date: DateTime(2026, 10, 12, 11, 0),
          status: OrderStatus.PENDING_ASSIGNMENT,
          id: '',
          location: const GPSCoordinates(latitude: 0, longitude: 0),
        ),
        CommandStatus(
          date: DateTime(2026, 10, 12, 11, 5),
          status: OrderStatus.ASSIGNED,
          id: 'driver-999',
          location: const GPSCoordinates(latitude: 43.6047, longitude: 1.4442),
        ),
      ],
    );

    final pdfBytes = await OrderPdfService.generateOrderPdf(order);
    expect(pdfBytes, isNotEmpty);
    // PDF signature: %PDF-
    expect(pdfBytes.take(5).toList(), [0x25, 0x50, 0x44, 0x46, 0x2D]);
    final raw = latin1.decode(pdfBytes);
    expect(RegExp(r'/Subtype\s*/Image').hasMatch(raw), isTrue);
    expect(raw, contains('/FontFile2'));
    final streams = <String>[];
    for (final match in RegExp(
      r'<<(.*?)>>\s*stream\r?\n',
      dotAll: true,
    ).allMatches(raw)) {
      if (!match.group(1)!.contains('/FlateDecode')) continue;
      final lengthMatch =
          RegExp(r'/Length\s+(\d+)').firstMatch(match.group(1)!);
      if (lengthMatch == null) continue;
      final length = int.parse(lengthMatch.group(1)!);
      final decoded = ZLibDecoder().convert(
        pdfBytes.sublist(match.end, match.end + length),
      );
      streams.add(latin1.decode(decoded));
    }
    final content = streams.join('\n');
    expect(content.toLowerCase(), contains('20ac'));
    expect(content, isNot(contains('HISTORIQUE DU SUIVI')));
  });
}
