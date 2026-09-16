/*

  Taminations Square Dance Animations
  Copyright (C) 2026 Brad Christie

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  speech_to_text 包里 SpeechToTextProvider 的替代品:
  对外 API 保持一致,底层改为科大讯飞语音听写(流式版)云端识别,
  不依赖设备的 Google 语音服务,在没有 GMS 的国行手机上也能使用。

  与原版语义的区别:listen() 是开关式的持续监听——
  第一次调用开始连续识别(图标保持红色),监听中再次调用 listen()
  视为用户点击关闭;每轮会话由服务端 VAD(静音 pauseFor)自动断句,
  断句后自动开启下一轮,直到用户主动关闭。

*/

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'xfyun_iat_client.dart';
import 'xfyun_keys.dart';

///  与 speech_to_text 包同名同结构的结果类型。
class SpeechRecognitionAlternative {

  final String recognizedWords;
  final double confidence;

  const SpeechRecognitionAlternative(this.recognizedWords, this.confidence);

}

class SpeechRecognitionResult {

  final List<SpeechRecognitionAlternative> alternates;
  final bool finalResult;

  const SpeechRecognitionResult(this.alternates, this.finalResult);

  String get recognizedWords =>
      alternates.isEmpty ? '' : alternates.first.recognizedWords;

}

class SpeechToTextProvider extends ChangeNotifier {

  final AudioRecorder _recorder = AudioRecorder();

  bool _isAvailable = false;
  bool _isListening = false;
  SpeechRecognitionResult? _lastResult;
  String? _lastError;
  double _lastLevel = 0;
  bool _debugLogging = false;
  bool _partialResults = false;

  //  持续监听状态
  bool _continuous = false;
  bool _paused = false;
  bool _disposed = false;
  int _consecutiveFailures = 0;
  static const int _maxConsecutiveFailures = 3;

  //  讯飞单次会话最长 60 秒,到 50 秒主动收尾换下一轮
  static const Duration _sessionRecycle = Duration(seconds: 50);

  //  刻意讲话判定:对着麦克风讲话的音量一般在 -10 ~ -20dB,
  //  环境噪音/远场语音通常低于 -35dB
  static const double _speechGateDb = -30.0;

  //  采样会话(按下说话/抬起出结果的PTT采集):
  //  单轮识别,不做音量门限(口令员按下即为刻意语音)
  bool _sampleSession = false;
  bool get isSampleSession => _sampleSession;

  //  句尾静音判定:检测到讲话后连续静音超过此时长,暂停并收尾本轮
  static const Duration _utteranceEndSilence = Duration(seconds: 2);

  double _sessionPeak = -60.0;
  bool _sessionHadSpeech = false;
  bool _sessionSampled = false;
  DateTime? _lastSpeechAt;

  XfyunIatClient? _client;
  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  Timer? _recycleTimer;
  Duration _endSilence = const Duration(seconds: 5);
  String? _localeId;
  bool _soundLevel = false;

  ///  与原版不同:底层引擎固定为讯飞听写,不需要再传入 SpeechToText 实例。
  SpeechToTextProvider();

  //  所有日志统一带 STT 前缀,便于 adb logcat -s flutter 过滤定位
  void _log(String message) => debugPrint('STT $message');

