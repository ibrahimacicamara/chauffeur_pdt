import 'package:flutter_tts/flutter_tts.dart';

class ClientConversationAudio {
  final _tts = FlutterTts();

  Future<void> speak(String text, {required bool Function() isActive}) async {
    if (await _tts.isLanguageAvailable('fr-FR') != true) {
      throw StateError('Installez une voix française dans les réglages de synthèse vocale.');
    }
    if (!isActive()) return;
    if (await _tts.setLanguage('fr-FR') != 1) {
      throw StateError('Voix française indisponible.');
    }
    await _tts.awaitSpeakCompletion(true);
    if (!isActive()) return;
    if (await _tts.speak(text) != 1) throw StateError('Lecture vocale impossible.');
  }

  Future<void> stop() async { await _tts.stop(); }
  Future<void> close() => stop();
}
