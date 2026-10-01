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

  Vosk 离线语音识别(原生 AAR 直连,不经任何 Flutter 插件):
  英文小模型打包在 APK 内,完全离线、免费、无调用次数限制。
  对外 API 与讯飞引擎(SpeechToTextProvider)保持一致。

  与讯飞引擎的语义区别:
  - 监听期间音频在原生侧直接识别,不向 Dart 推音频流;
  - Vosk 自带断句(端点检测),持续监听不需要按轮换会话,
    每句结束自动给出最终结果并继续下一句,直到用户关闭;
  - 采样(PTT)抬起时主动向原生要收尾结果(voskFinal)。

*/

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'music_monitor.dart';
import 'xfyun_speech_to_text.dart'
    show SpeechRecognitionAlternative, SpeechRecognitionResult;

class VoskSpeechToText extends ChangeNotifier {

  bool _isAvailable = false;
  bool _isListening = false;
  SpeechRecognitionResult? _lastResult;
  String? _lastError;
  double _lastLevel = 0;
  bool _partialResults = false;
  bool _soundLevel = false;
  bool _continuous = false;
  bool _paused = false;
  bool _disposed = false;
  bool _sampleSession = false;

  StreamSubscription<MusicEvent>? _sub;
  final musicMonitor = MusicMonitor();

  //  采表词表(null=自由识别);仅下一轮采样会话使用
  List<String>? _grammarWords;

  //  本会话已确定的最终文字(识别器可能分段多次给最终结果,
  //  采样期间累计拼接,避免多词口令只取到前半段)
  String _sessionText = '';

  //  本会话见过的全部候选文本(分段事件+收尾并集,去重):
  //  收尾 flush 只带最后一段的候选,不能覆盖中间的完整列表
  final List<String> _sessionAlts = [];

  //  模型加载去重:并发的 initialize 共享同一次加载
  Future<bool>? _initFuture;

  VoskSpeechToText();

  //  所有日志统一带 VOSK 前缀,便于 adb logcat -s flutter 过滤定位
  void _log(String message) => debugPrint('VOSK $message');

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  ///  加载离线模型。首次运行需要从 assets 解包(数秒),之后常驻。
  Future<bool> initialize({bool debugLogging = false}) async {
    if (_isAvailable) return true;
    return _initFuture ??= _doInit().whenComplete(() => _initFuture = null);
  }

  Future<bool> _doInit() async {
    _log('initialize: loading model ...');
    try {
      _isAvailable = await musicMonitor.voskInit();
    } catch (e) {
      _log('initialize: EXCEPTION $e');
      _isAvailable = false;
    }
    if (!_isAvailable) _lastError = 'vosk 模型加载失败';
    _log('initialize: done, isAvailable=$_isAvailable');
    _notify();
    return _isAvailable;
  }

  bool get isAvailable => _isAvailable;

  bool get isNotAvailable => !_isAvailable;

  bool get isListening => _isListening;

  bool get isNotListening => !_isListening;

  bool get hasError => _lastError != null;

  bool get hasResults => _lastResult != null;

  SpeechRecognitionResult? get lastResult => _lastResult;

  String? get lastError => _lastError;

  double get lastLevel => _lastLevel;

  bool get isSampleSession => _sampleSession;

  void clearResults() {
    _log('clearResults');
    _lastResult = null;
  }

  ///  采表采样限定口令词表(null=自由识别)
  void setSampleGrammar(List<String>? words) {
    _grammarWords = words;
  }

  ///  开关式持续监听(与讯飞引擎一致):
  ///  空闲时调用开始连续识别;监听中再调一次视为用户点击关闭。
  ///  Vosk 自带断句,每句自动出最终结果,无需会话轮换。
  void listen({
    bool partialResults = true,
    bool onDevice = false,
    bool soundLevel = false,
    Duration? listenFor,
    Duration? pauseFor,
    String? localeId,
  }) {
    if (_isListening) {
      _log('listen: toggle OFF (was listening)');
      _toggleOff();
      return;
    }
    _log('listen: toggle ON (grammar=${_grammarWords?.length ?? 0} phrases)');
    _lastResult = null;
    _lastError = null;
    _lastLevel = 0;
    _partialResults = partialResults;
    _soundLevel = soundLevel;
    _continuous = true;
    _sampleSession = false;
    _paused = false;
    unawaited(_startSession());
  }

  ///  采样模式(PTT 按下说话):单轮识别,抬起(调用 stop)
  ///  后收尾给出最终结果
  void sample({bool partialResults = false, String? localeId}) {
    if (_isListening) {
      _log('sample: ignored (already listening)');
      return;
    }
    _log('sample: start (push-to-talk)');
    _lastResult = null;
    _lastError = null;
    _lastLevel = 0;
    _partialResults = partialResults;
    _continuous = false;
    _sampleSession = true;
    _paused = false;
    unawaited(_startSession());
  }

  ///  结束识别并收尾送出结果(采样抬起时调用)
  void stop() {
    _log('stop: isListening=$_isListening continuous=$_continuous');
    if (!_isListening) {
      _notify();
      return;
    }
    _continuous = false;
    _sampleSession = false;
    _paused = false;
    unawaited(_finish());
  }

  ///  完全停止并丢弃当前内容
  void cancel() {
    _log('cancel: isListening=$_isListening');
    _continuous = false;
    _sampleSession = false;
    _paused = false;
    _sub?.cancel();
    _sub = null;
    musicMonitor.voskStop();
    _lastResult = null;
    _isListening = false;
    _notify();
  }