  //  dispose 之后不再通知监听者(ChangeNotifier 已销毁)
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  ///  请求麦克风权限并检查讯飞凭据是否已配置。
  ///  返回 true 表示可以调用 [listen]。
  Future<bool> initialize({bool debugLogging = false}) async {
    _log('initialize: start, current isAvailable=$_isAvailable');
    if (_isAvailable) return _isAvailable;
    _debugLogging = debugLogging;
    _log('initialize: xfyun keys configured=${XfyunKeys.configured} '
        '(appId length=${XfyunKeys.appId.length}, '
        'apiKey length=${XfyunKeys.apiKey.length}, '
        'apiSecret length=${XfyunKeys.apiSecret.length})');
    if (!XfyunKeys.configured) {
      _log('initialize: FAIL - xfyun keys not configured, '
          'see lib/sequencer/xfyun_keys_template.dart');
      return false;
    }
    try {
      _log('initialize: requesting mic permission ...');
      _isAvailable = await _recorder.hasPermission();
    } catch (error) {
      _log('initialize: mic permission request THREW: $error');
      _isAvailable = false;
    }
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

  ///  清空上一次的识别结果(调用方在 build 里处理完结果后调用,
  ///  防止同一条结果被重复处理)。持续监听模式下不会自动清空。
  void clearResults() {
    _log('clearResults');
    _lastResult = null;
  }

  ///  麦克风音量(dB),仅在 [listen] 的 soundLevel 为 true 时更新。
  double get lastLevel => _lastLevel;

  ///  开关式持续监听:
  ///  空闲时调用 -> 开始连续识别;
  ///  监听中调用 -> 用户点击关闭,停止识别。
  ///  [pauseFor] 仅作为服务端 VAD 的兜底静音时长;句尾判定由本地音量门限
  ///  + [_utteranceEndSilence] 完成,收尾更快且不受尾随噪音干扰;
  ///  [listenFor] 仅为兼容原 API,每轮会话固定在约 50 秒主动换轮。
  void listen({
    bool partialResults = true,
    bool onDevice = false,
    bool soundLevel = false,
    Duration? listenFor,
    Duration? pauseFor,
    String? localeId,
  }) {
    if (_isListening || _client != null) {
      _log('listen: toggle OFF (was listening)');
      _toggleOff();
      return;
    }
    _log('listen: toggle ON, localeId=$localeId partialResults=$partialResults '
        'soundLevel=$soundLevel listenFor=$listenFor pauseFor=$pauseFor');
    _lastResult = null;
    _lastError = null;
    _lastLevel = 0;
    _partialResults = partialResults;
    _continuous = true;
    _sampleSession = false;
    _paused = false;
    _consecutiveFailures = 0;
    _endSilence = pauseFor ?? const Duration(seconds: 5);
    _localeId = localeId;
    _soundLevel = soundLevel;
    unawaited(_startSession());
  }

  ///  采样模式(PTT 按下说话):单轮识别,抬起(调用 stop)后
  ///  立即收尾给出最终结果;不做音量门限,不自动开下一轮
  void sample({
    bool partialResults = false,
    String? localeId,
  }) {
    if (_isListening || _client != null) {
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
    _consecutiveFailures = 0;
    _endSilence = const Duration(seconds: 5);
    _localeId = localeId;
    unawaited(_startSession());
  }

  ///  结束当前一轮会话并把已识别内容作为最终结果送出;
  ///  持续监听模式下会自动开启下一轮。
  void stop() {
    _log('stop: isListening=$_isListening continuous=$_continuous');
    if (!_isListening) {
      _notify();
      return;
    }
    _stopRecording();
    _client?.finishAudio();
    _notify();
  }

  ///  完全停止监听并丢弃当前轮已识别的内容。
  void cancel() {
    _log('cancel: isListening=$_isListening');
    _continuous = false;
    _sampleSession = false;
    _paused = false;
    _stopRecording();
    _client?.abort();
    _client = null;
    _lastResult = null;
    _isListening = false;
    _notify();
  }

  ///  暂停监听:立即停麦并收尾当前轮(有刻意讲话则照常送出结果),
  ///  之后不再自动开启新一轮,直到 [resume]。
  void pause() {
    _log('pause: manual, isListening=$_isListening');
    if (!_isListening) return;
    _paused = true;
    _stopRecording();
    _client?.finishAudio();
    _notify();
  }

  ///  恢复监听:开启新一轮识别。仅对持续监听模式有意义。
  void resume() {
    _log('resume: isListening=$_isListening continuous=$_continuous');
    _paused = false;
    if (_isListening || !_continuous) return;
    unawaited(_startSession());
  }

  @override
  void dispose() {
    _disposed = true;
    _continuous = false;
    _paused = false;
    _stopRecording();
    _client?.abort();
    _client = null;
    unawaited(_recorder.dispose());
    super.dispose();
  }

  ///  用户主动关闭:立即停止,不送出剩余内容。
  void _toggleOff() {
    _continuous = false;
    _paused = false;
    _stopRecording();
    _client?.abort();
    _client = null;
    _isListening = false;
    _lastResult = null;
    _notify();
  }

  Future<void> _startSession() async {
    _log('session: start, language=${_languageFor(_localeId)} '
        'endSilence=${_endSilence.inMilliseconds}ms');
    //  每轮会话的音量统计重置
    _sessionPeak = -60.0;
    _sessionHadSpeech = false;
    _lastSpeechAt = null;
    XfyunIatClient? client;
    client = XfyunIatClient(
      appId: XfyunKeys.appId,
      apiKey: XfyunKeys.apiKey,
      apiSecret: XfyunKeys.apiSecret,
      language: _languageFor(_localeId),
      endSilenceMs: _endSilence.inMilliseconds,
      debugLogging: _debugLogging,
      onResult: (result) => _onIatResult(client!, result),
      onError: (code, message) => _onIatError(client!, code, message),
    );
    try {
      _log('session: connecting websocket ...');
      await client.connect();
    } catch (error) {
      _log('session: websocket connect FAILED: $error');
      _isListening = false;
      _lastError = 'speech recognition connect failed: $error';
      _onSessionFailure(client);
      return;
    }
    _log('session: websocket connected');
    //  连接建立期间可能已被取消/销毁(切后台、退出页面),
    //  直接废弃本会话,不再启动录音
    if (_disposed || !_continuous) {
      _log('session: cancelled while connecting, abort');
      client.abort();
      return;
    }
    final session = client;
    _client = session;
    _isListening = true;
    _notify();
    try {
      //  recorder.stop 可重入,先确保上一轮录音已完全停止
      _log('session: stopping previous recording ...');
      await _recorder.stop();
      _log('session: starting pcm 16k mono stream ...');
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ));
      _log('session: recording started');
      _audioSubscription = stream.listen(
          (chunk) => session.sendAudio(chunk),
          onError: (Object error) =>
              _onIatError(session, -1, 'audio stream error: $error'));
      //  音量监测始终开启:用于句尾判定和噪音门限,
      //  soundLevel 参数只决定是否把音量暴露给调用方
      _amplitudeSubscription = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((amplitude) => _onAmplitude(amplitude.current, session));
      _log('session: amplitude monitoring on '
          '(gate=$_speechGateDb endSilence=$_utteranceEndSilence)');
    } catch (error) {
      _log('session: recorder FAILED: $error');
      _onIatError(session, -1, 'microphone error: $error');
      return;
    }
    _sessionSampled = _sampleSession;
    _recycleTimer = Timer(_sessionRecycle, () {
      _log('session: $_sessionRecycle recycle time reached -> wrap up');
      stop();
    });
    _log('session: listening');
  }

