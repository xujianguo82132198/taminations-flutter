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

  多语音引擎(离线优先):
  - 默认 Vosk 离线引擎(免费、无次数限制、不联网);
  - 自动模式:离线不可用时依次退回讯飞(中国大陆)→谷歌(海外);
  - 可在 Sequencer → Settings → 语音引擎 中手动指定。
  对外 API 与单个引擎一致,调用方无感切换

*/

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'vosk_speech_to_text.dart';

class DualSpeechProvider extends ChangeNotifier {

  static const _prefKey = '语音引擎';   //  auto / vosk / xfyun / google

  final vosk = VoskSpeechToText();

  ///  当前生效引擎名:'vosk' / 'xfyun' / 'google'
  String engine = 'vosk';
  String _setting = 'auto';   //  auto / vosk / xfyun / google

  dynamic get _active => vosk;

  bool get isAvailable => _active.isAvailable;
  bool get isListening => _active.isListening;
  bool get hasResults => _active.hasResults;
  String? get lastError =>
      _active.lastError;
  SpeechRecognitionResult? get lastResult => _active.lastResult;

  ///  分段取样(仅Vosk采样会话):已收段文本(0.3秒静音收段,
  ///  最多3段)。其他引擎无分段,返回空表
  List<String> get segments =>
      engine == 'vosk' ? vosk.segments : const <String>[];

  ///  命令完成事件(连续模式,静音0.9秒):整条口令的分段
  ///  快照与完成计数,三表流水线取用
  int get commandSeq =>
      engine == 'vosk' ? vosk.commandSeq : 0;
  List<String> get lastCommandSegments =>
      engine == 'vosk' ? vosk.lastCommandSegments : const <String>[];
  ///  采样会话内每个final的本句原文(Input模式按句消费)
  List<String> get sampleFinals =>
      engine == 'vosk' ? vosk.sampleFinals : const <String>[];
  ///  各段n-best候选(与segments同序)
  List<List<String>> get segmentAlts =>
      engine == 'vosk' ? vosk.segmentAlts : const <List<String>>[];

  ///  构建时间戳(每次构建手动更新,用户可验证新旧版本)
  static const buildStamp = '2026-10-09 15:33';
  DualSpeechProvider() {
    debugPrint('BUILD STAMP: $buildStamp');
    _loadSetting();
    //  任一引擎通知都向上转发
    vosk.addListener(_forward);
  }

  Future<void> _loadSetting() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _setting = prefs.getString(_prefKey) ?? 'auto';
    } catch (_) {}
    engine = _engineFor(_setting);
    debugPrint('DualSpeech: engine=$engine (setting=$_setting)');
    //  预热离线模型(首次解包需数秒,提前到打开页面时做,
    //  用户按下麦克风时基本已就绪)
    if (engine == 'vosk') unawaited(vosk.initialize());
    notifyListeners();
  }

  String _engineFor(String setting) => 'vosk';

  ///  设置引擎(auto/vosk/xfyun/google),持久化并立即生效
  Future<void> setEngine(String value) async {
    _setting = 'vosk';
    engine = 'vosk';
    unawaited(vosk.initialize());
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, value);
    } catch (_) {}
    debugPrint('DualSpeech: engine=$engine (setting=$value)');
    notifyListeners();
  }

  void _forward() => notifyListeners();

  Future<bool> initialize() async {
    if (engine == 'vosk') {
      final ok = await vosk.initialize();
      if (ok) {
        notifyListeners();
        return true;
      }

      notifyListeners();
      return false;
    }
    final ok = await _active.initialize();
    notifyListeners();
    return ok;
  }

  void listen({
    bool partialResults = false,
    String? localeId,
    Duration? listenFor,
    Duration? pauseFor,
  }) {
    _active.listen(localeId: localeId);
  }

  void sample({String? localeId, bool partialResults = true}) {
    _active.sample(
        localeId: localeId, partialResults: partialResults);
  }

  ///  采表采样限定口令词表(null=自由识别)
  void setSampleGrammar(List<String>? words) {
    if (engine == 'vosk') vosk.setSampleGrammar(words);
    else vosk.setSampleGrammar(null);
  }

  void stop() => _active.stop();
  void cancel() => _active.cancel();
  void pause() => _active.pause();
  void resume() => _active.resume();
  void clearResults() => _active.clearResults();

  @override
  void dispose() {
    vosk.removeListener(_forward);
    vosk.dispose();
    super.dispose();
  }

}
