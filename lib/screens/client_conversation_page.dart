import 'dart:async';

import 'package:chauffeur/services/client_conversation_audio.dart';
import 'package:chauffeur/services/client_conversation_service.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

class ClientConversationPage extends StatefulWidget {
  const ClientConversationPage({
    super.key,
    required this.driverId,
    this.orderId,
    this.service,
    this.audio,
    this.speech,
  });

  final String driverId;
  final String? orderId;
  final ClientConversationService? service;
  final ClientConversationAudio? audio;
  final SpeechToText? speech;

  @override
  State<ClientConversationPage> createState() => _ClientConversationPageState();
}

class _ClientConversationPageState extends State<ClientConversationPage>
    with WidgetsBindingObserver {
  late final _service = widget.service ?? ClientConversationService();
  late final _audio = widget.audio ?? ClientConversationAudio();
  late final _speech = widget.speech ?? SpeechToText();
  final _input = TextEditingController();
  final _seen = <String>{};
  StreamSubscription<ConversationClient?>? _clientSubscription;
  StreamSubscription<List<ConversationMessage>>? _messageSubscription;
  ConversationClient? _client;
  List<ConversationMessage> _messages = [];
  var _loading = true;
  var _sending = false;
  var _refreshing = false;
  var _foreground = true;
  var _dictating = false;
  var _speechGeneration = 0;
  var _voiceConsent = false;
  var _sessionGeneration = 0;
  var _audioGeneration = 0;
  String? _error;
  String? _pendingText;
  String? _pendingId;
  Future<void> _queue = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _clientSubscription = _service
        .watchClient(widget.driverId)
        .listen(
          _onClient,
          onError: (Object error) {
            _onClient(null);
            _report(error);
          },
        );
    unawaited(_refresh());
  }

  void _report(Object error) {
    debugPrint('Conversation client : $error');
    if (mounted) {
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      await _service.refresh();
    } on Object catch (error) {
      _report(error);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _onClient(ConversationClient? client) {
    if (!mounted) return;
    if (widget.orderId != null && client?.orderId != widget.orderId) {
      client = null;
    }
    final changed = client?.sessionId != _client?.sessionId;
    setState(() {
      _client = client;
      _loading = false;
      if (changed) {
        _sessionGeneration++;
        _audioGeneration++;
        _messages = [];
        _seen.clear();
        _input.clear();
        _pendingId = null;
        _pendingText = null;
        _error = null;
      }
    });
    if (!changed) return;
    unawaited(_cancelDictation());
    unawaited(_stop());
    unawaited(_messageSubscription?.cancel());
    if (client == null) return;
    final sessionId = client.sessionId;
    final generation = _sessionGeneration;
    var initialSnapshot = true;
    _messageSubscription = _service
        .watchMessages(widget.driverId, sessionId)
        .listen(
          (messages) {
            if (!mounted || generation != _sessionGeneration) return;
            setState(() => _messages = messages);
            for (final message in messages) {
              if (initialSnapshot || message.role != 'client' || !_foreground) {
                _seen.add(message.id);
                continue;
              }
              if (message.source != 'fr' && message.translation == null) {
                continue;
              }
              if (!_seen.add(message.id)) {
                continue;
              }
              _enqueue(message, sessionId);
            }
            initialSnapshot = false;
          },
          onError: (Object error) {
            if (generation == _sessionGeneration) _report(error);
          },
        );
  }

  void _enqueue(ConversationMessage message, String sessionId) {
    final generation = _audioGeneration;
    _queue = _queue.then((_) => _receive(message, sessionId, generation));
  }

  Future<void> _receive(
    ConversationMessage message,
    String sessionId,
    int generation,
  ) async {
    bool active() =>
        mounted && _foreground && !_dictating && generation == _audioGeneration;
    if (!active()) return;
    try {
      final text = message.source == 'fr' ? message.text : message.translation;
      if (text == null) {
        throw StateError('Traduction en attente sur la tablette.');
      }
      if (!active()) return;
      if (message.target != 'fr') {
        throw StateError('Langue du message reçu invalide.');
      }
      if (active()) await _audio.speak(text, isActive: active);
    } on Object catch (error) {
      if (active()) _report(error);
    }
  }

  Future<void> _send() async {
    final client = _client;
    final text = _input.text.trim();
    if (_sending || client == null) return;
    if (text.isEmpty || text.runes.length > 500) {
      _report(StateError('Saisissez un message de 1 à 500 caractères.'));
      return;
    }
    final generation = _sessionGeneration;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _cancelDictation();
      if (!mounted || generation != _sessionGeneration) return;
      if (_pendingText != text) {
        _pendingId = _service.newMessageId();
        _pendingText = text;
      }
      await _service.send(client.sessionId, _pendingId!, text);
      if (!mounted || generation != _sessionGeneration) return;
      _input.clear();
      _pendingId = null;
      _pendingText = null;
    } on Object catch (error) {
      if (generation == _sessionGeneration) _report(error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _stop() async {
    try {
      await _audio.stop();
    } on Object catch (error) {
      _report(error);
    }
  }

  Future<void> _cancelDictation({bool disposing = false}) async {
    _speechGeneration++;
    if (mounted && !disposing) setState(() => _dictating = false);
    try {
      await _speech.cancel();
    } on Object catch (error) {
      _report(error);
    }
  }

  Future<void> _dictate() async {
    if (_dictating) {
      try {
        await _speech.stop();
      } on Object catch (error) {
        _report(error);
      } finally {
        if (mounted) setState(() => _dictating = false);
      }
      return;
    }
    final session = _sessionGeneration;
    if (!_voiceConsent) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Activer la dictée ?'),
          content: const Text(
            'La reconnaissance vocale du téléphone peut transmettre votre voix à Google ou Apple. Relisez le texte avant de l’envoyer.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Activer'),
            ),
          ],
        ),
      );
      if (!mounted ||
          accepted != true ||
          session != _sessionGeneration ||
          !_foreground) {
        return;
      }
      _voiceConsent = true;
    }
    final generation = ++_speechGeneration;
    bool active() =>
        mounted &&
        _foreground &&
        session == _sessionGeneration &&
        generation == _speechGeneration;
    setState(() {
      _dictating = true;
      _error = null;
    });
    try {
      _audioGeneration++;
      await _stop();
      final available = await _speech.initialize(
        onError: (error) {
          if (!active()) return;
          setState(() => _dictating = false);
          _report(
            StateError(
              'Dictée indisponible : ${error.errorMsg}. Vérifiez le microphone et la langue française.',
            ),
          );
        },
        onStatus: (status) {
          if (active() && (status == 'done' || status == 'notListening')) {
            setState(() => _dictating = false);
          }
        },
      );
      if (!active()) return;
      if (!available) {
        throw StateError(
          'Autorisez le microphone et la reconnaissance vocale dans les réglages.',
        );
      }
      final locales = await _speech.locales();
      if (!active()) return;
      final french = locales
          .where((locale) => locale.localeId.toLowerCase().startsWith('fr'))
          .toList();
      if (french.isEmpty) {
        throw StateError(
          'Installez la reconnaissance vocale française sur le téléphone.',
        );
      }
      final base = _input.text.trimRight();
      await _speech.listen(
        listenOptions: SpeechListenOptions(
          localeId: french.first.localeId,
          partialResults: true,
          onDevice: false,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
        ),
        onResult: (result) {
          if (!active()) return;
          final value = [
            if (base.isNotEmpty) base,
            result.recognizedWords,
          ].join(' ');
          final limited = String.fromCharCodes(value.runes.take(500));
          _input.value = TextEditingValue(
            text: limited,
            selection: TextSelection.collapsed(offset: limited.length),
          );
          if (result.finalResult) setState(() => _dictating = false);
        },
      );
    } on Object catch (error) {
      if (active()) {
        setState(() => _dictating = false);
        _report(error);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _audioGeneration++;
      unawaited(_cancelDictation());
      unawaited(_stop());
    } else {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionGeneration++;
    _audioGeneration++;
    unawaited(_cancelDictation(disposing: true));
    unawaited(_clientSubscription?.cancel());
    unawaited(_messageSubscription?.cancel());
    unawaited(
      _audio.close().catchError((Object error) {
        debugPrint('Fermeture audio de la conversation : $error');
      }),
    );
    _input.dispose();
    super.dispose();
  }

  String _display(ConversationMessage message) =>
      message.role == 'driver' || message.source == 'fr'
      ? message.text
      : message.translation ?? 'Traduction en attente sur la tablette';

  @override
  Widget build(BuildContext context) {
    final client = _client;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Conversation client'),
        actions: [
          IconButton(
            tooltip: 'Actualiser',
            onPressed: _refreshing ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_loading || _refreshing) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (client == null)
            const Expanded(
              child: Center(child: Text('Aucun client en cours.')),
            ),
          if (client != null) ...[
            ListTile(
              title: Text(client.name),
              subtitle: Text(
                'Langue : ${conversationLanguages[client.language]}'
                '\n${client.orderId == null ? 'Conversation libre' : 'Course ${client.orderId}'}',
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (_messages.isEmpty) const Text('Aucun message.'),
                  for (final message in _messages)
                    Align(
                      key: ValueKey('message-bubble-${message.id}'),
                      alignment: message.role == 'driver'
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: .85,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 5),
                          decoration: BoxDecoration(
                            color: message.role == 'driver'
                                ? Theme.of(context).colorScheme.primaryContainer
                                : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(18),
                              topRight: const Radius.circular(18),
                              bottomLeft: Radius.circular(
                                message.role == 'driver' ? 18 : 4,
                              ),
                              bottomRight: Radius.circular(
                                message.role == 'driver' ? 4 : 18,
                              ),
                            ),
                          ),
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                message.role == 'driver' ? 'Vous' : client.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              SelectableText(_display(message)),
                              if (message.role == 'client' &&
                                  message.source != 'fr')
                                Text('Original : ${message.text}'),
                              if (message.role == 'client')
                                TextButton.icon(
                                  onPressed: () =>
                                      _enqueue(message, client.sessionId),
                                  icon: const Icon(Icons.volume_up),
                                  label: const Text('Lire'),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const ValueKey('conversation-input'),
                      controller: _input,
                      enabled: !_sending && !_dictating,
                      maxLength: 500,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Votre réponse en français',
                      ),
                    ),
                    TextButton.icon(
                      key: const ValueKey('conversation-dictate'),
                      onPressed: _sending ? null : _dictate,
                      icon: Icon(
                        _dictating ? Icons.stop_circle_outlined : Icons.mic,
                      ),
                      label: Text(
                        _dictating ? 'Arrêter la dictée' : 'Dicter une réponse',
                      ),
                    ),
                    FilledButton.icon(
                      key: const ValueKey('conversation-send'),
                      onPressed: _sending || _dictating ? null : _send,
                      icon: const Icon(Icons.send),
                      label: Text(_sending ? 'Envoi en cours…' : 'Envoyer'),
                    ),
                    const Text(
                      'Lecture automatique des nouveaux messages uniquement au premier plan.',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
