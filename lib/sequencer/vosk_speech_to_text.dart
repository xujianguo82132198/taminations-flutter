import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:vosk_flutter/vosk_flutter.dart';
import 'xfyun_speech_to_text.dart'
    show SpeechRecognitionAlternative, SpeechRecognitionResult;

class VoskSpeechToText extends ChangeNotifier {
  final _vosk = VoskFlutterPlugin.instance();
  Model? _model;
  Recognizer? _recognizer;
  SpeechService? _service;
  StreamSubscription<String>? _sub;
  bool _available = false;
  bool _listening = false;
  SpeechRecognitionResult? _lastResult;
  String? _lastError;

  bool get isAvailable => _available;
  bool get isListening => _listening;
  bool get hasResults => _lastResult != null;
  SpeechRecognitionResult? get lastResult => _lastResult;
  String? get lastError => _lastError;

  Future<bool> initialize() async {
    if (_available) return true;
    try {
      _model = await _vosk.createModel('assets/models/vosk-model-small-en-us-0.15');
      _recognizer = await _vosk.createRecognizer(model: _model!, sampleRate: 16000);
      _service = await _vosk.initSpeechService(_recognizer!);
      _available = true;
    } catch (e) {
      _lastError = 'vosk: $e';
      _available = false;
    }
    notifyListeners();
    return _available;
  }

  void listen({String? localeId}) {
    if (!_available || _listening) return;
    _lastResult = null;
    _sub?.cancel();
    _sub = _service!.onResult().listen((json) {
      final m = RegExp(r'"text"\s*:\s*"([^"]*)"').firstMatch(json);
      final text = m?.group(1) ?? '';
      if (text.isNotEmpty) {
        _lastResult = SpeechRecognitionResult(
            [SpeechRecognitionAlternative(text, 1.0)], true);
        notifyListeners();
      }
    });
    _service!.start();
    _listening = true;
    notifyListeners();
  }

  void sample({String? localeId}) => listen(localeId: localeId);
  void stop() { _sub?.cancel(); _sub = null; _service?.stop(); _listening = false; notifyListeners(); }
  void cancel() { stop(); _lastResult = null; }
  void pause() => stop();
  void resume() { if (!_listening) listen(); }
  void clearResults() => _lastResult = null;
  @override void dispose() { cancel(); super.dispose(); }
}
