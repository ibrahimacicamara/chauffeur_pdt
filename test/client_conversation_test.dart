import 'dart:async';

import 'package:chauffeur/screens/client_conversation_page.dart';
import 'package:chauffeur/services/client_conversation_audio.dart';
import 'package:chauffeur/services/client_conversation_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

class _Speech extends Fake implements SpeechToText {
  SpeechResultListener? result;
  SpeechListenOptions? options;
  bool available = true;
  int cancelled = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #initialize: return Future<bool>.value(available);
      case #locales: return Future.value([LocaleName('fr_FR', 'Français')]);
      case #listen:
        result = invocation.namedArguments[#onResult] as SpeechResultListener?;
        options = invocation.namedArguments[#listenOptions] as SpeechListenOptions?;
        return Future<void>.value();
      case #cancel: cancelled++; return Future<void>.value();
      case #stop: return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class _Service extends ClientConversationService {
  final clients = StreamController<ConversationClient?>.broadcast();
  final messages = StreamController<List<ConversationMessage>>.broadcast();
  final sent = <String>[];
  final translations = <String>[];
  var ids = 0;
  var failSend = false;

  @override
  Stream<ConversationClient?> watchClient(String driverId) => clients.stream;
  @override
  Stream<List<ConversationMessage>> watchMessages(
    String driverId,
    String sessionId,
  ) => messages.stream;
  @override
  Future<void> refresh() async {}
  @override
  String newMessageId() => 'message-${++ids}';
  @override
  Future<void> send(String sessionId, String messageId, String text) async {
    sent.add('$sessionId:$messageId:$text');
    if (failSend) throw StateError('Connexion interrompue');
  }

  @override
  Future<void> saveTranslation(
    String sessionId,
    String messageId,
    String text,
  ) async {
    translations.add('$sessionId:$messageId:$text');
  }
}

class _Audio extends ClientConversationAudio {
  final spoken = <String>[];
  Completer<void>? pending;
  var stops = 0;
  @override
  Future<void> speak(String text, {required bool Function() isActive}) async {
    if (pending != null) await pending!.future;
    if (isActive()) spoken.add(text);
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> close() async {}
}

const client = ConversationClient(
  sessionId: 'session',
  name: 'Alice',
  language: 'en',
  orderId: 'course',
);

ConversationMessage message(
  String id, {
  String role = 'client',
  String? translation,
}) => ConversationMessage(
  id: id,
  role: role,
  text: 'Hello',
  source: 'en',
  target: 'fr',
  createdAt: DateTime.now(),
  translation: translation,
);

void main() {
  Future<(_Service, _Audio)> open(
    WidgetTester tester, {
    String? orderId,
    _Speech? speech,
  }) async {
    final service = _Service();
    final audio = _Audio();
    addTearDown(service.clients.close);
    addTearDown(service.messages.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ClientConversationPage(
          driverId: 'driver',
          orderId: orderId,
          service: service,
          audio: audio,
          speech: speech ?? _Speech(),
        ),
      ),
    );
    await tester.pump();
    service.clients.add(client);
    await tester.pumpAndSettle();
    service.messages.add([]);
    await tester.pumpAndSettle();
    return (service, audio);
  }

  testWidgets('Shows client and sends reply with stable ID on retry', (
    tester,
  ) async {
    final (service, _) = await open(tester);
    expect(find.text('Alice'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('conversation-input')),
      'Bien sûr',
    );
    service.failSend = true;
    await tester.tap(find.byKey(const ValueKey('conversation-send')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connexion interrompue'), findsOneWidget);
    service.failSend = false;
    await tester.tap(find.byKey(const ValueKey('conversation-send')));
    await tester.pumpAndSettle();
    expect(service.sent, [
      'session:message-1:Bien sûr',
      'session:message-1:Bien sûr',
    ]);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('French dictation preserves draft and requires review before sending', (tester) async {
    final speech = _Speech();
    final (service, _) = await open(tester, speech: speech);
    await tester.enterText(find.byType(TextField), 'Bonjour');
    await tester.tap(find.byKey(const ValueKey('conversation-dictate')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activer'));
    await tester.pumpAndSettle();
    expect(speech.options!.localeId, 'fr_FR');
    expect(speech.options!.onDevice, isFalse);
    speech.result!(SpeechRecognitionResult.init([
      SpeechRecognitionWords('nous arrivons', null, 1),
    ], ResultType.finalResult));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Bonjour nous arrivons');
    expect(service.sent, isEmpty);
    await tester.tap(find.byKey(const ValueKey('conversation-send')));
    await tester.pumpAndSettle();
    expect(service.sent.single, 'session:message-1:Bonjour nous arrivons');
    expect(speech.cancelled, greaterThan(0));
  });

  testWidgets('Dictation permissions fail explicitly; session changes ignore late results', (tester) async {
    final speech = _Speech()..available = false;
    final (service, _) = await open(tester, speech: speech);
    await tester.tap(find.byKey(const ValueKey('conversation-dictate')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Autorisez le microphone'), findsOneWidget);
    speech.available = true;
    await tester.tap(find.byKey(const ValueKey('conversation-dictate')));
    await tester.pumpAndSettle();
    final result = speech.result!;
    service.clients.add(null);
    await tester.pumpAndSettle();
    result(SpeechRecognitionResult.init([SpeechRecognitionWords('ancien client', null, 1)], ResultType.finalResult));
    await tester.pumpAndSettle();
    expect(find.text('ancien client'), findsNothing);
    expect(service.sent, isEmpty);
  });

  testWidgets('Discussion bubbles align driver right and client left', (tester) async {
    final (service, _) = await open(tester);
    service.messages.add([message('client', translation: 'Bonjour'), message('driver', role: 'driver')]);
    await tester.pumpAndSettle();
    expect(tester.widget<Align>(find.byKey(const ValueKey('message-bubble-client'))).alignment, Alignment.centerLeft);
    expect(tester.widget<Align>(find.byKey(const ValueKey('message-bubble-driver'))).alignment, Alignment.centerRight);
  });

  testWidgets(
    'Waits for tablet translation and reads once without translating locally',
    (tester) async {
      final (service, audio) = await open(tester);
      service.messages.add([message('new')]);
      await tester.pumpAndSettle();
      expect(service.translations, isEmpty);
      expect(audio.spoken, isEmpty);
      service.messages.add([
        message('new', translation: 'Bonjour'),
        message('own', role: 'driver'),
      ]);
      await tester.pumpAndSettle();
      expect(audio.spoken, ['Bonjour']);
      expect(service.translations, isEmpty);
      service.clients.add(null);
      await tester.pumpAndSettle();
      expect(find.text('Alice'), findsNothing);
      expect(find.text('Bonjour'), findsNothing);
      expect(find.text('Aucun client en cours.'), findsOneWidget);
    },
  );

  testWidgets('Initial history is not read; manual reading remains available', (
    tester,
  ) async {
    final service = _Service();
    final audio = _Audio();
    addTearDown(service.clients.close);
    addTearDown(service.messages.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ClientConversationPage(
          driverId: 'driver',
          service: service,
          audio: audio,
        ),
      ),
    );
    service.clients.add(client);
    await tester.pumpAndSettle();
    service.messages.add([message('history', translation: 'Bonjour')]);
    await tester.pumpAndSettle();
    expect(audio.spoken, isEmpty);
    await tester.tap(find.text('Lire'));
    await tester.pumpAndSettle();
    expect(audio.spoken, ['Bonjour']);
  });

  testWidgets('Backgrounding invalidates all queued speech', (
    tester,
  ) async {
    final (service, audio) = await open(tester);
    audio.pending = Completer<void>();
    service.messages.add([message('first', translation: 'Bonjour'), message('queued', translation: 'Bonjour')]);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    audio.pending!.complete();
    await tester.pumpAndSettle();
    expect(audio.spoken, isEmpty);
    expect(service.translations, isEmpty);
    expect(audio.stops, greaterThan(0));
  });

  testWidgets(
    'Changing client invalidates pending speech and clears draft and history',
    (tester) async {
      final (service, audio) = await open(tester);
      audio.pending = Completer<void>();
      service.messages.add([message('old', translation: 'Bonjour')]);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Ancien brouillon');
      service.clients.add(
        const ConversationClient(
          sessionId: 'other',
          name: 'Bob',
          language: 'fr',
          orderId: 'other-course',
        ),
      );
      await tester.pumpAndSettle();
      audio.pending!.complete();
      await tester.pumpAndSettle();
      expect(audio.spoken, isEmpty);
      expect(service.translations, isEmpty);
      expect(find.text('Alice'), findsNothing);
      expect(find.text('Bob'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    },
  );

  testWidgets('Course-specific entry never displays another course client', (
    tester,
  ) async {
    await open(tester, orderId: 'different-course');
    expect(find.text('Alice'), findsNothing);
    expect(find.text('Aucun client en cours.'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