  ///  暂停:收尾当前内容并停麦,等 resume 再继续
  void pause() {
    _log('pause: isListening=$_isListening');
    if (!_isListening) return;
    _paused = true;
    unawaited(_finish());
  }

  ///  恢复监听(仅持续模式的暂停之后有意义)
  void resume() {
    _log('resume: paused=$_paused continuous=$_continuous');
    if (!_paused) return;
    _paused = false;
    if (!_continuous) return;
    unawaited(_startSession());
  }

  @override
  void dispose() {
    _disposed = true;
    _continuous = false;
    _sub?.cancel();
    _sub = null;
    musicMonitor.voskStop();
    super.dispose();
  }

  ///  用户主动关闭:立即停止,不送出剩余内容
  void _toggleOff() {
    _continuous = false;
    _paused = false;
    _sub?.cancel();
    _sub = null;
    musicMonitor.voskStop();
    _isListening = false;
    _lastResult = null;
    _notify();
  }

  Future<void> _startSession() async {
    try {
      _sessionText = '';
      _sessionAlts.clear();
      _sub?.cancel();
      _sub = musicMonitor.events.listen(_onEvent);
      await musicMonitor.voskStart(
          grammar: _grammarWords == null || _grammarWords!.isEmpty
              ? null : jsonEncode(_grammarWords));
      _isListening = true;
      _log('session: listening');
    } catch (e) {
      _log('session: start FAILED: $e');
      _lastError = 'vosk start failed: $e';
      _isListening = false;
      _sub?.cancel();
      _sub = null;
    }
    _notify();
  }

  //  收尾:向原生要剩余语音的最终结果(采样抬起/暂停场景)
  Future<void> _finish() async {
    _sub?.cancel();
    _sub = null;
    String? json;
    try {
      json = await musicMonitor.voskFinal();
    } catch (_) {}
    final texts = _textsOf(json);
    if (texts.isNotEmpty) {
      _sessionText = _sessionText.isEmpty
          ? texts.first : '$_sessionText ${texts.first}';
      for (final t in texts) {
        if (!_sessionAlts.contains(t)) _sessionAlts.add(t);
      }
    }
    if (_sessionAlts.isNotEmpty) {
      //  默认值=累计拼接句;其余候选按见到的顺序跟上
      _log('finish: "$_sessionText" alts=$_sessionAlts');
      final alts = <SpeechRecognitionAlternative>[
        if (_sessionText.isNotEmpty)
          SpeechRecognitionAlternative(_sessionText, 1.0),
        for (final t in _sessionAlts)
          if (t != _sessionText) SpeechRecognitionAlternative(t, 1.0),
      ];
      _lastResult = SpeechRecognitionResult(alts, true);
    } else {
      _log('finish: final text empty');
    }
    if (!_continuous) _isListening = false;
    _notify();
  }

  void _onEvent(MusicEvent event) {
    if (!_isListening) return;
    switch (event.type) {
      case 'vosk_partial':
        if (_partialResults) {
          final text = _textField(event.text, 'partial');
          if (text != null && text.isNotEmpty) {
            _lastResult = SpeechRecognitionResult(
                [SpeechRecognitionAlternative(text, 0.0)], false);
            _notify();
          }
        }
        break;
      case 'vosk_final':
        //  断句自动给出的最终结果;采样期间累计拼接,
        //  避免多词口令只取到前半段(带全部候选供上层挑选)
        final texts = _textsOf(event.text);
        _log('final: $texts');
        if (texts.isNotEmpty) {
          _sessionText = _sessionText.isEmpty
              ? texts.first : '$_sessionText ${texts.first}';
          for (final t in texts) {
            if (!_sessionAlts.contains(t)) _sessionAlts.add(t);
          }
          _lastResult = SpeechRecognitionResult(
              [for (final t in _sessionAlts)
                SpeechRecognitionAlternative(t, 1.0)],
              true);
          _notify();
        }
        break;
      case 'speech_amplitude':
        if (_soundLevel && event.level != null) {
          _lastLevel = event.level!;
          _notify();
        }
        break;
      case 'speech_error':
        _lastError = 'native capture failed';
        _notify();
        break;
    }
  }

  //  从结果 JSON 取全部候选文本(去重,首选在前);
  //  setMaxAlternatives 开启后 JSON 带 alternatives 数组
  List<String> _textsOf(String? json) {
    if (json == null || json.isEmpty) return const [];
    try {
      final v = jsonDecode(json);
      if (v is! Map) return const [];
      final out = <String>[];
      if (v['text'] is String && (v['text'] as String).trim().isNotEmpty) {
        out.add((v['text'] as String).trim());
      }
      final alts = v['alternatives'];
      if (alts is List) {
        for (final a in alts) {
          if (a is Map && a['text'] is String) {
            final t = (a['text'] as String).trim();
            if (t.isNotEmpty && !out.contains(t)) out.add(t);
          }
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  //  从 Vosk 结果 JSON 中取字段:
  //  最终结果 {"text": "..."},中间结果 {"partial": "..."}
  String? _textField(String? json, String key) {
    if (json == null || json.isEmpty) return null;
    try {
      final v = jsonDecode(json);
      return v is Map && v[key] is String ? v[key] as String : null;
    } catch (_) {
      return null;
    }
  }

}
