import 'package:chauffeur/screens/current_com.dart';
import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

class OrderPdfService {
  static String clean(String? text) {
    if (text == null) return '';
    return text
        .replaceAll('’', "'")
        .replaceAll('‘', "'")
        .replaceAll('“', '"')
        .replaceAll('”', '"')
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll('…', '...')
        .replaceAll('\u00A0', ' ')
        .replaceAll('\u202F', ' ');
  }

  static Future<Uint8List> generateOrderPdf(DriverOrder order) async {
    final logoData = await rootBundle.load(
      'assets/images/pro_du_transport.png',
    );
    final logo = pw.MemoryImage(logoData.buffer.asUint8List(
      logoData.offsetInBytes, logoData.lengthInBytes,
    ));
    final regular = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'),
    );
    final bold = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'),
    );
    final pdf = pw.Document(
      theme: pw.ThemeData.withFont(
        base: regular,
        bold: bold,
        italic: regular,
        boldItalic: bold,
      ),
    );

    final primaryColor = PdfColor.fromHex('#142536');
    final accentGold = PdfColor.fromHex('#D5B477');
    final textDark = PdfColor.fromHex('#1A202C');
    final textMuted = PdfColor.fromHex('#687787');
    final bgLight = PdfColor.fromHex('#F8FAFC');
    final borderColor = PdfColor.fromHex('#E2E8F0');

    final departureStr = order.departureDate != null
        ? clean(formatCourseDate(order.departureDate!))
        : 'Non renseignée';
    final nowStr = clean(formatCourseDate(DateTime.now()));

    pw.Widget sectionTitle(String title) {
      return pw.Container(
        margin: const pw.EdgeInsets.only(top: 14, bottom: 6),
        padding: const pw.EdgeInsets.only(bottom: 4),
        decoration: pw.BoxDecoration(
          border: pw.Border(
            bottom: pw.BorderSide(color: accentGold, width: 1.5),
          ),
        ),
        child: pw.Text(
          clean(title),
          style: pw.TextStyle(
            fontSize: 12,
            fontWeight: pw.FontWeight.bold,
            color: primaryColor,
          ),
        ),
      );
    }

    pw.Widget infoRow(String label, String value, {bool isHighlight = false}) {
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(
              width: 140,
              child: pw.Text(
                clean(label),
                style: pw.TextStyle(
                  fontSize: 10,
                  color: textMuted,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.Expanded(
              child: pw.Text(
                clean(value),
                style: pw.TextStyle(
                  fontSize: 10,
                  color: textDark,
                  fontWeight: isHighlight
                      ? pw.FontWeight.bold
                      : pw.FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      );
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 36, vertical: 32),
        header: (pw.Context context) {
          return pw.Container(
            padding: const pw.EdgeInsets.only(bottom: 12),
            margin: const pw.EdgeInsets.only(bottom: 12),
            decoration: pw.BoxDecoration(
              border: pw.Border(
                bottom: pw.BorderSide(color: borderColor, width: 1),
              ),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Padding(
                  padding: const pw.EdgeInsets.only(right: 12),
                  child: pw.Image(
                    logo,
                    width: 64,
                    height: 64,
                    fit: pw.BoxFit.contain,
                  ),
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'PRO DU TRANSPORT',
                      style: pw.TextStyle(
                        fontSize: 20,
                        fontWeight: pw.FontWeight.bold,
                        color: primaryColor,
                      ),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Service de Chauffeur VTC Privé',
                      style: pw.TextStyle(
                        fontSize: 9,
                        color: textMuted,
                        fontStyle: pw.FontStyle.italic,
                      ),
                    ),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Container(
                      padding: const pw.EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: pw.BoxDecoration(
                        color: primaryColor,
                        borderRadius: const pw.BorderRadius.all(
                          pw.Radius.circular(4),
                        ),
                      ),
                      child: pw.Text(
                        'BON DE COMMANDE',
                        style: pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 11,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      'Réf : ${clean(order.id)}',
                      style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                        color: textDark,
                      ),
                    ),
                    pw.Text(
                      'Émis le : $nowStr',
                      style: pw.TextStyle(fontSize: 8, color: textMuted),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
        footer: (pw.Context context) {
          return pw.Container(
            margin: const pw.EdgeInsets.only(top: 12),
            padding: const pw.EdgeInsets.only(top: 8),
            decoration: pw.BoxDecoration(
              border: pw.Border(
                top: pw.BorderSide(color: borderColor, width: 0.8),
              ),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Pro du Transport - Bon de commande de transport de personnes',
                  style: pw.TextStyle(fontSize: 8, color: textMuted),
                ),
                pw.Text(
                  'Page ${context.pageNumber} / ${context.pagesCount}',
                  style: pw.TextStyle(fontSize: 8, color: textMuted),
                ),
              ],
            ),
          );
        },
        build: (pw.Context context) {
          final isDisposal = order.disposal == true;
          final currentStatusLabel = clean(order.driverId != null
              ? order.currentStatus.label
              : (order.status ?? "En attente d'attribution"));

          return [
            // Status and Reference Banner
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                color: bgLight,
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
                border: pw.Border.all(color: borderColor),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'STATUT DE LA COURSE',
                        style: pw.TextStyle(
                          fontSize: 8,
                          color: textMuted,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.SizedBox(height: 2),
                      pw.Text(
                        clean(currentStatusLabel),
                        style: pw.TextStyle(
                          fontSize: 12,
                          fontWeight: pw.FontWeight.bold,
                          color: primaryColor,
                        ),
                      ),
                    ],
                  ),
                  if (order.driverId != null && order.driverId!.isNotEmpty)
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text(
                          'CHAUFFEUR ATTRIBUÉ',
                          style: pw.TextStyle(
                            fontSize: 8,
                            color: textMuted,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.SizedBox(height: 2),
                        pw.Text(
                          clean(order.driverId!),
                          style: pw.TextStyle(
                            fontSize: 10,
                            fontWeight: pw.FontWeight.bold,
                            color: textDark,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),

            // Trajet & Prise en charge
            sectionTitle('DÉTAILS DU TRAJET & PRISE EN CHARGE'),
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: borderColor),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  infoRow('Date & Heure de départ', departureStr,
                      isHighlight: true),
                  infoRow(
                    'Lieu de prise en charge',
                    order.departureAddress ?? 'Non renseigné',
                  ),
                  infoRow(
                    'Type de prestation',
                    isDisposal ? 'Mise à disposition' : 'Transfert direct',
                  ),
                  if (order.steps.isNotEmpty) ...[
                    pw.SizedBox(height: 4),
                    pw.Text(
                      'Destination(s) / Étapes :',
                      style: pw.TextStyle(
                        fontSize: 10,
                        color: textMuted,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    for (var i = 0; i < order.steps.length; i++)
                      pw.Padding(
                        padding: const pw.EdgeInsets.only(left: 12, top: 2),
                        child: pw.Text(
                          '${i + 1}. ${clean(order.steps[i])}',
                          style: pw.TextStyle(fontSize: 10, color: textDark),
                        ),
                      ),
                  ],
                  if (order.precision != null &&
                      order.precision!.trim().isNotEmpty) ...[
                    pw.SizedBox(height: 4),
                    infoRow('Instructions / Précision', order.precision!),
                  ],
                ],
              ),
            ),

            // Prestation & Véhicule
            sectionTitle('VÉHICULE & PASSAGERS'),
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: borderColor),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (order.vehicule != null)
                    infoRow('Véhicule demandé', order.vehicule!),
                  if (order.category != null)
                    infoRow('Catégorie', order.category!),
                  infoRow(
                    'Nombre de passagers',
                    order.personNumber != null
                        ? '${order.personNumber} passager(s)'
                        : '1 passager',
                  ),
                  infoRow(
                    'Nombre de bagages',
                    order.suitcaseNumber != null
                        ? '${order.suitcaseNumber} bagage(s)'
                        : '0 bagage',
                  ),
                ],
              ),
            ),

            // Client & Tarification
            sectionTitle('CLIENT & TARIFICATION'),
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: borderColor),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (order.clients.isNotEmpty)
                    for (final client in order.clients)
                      infoRow(
                        'Passager',
                        '${client.name} - Tél : ${client.phone}',
                      ),
                  if (order.customerEmail != null &&
                      order.customerEmail!.trim().isNotEmpty)
                    infoRow('Email client', order.customerEmail!),
                  if (order.price != null)
                    infoRow(
                      'Tarif TTC de la course',
                      '${order.price} €',
                      isHighlight: true,
                    ),
                  if (order.paymentStatus != null)
                    infoRow('Statut paiement', order.paymentStatus!),
                ],
              ),
            ),

            pw.SizedBox(height: 16),
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                color: bgLight,
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
              ),
              child: pw.Text(
                clean(
                  'Conditions générales : Le présent bon de commande confirme la prise en charge de la course par Pro du Transport. '
                  "Toute modification ou annulation doit être signalée au plus vite au service d'exploitation.",
                ),
                style: pw.TextStyle(fontSize: 7.5, color: textMuted),
                textAlign: pw.TextAlign.justify,
              ),
            ),
          ];
        },
      ),
    );

    return pdf.save();
  }

  static Future<void> downloadPdf(DriverOrder order) async {
    final bytes = await generateOrderPdf(order);
    await Printing.sharePdf(
      bytes: bytes,
      filename: 'bon_de_commande_${order.id}.pdf',
    );
  }

  static Future<void> previewOrPrintPdf(DriverOrder order) async {
    final bytes = await generateOrderPdf(order);
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: 'bon_de_commande_${order.id}',
    );
  }

  static void showDownloadModal({
    required BuildContext context,
    required DriverOrder order,
    Future<void> Function(BuildContext context, DriverOrder order)?
        customDownloader,
  }) {
    if (customDownloader != null) {
      customDownloader(context, order);
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (modalContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: 20,
              horizontal: 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.receipt_long_outlined,
                      color: Color(0xFF142536),
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Bon de commande',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF142536),
                            ),
                          ),
                          Text(
                            'Commande ${order.id}',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF687787),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFE2E7EC),
                    child: Icon(
                      Icons.file_download_outlined,
                      color: Color(0xFF142536),
                    ),
                  ),
                  title: const Text(
                    'Télécharger / Partager le PDF',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Enregistre ou partage le bon de commande sur votre appareil',
                    style: TextStyle(fontSize: 12),
                  ),
                  onTap: () async {
                    Navigator.of(modalContext).pop();
                    try {
                      await downloadPdf(order);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Erreur lors du téléchargement : $e'),
                          ),
                        );
                      }
                    }
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFE2E7EC),
                    child: Icon(
                      Icons.print_outlined,
                      color: Color(0xFF142536),
                    ),
                  ),
                  title: const Text(
                    'Aperçu & Impression',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Prévisualiser le document et l’imprimer',
                    style: TextStyle(fontSize: 12),
                  ),
                  onTap: () async {
                    Navigator.of(modalContext).pop();
                    try {
                      await previewOrPrintPdf(order);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Erreur lors de l’impression : $e'),
                          ),
                        );
                      }
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
