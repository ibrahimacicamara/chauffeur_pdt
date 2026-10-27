import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:flutter/material.dart';

class OnboardPaymentWarning extends StatelessWidget {
  const OnboardPaymentWarning({super.key, required this.order, this.compact = false});

  final DriverOrder order;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (!order.hasOnboardPayment) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: EdgeInsets.only(top: compact ? 8 : 16),
        padding: EdgeInsets.all(compact ? 10 : 16),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF4DF),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFD5B477)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, color: Color(0xFF805500)),
            SizedBox(width: compact ? 8 : 12),
            Expanded(
              child: const Text(
                'Attention: paiement à bord sur cette course',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF805500),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
