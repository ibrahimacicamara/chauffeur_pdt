import 'package:chauffeur/services/firebase/firebase.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String? firstClientName(DriverOrder order) {
  for (final client in order.clients) {
    final name = client.name.trim();
    if (name.isNotEmpty) return name;
  }
  return null;
}

/// Pancarte plein écran présentée au client lors de la prise en charge.
class ClientNameBoardPage extends StatefulWidget {
  const ClientNameBoardPage({super.key, required this.name});

  final String name;

  static Future<void> open(BuildContext context, String name) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => ClientNameBoardPage(name: name),
        ),
      );

  @override
  State<ClientNameBoardPage> createState() => _ClientNameBoardPageState();
}

class _ClientNameBoardPageState extends State<ClientNameBoardPage> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.white,
    body: SafeArea(
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 56, 24, 100),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: Text(
                    widget.name.toUpperCase(),
                    key: const ValueKey('client-name-board-text'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 200,
                      fontWeight: FontWeight.w900,
                      color: Colors.black,
                      height: 1.1,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 20,
            bottom: 16,
            child: Image.asset(
              'assets/images/pro_du_transport.png',
              key: const ValueKey('client-name-board-logo'),
              width: 100,
              height: 68,
              fit: BoxFit.contain,
              semanticLabel: 'Pro du Transport',
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              key: const ValueKey('client-name-board-close'),
              tooltip: 'Fermer la pancarte',
              iconSize: 32,
              color: Colors.black54,
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
        ],
      ),
    ),
  );
}
