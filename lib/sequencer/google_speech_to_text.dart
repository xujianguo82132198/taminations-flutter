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

import 'package:flutter/foundation.dart';

import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'xfyun_speech_to_text.dart'
    show SpeechRecognitionAlternative, SpeechRecognitionResult;

///  谷歌语音引擎(原上游方案,包装 speech_to_text 包)。
///  与讯飞引擎同构的 API,供 DualSpeechProvider 切换使用;
///  适用有 GMS 的地区(美国等)。
class GoogleSpeechToText extends ChangeNotifier {

  final stt.SpeechToText _stt = stt.SpeechToText();
  bool _available = false;
  SpeechRecognitionResult? _lastResult;

  bool get isAvailable => _available;
  bool get isListening => _stt.isListening;
  bool get hasResults => _lastResult != null;
  bool get hasError => false;
  SpeechRecognitionResult? get lastResult => _lastResult;

  Future<bool> initialize() async {
    if (_available) return true;
    try {
      _available = await _stt.initialize();
    } catch (e) {
      debugPrint('google stt init failed: $e');
      _available = false;
    }
    notifyListeners();
    return _available;
  }

  void listen({
    bool partialResults = false,
    String? localeId,
    Duration? listenFor,
    Duration? pauseFor,
  }) {
    if (!_available || _stt.isListening) return;
    _lastResult = null;
    _stt.listen(
      onResult: (r) {
        _lastResult = SpeechRecognitionResult(
            [SpeechRecognitionAlternative(
                r.recognizedWords, r.confidence)],
            r.finalResult);
        notifyListeners();
      },
      localeId: localeId,
      partialResults: partialResults,
    );
  }

  ///  采样(按住说话):与 listen 相同,抬起时 stop 收尾
  void sample({bool partialResults = false, String? localeId}) =>
      listen(partialResults: partialResults, localeId: localeId);

  void stop() => _stt.stop();
  void cancel() {
    _stt.cancel();
    _lastResult = null;
  }

  ///  包无暂停语义:等效停止;上层 resume 会重新 listen
  void pause() => _stt.stop();
  void resume() {
    if (!_stt.isListening) listen();
  }

  void clearResults() => _lastResult = null;

  @override
  void dispose() {
    cancel();
    super.dispose();
  }

}
