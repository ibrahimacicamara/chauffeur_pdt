import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

const conversationLanguages = {
  'fr': 'Français',
  'en': 'English',
  'es': 'Español',
  'zh': '中文',
  'pt': 'Português',
  'ru': 'Русский',
  'ja': '日本語',
  'hi': 'हिन्दी',
};

class ConversationClient {
  const ConversationClient({
    required this.sessionId,
    required this.name,
    required this.language,
    this.orderId,
  });

  final String sessionId;
  final String name;
  final String language;
  final String? orderId;

  factory ConversationClient.fromMap(Map<String, dynamic> data) {
    if (data['sessionId'] is! String ||
        data['name'] is! String ||
        !conversationLanguages.containsKey(data['language']) ||
        (data['orderId'] != null && data['orderId'] is! String)) {
      throw const FormatException('Session client invalide.');
    }
    return ConversationClient(
      sessionId: data['sessionId'] as String,
      name: data['name'] as String,
      language: data['language'] as String,
      orderId: data['orderId'] as String?,
    );
  }
}

class ConversationMessage {
  const ConversationMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.source,
    required this.target,
    required this.createdAt,
    this.translation,
  });

  final String id;
  final String role;
  final String text;
  final String source;
  final String target;
  final DateTime createdAt;
  final String? translation;

  factory ConversationMessage.fromMap(String id, Map<String, dynamic> data) {
    if (!{'client', 'driver'}.contains(data['role']) ||
        data['text'] is! String ||
        !conversationLanguages.containsKey(data['source']) ||
        !conversationLanguages.containsKey(data['target']) ||
        data['createdAt'] is! Timestamp ||
        (data['translation'] != null && data['translation'] is! String)) {
      throw const FormatException('Message client invalide.');
    }
    return ConversationMessage(
      id: id,
      role: data['role'] as String,
      text: data['text'] as String,
      source: data['source'] as String,
      target: data['target'] as String,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      translation: data['translation'] as String?,
    );
  }
}

class ClientConversationService {
  ClientConversationService({this.firestore, this.functions});

  final FirebaseFirestore? firestore;
  final FirebaseFunctions? functions;
  FirebaseFirestore get _db => firestore ?? FirebaseFirestore.instance;

  Stream<ConversationClient?> watchClient(String driverId) =>
      _db.collection('Clients').doc(driverId)
        .snapshots(includeMetadataChanges: true)
        .where((snapshot) => !snapshot.metadata.isFromCache)
        .map((snapshot) {
          final current = snapshot.data()?['currentClient'];
          if (current == null) return null;
          if (current is! Map<String, dynamic>) {
            throw const FormatException('Session client invalide.');
          }
          return ConversationClient.fromMap(current);
        });

  Stream<List<ConversationMessage>> watchMessages(String driverId, String sessionId) =>
      _db.collection('Clients').doc(driverId).collection('sessions').doc(sessionId)
        .collection('messages').orderBy('createdAt', descending: true).limit(100)
        .snapshots(includeMetadataChanges: true)
        .where((snapshot) => !snapshot.metadata.isFromCache)
        .map((snapshot) => snapshot.docs.reversed.map(
          (doc) => ConversationMessage.fromMap(doc.id, doc.data()),
        ).toList());

  String newMessageId() => _db.collection('Clients').doc().id;

  Future<void> _call(String name, Map<String, dynamic> data) async {
    await (functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1'))
        .httpsCallable(name).call<void>(data);
  }

  Future<void> refresh() => _call('refreshCurrentClient', {});

  Future<void> send(String sessionId, String messageId, String text) =>
      _call('sendClientSessionMessage', {
        'sessionId': sessionId, 'messageId': messageId,
        'role': 'driver', 'text': text,
      });

  Future<void> saveTranslation(String sessionId, String messageId, String text) =>
      _call('saveClientMessageTranslation', {
        'sessionId': sessionId, 'messageId': messageId, 'translation': text,
      });
}
