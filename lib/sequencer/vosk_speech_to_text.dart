/*

  Taminations Square Dance Animations
  Copyright (C) 2026 Brad Christie

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.

*/

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vosk_flutter/vosk_flutter.dart';

import 'xfyun_speech_to_text.dart'
    show SpeechRecognitionAlternative, SpeechRecognitionResult;

///  Vosk 离线语音引擎(永久免费,无配额限制,无需网络)。
///  唯一引擎:替代讯飞和谷歌。
///  自由识别(不限词表),映射表的误差匹配负责最终校正。
class VoskSpeechToText extends ChangeNotifier {

  final _vosk = VoskFlutterPlugin.instance();
  Model? _model;
  Recognizer? _recognizer;
  SpeechService? _service;
  StreamSubscription<String>? _resultSub;
  bool _available = false;
  bool _listening = false;
  SpeechRecognitionResult? _lastResult;
  String? _lastError;

  bool get isAvailable => _available;
  bool get isListening => _listening;
  bool get hasResults => _lastResult != null;
  SpeechRecognitionResult? get lastResult => _lastResult;
  String? get lastError => _lastError;

  ///  初始化:加载离线模型
  Future<bool> initialize() async {
    if (_available) return true;
    try {
      _model = await _vosk.createModel(
          'assets/models/vosk-model-small-en-us-0.15');
      _recognizer = await _vosk.createRecognizer(
          model: _model!, sampleRate: 16000);
      _service = await _vosk.initSpeechService(_recognizer!);
      _available = true;
      debugPrint('Vosk: initialized');
    } catch (e) {
      debugPrint('Vosk init failed: $e');
      _lastError = 'vosk init: $e';
      _available = false;
    }
    notifyListeners();
    return _available;
  }

  ///  开始识别
  void listen({String? localeId}) {
    if (!_available || _listening) return;
    _lastResult = null;
    _resultSub?.cancel();
    _resultSub = _service!.onResult().listen(_onResult);
    _service!.start();
    _listening = true;
    notifyListeners();
  }

  ///  采样模式(按下说话,抬起结束)
  void sample({String? localeId}) => listen(localeId: localeId);

  void _onResult(String json) {
    debugPrint('Vosk result: $json');
    final text = _extractText(json);
    if (text.isNotEmpty) {
      _lastResult = SpeechRecognitionResult(
          [SpeechRecognitionAlternative(text, 1.0)], true);
      notifyListeners();
    }
  }

  String _extractText(String json) {
    final m = RegExp(r'"text"\s*:\s*"([^"]*)"').firstMatch(json);
    return m?.group(1) ?? '';
  }

  void stop() {
    _resultSub?.cancel();
    _resultSub = null;
    _service?.stop();
    _listening = false;
    notifyListeners();
  }

  void cancel() {
    stop();
    _lastResult = null;
  }

  void pause() => stop();
  void resume() {
    if (!_listening) listen();
  }

  void clearResults() => _lastResult = null;

  @override
  void dispose() {
    cancel();
    super.dispose();
  }

}