  //  音量回调:记录峰值、判定刻意讲话、检测句尾静音
  void _onAmplitude(double level, XfyunIatClient session) {
    if (level > _sessionPeak) _sessionPeak = level;
    //  采样会话(PTT)视为刻意语音,不受音量门限限制
    if (_sessionSampled) {
      _sessionHadSpeech = true;
      _lastSpeechAt = DateTime.now();
    }
    if (level > _speechGateDb) {
      if (!_sessionHadSpeech) {
        _log('amplitude: speech detected, level=${level.toStringAsFixed(1)}dB');
      }
      _sessionHadSpeech = true;
      _lastSpeechAt = DateTime.now();
    }
    if (_soundLevel) {
      _lastLevel = level;
      _notify();
    }
    //  句尾判定:检测到讲话后连续静音超过阈值 -> 暂停收尾,
    //  停麦后环境噪音不会再进入本轮识别
    if (_sessionHadSpeech &&
        _client == session &&
        _lastSpeechAt != null &&
        DateTime.now().difference(_lastSpeechAt!) > _utteranceEndSilence) {
      _log('amplitude: utterance end (silence > $_utteranceEndSilence, '
          'peak=${_sessionPeak.toStringAsFixed(1)}dB) -> pause & wrap up');
      stop();
    }
  }

  void _onIatResult(XfyunIatClient client, XfyunIatResult result) {
    //  只处理当前会话的回调,丢弃已被替换/关闭的旧会话
    if (_client != client) {
      _log('result: dropped (client replaced), isFinal=${result.isFinal}');
      return;
    }
    _log('result: isFinal=${result.isFinal} '
        'best="${result.bestText}" alternates=${result.alternates.length}');
    if (result.isFinal) {
      _stopRecording();
      _client = null;
      //  音量门限:整轮没有超过门限的说话(环境噪音/远场非刻意语音),
      //  即使识别出文字也丢弃,不送结果
      if (!_sessionHadSpeech) {
        _log('result: discarded by speech gate '
            '(peak=${_sessionPeak.toStringAsFixed(1)}dB < $_speechGateDb)');
      } else if (result.bestText.isNotEmpty) {
        _lastResult = SpeechRecognitionResult(
            [for (final text in result.alternates)
              SpeechRecognitionAlternative(text, 1.0)],
            true);
        _consecutiveFailures = 0;
      } else {
        _log('result: final text empty, no result delivered');
      }
      if (_continuous && !_paused) {
        //  持续监听:保持红色状态,识别已返回 -> resume 开启下一轮
        _log('session: continuous -> starting next session');
        unawaited(_startSession());
      } else {
        _isListening = false;
      }
      _notify();
    } else if (_partialResults && result.bestText.isNotEmpty) {
      _lastResult = SpeechRecognitionResult(
          [SpeechRecognitionAlternative(result.bestText, 0.0)], false);
      _notify();
    }
  }

  void _onIatError(XfyunIatClient client, int code, String message) {
    if (_client != client) return;
    _stopRecording();
    _client = null;
    _lastError = 'xfyun iat $code: $message';
    if (code == 10105 || code == 10163) {
      //  鉴权失败通常是设备时钟偏差过大(服务端允许 300 秒)
      _lastError = '$_lastError (check device date/time)';
    }
    _log('error: $_lastError');
    _onSessionFailure(client);
  }

  //  会话异常结束:持续模式下重试,连续失败太多次则彻底停止
  void _onSessionFailure(XfyunIatClient client) {
    client.abort();
    if (!_continuous || _paused) {
      _isListening = false;
      _notify();
      return;
    }
    _consecutiveFailures++;
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      _log('session: $_consecutiveFailures consecutive failures, giving up');
      _continuous = false;
      _isListening = false;
      _notify();
      return;
    }
    _log('session: failure #$_consecutiveFailures, '
        'retry in 1 second');
    Timer(const Duration(seconds: 1), () {
      if (_continuous) unawaited(_startSession());
    });
  }

  void _stopRecording() {
    _log('stopRecording: timers/subscriptions teardown');
    _recycleTimer?.cancel();
    _recycleTimer = null;
    _audioSubscription?.cancel();
    _audioSubscription = null;
    _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    unawaited(_recorder.stop());
  }

  //  本应用的语音输入只有英文口令,固定使用讯飞英文听写,
  //  忽略调用方传入的 localeId
  String _languageFor(String? localeId) => 'en_us';

}
