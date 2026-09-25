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
import 'package:shared_preferences/shared_preferences.dart';

import 'google_speech_to_text.dart';
import 'xfyun_speech_to_text.dart';

///  双语音引擎(中国用讯飞,美国/海外用谷歌):
///  - 自动(默认):先用讯飞;连接失败(海外网络)自动切谷歌并重试;
///    谷歌不可用(无 GMS)则保持讯飞
///  - 手动:设置中指定引擎
///  对外 API 与单个引擎一致,调用方无感切换
class DualSpeechProvider extends ChangeNotifier {

  static const _prefKey = '语音引擎';   //  auto / xfyun / google

  final xfyun = SpeechToTextProvider();
  final google = GoogleSpeechToText();

  ///  当前生效引擎名:'xfyun' / 'google'
  String engine = 'xfyun';
  String _setting = 'auto';   //  auto / xfyun / google
  Timer? _failoverTimer;
  bool _switchedNoticeShown = false;

  dynamic get _active =>
      engine == 'google' ? google : xfyun;

  bool get isAvailable => _active.isAvailable;
  bool get isListening => _active.isListening;
  bool get hasResults => _active.hasResults;
  String? get lastError =>
      engine == 'google' ? null : xfyun.lastError;
  SpeechRecognitionResult? get lastResult => _active.lastResult;

  DualSpeechProvider() {
    _loadSetting();
    //  任一引擎通知都向上转发
    xfyun.addListener(_forward);
    google.addListener(_forward);
  }

  Future<void> _loadSetting() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _setting = prefs.getString(_prefKey) ?? 'auto';
    } catch (_) {}
    if (_setting == 'google') engine = 'google';
    else engine = 'xfyun';
  }

  ///  设置引擎(auto/xfyun/google),持久化并立即生效
  Future<void> setEngine(String value) async {
    _setting = value;
    engine = value == 'google' ? 'google' : 'xfyun';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, value);
    } catch (_) {}
    debugPrint('DualSpeech: engine=$engine (setting=$value)');
    notifyListeners();
  }

  void _forward() {
    if (!_switchedNoticeShown &&
        engine == 'xfyun' && !xfyun.isListening &&
        (xfyun.lastError?.contains('connect') ?? false)) {
      //  首次连接失败提示一次(海外网络场景)
      _switchedNoticeShown = true;
      debugPrint('DualSpeech: xfyun connect failed noticed');
    }
    notifyListeners();
  }

  Future<bool> initialize() async {
    if (_setting == 'auto' && engine == 'xfyun') {
      //  自动模式:两个都尝试初始化,优先讯飞(中国),
      //  讯飞不可初始化且谷歌可用时切谷歌
      final xok = await xfyun.initialize();
      if (xok) {
        notifyListeners();
        return true;
      }
      final gok = await google.initialize();
      if (gok) {
        engine = 'google';
        debugPrint('DualSpeech: xfyun unavailable -> google');
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
    _active.listen(
        partialResults: partialResults,
        localeId: localeId,
        listenFor: listenFor,
        pauseFor: pauseFor);
    _watchFailover();
  }

  void sample({String? localeId}) {
    if (engine == 'google')
      google.sample(localeId: localeId);
    else
      xfyun.sample(localeId: localeId);
    _watchFailover();
  }

  ///  自动模式:讯飞 5 秒内没进入监听且报连接错误 ->
  ///  切谷歌重试一次(海外网络)
  void _watchFailover() {
    _failoverTimer?.cancel();
    if (_setting != 'auto' || engine != 'xfyun') return;
    _failoverTimer = Timer(const Duration(seconds: 5), () async {
      if (engine != 'xfyun' || xfyun.isListening) return;
      final err = xfyun.lastError ?? '';
      if (!err.contains('connect')) return;
      final gok = await google.initialize();
      if (gok) {
        engine = 'google';
        debugPrint('DualSpeech: failover xfyun->google');
        google.listen(localeId: 'en_US');
        notifyListeners();
      }
    });
  }

  void stop() => _active.stop();
  void cancel() => _active.cancel();
  void pause() => _active.pause();
  void resume() => _active.resume();
  void clearResults() => _active.clearResults();

  @override
  void dispose() {
    _failoverTimer?.cancel();
    xfyun.removeListener(_forward);
    google.removeListener(_forward);
    xfyun.dispose();
    google.dispose();
    super.dispose();
  }

}
