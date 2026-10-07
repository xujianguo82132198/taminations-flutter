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

import '../settings.dart';
import 'caller_store.dart';
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

  //  停顿分段:整段只有主语/分数(核心为空)时,按规范
  //  前缀单独缓存,不与后续口令段连成乱串——下一段到来
  //  时作为前缀拼在前面(如 "home"段 + "circulate"段 →
  //  "ends circulate")
  String _segmentPrefix = '';

  //  本会话见过的全部候选文本(分段事件+收尾并集,去重):
  //  收尾 flush 只带最后一段的候选,不能覆盖中间的完整列表
  final List<String> _sessionAlts = [];

  //  流式合并窗口:口令中间停顿会被断句器切成多段,
  //  每段各自查表会错误执行两个口令(如 "split circulate one"
  //  + "the half")。一段结束后等待此窗口,无后续才作为完整
  //  口令送出;有后续则拼接后再送
  Timer? _streamMergeTimer;
  int _streamSegments = 0;

  //  模型加载去重:并发的 initialize 共享同一次加载
  Future<bool>? _initFuture;

  //  ---- 分段取样状态机(用户定义的口令结构,仅采样模式) ----
  //  按下=待命;声音开始一段;静音0.3秒收一段;最多3段
  //  (前缀/口令/后缀)。静音0.9秒=本条口令结束,重新待命
  //  (再出的声音属于新口令)。段关闭即通知上层查表,
  //  其余时间不查表
  static const _segCloseSilence = Duration(milliseconds: 300);
  static const _segArmSilence = Duration(milliseconds: 900);
  //  自适应门限:静音期跟踪底噪(慢速),开门=底噪+12dB,
  //  关门=底噪+5dB——环境噪音高低都适用(固定-42曾在
  //  底噪-40的房间里永远关不上段,命令无法完成)
  double _noiseFloorDb = -45.0;
  ///  看门狗:段开着且db悬在滞回带的累计毫秒——超过1.5秒
  ///  =底噪估低了(慢速适应逃不出坑),快速上贴当前值
  int _deadZoneMs = 0;

  ///  已收段文本(按收段顺序)。上限10段:口令无时长限制
  ///  (用户:前缀后到后缀之前都是口令,多段拼接),10段
  ///  足够容纳最长的口令结构
  final List<String> _segments = [];
  List<String> get segments => List.unmodifiable(_segments);
  bool _segInSegment = false;
  DateTime? _segLastLoudAt;
  String _segStartKnown = '';
  String _segKnownFinals = '';
  String _segKnownPartial = '';
  ///  采样期间闪现过的中间结果(去重,曾显示但可能被
  ///  修订掉的文本,如分段"left")——收尾并入候选供点选
  final List<String> _partialSeen = [];

  ///  命令完成判定计时器(连续模式:0.9秒无新final)
  Timer? _commandTimer;
  ///  命令完成(静音0.9秒判定)事件:连续模式下整条口令的
  ///  分段快照与完成计数,供三表流水线取用
  int _commandSeq = 0;
  int get commandSeq => _commandSeq;
  List<String> _lastCommandSegments = const [];
  List<String> get lastCommandSegments =>
      List.unmodifiable(_lastCommandSegments);
  ///  各段的n-best候选(与segments同序):首选丢词时
  ///  (如整拍念出,heads被吞,"heads pass ocean"在第9候选),
  ///  从候选里找回前缀
  List<List<String>> _segmentAlts = [];   //  可变(const空表clear会崩)
  List<List<String>> get segmentAlts =>
      List.unmodifiable(_segmentAlts);

  ///  命令收尾:整条口令的识别结果一次性送出
  ///  (连续模式;取代旧的1.3秒合并窗——0.9秒静音即口令边界)
  ///  会话回收:重建识别器(同语法同闸门),保持监听状态
  Future<void> _recycleSession() async {
    if (!_continuous || _disposed) return;
    try {
      _log('recycle: fresh recognizer for next command');
      _sub?.cancel();
      _sub = null;
      await musicMonitor.voskStop();
      await musicMonitor.voskStart(
          grammar: _grammarWords == null || _grammarWords!.isEmpty
              ? null : jsonEncode(_grammarWords),
          gate: Settings.silenceGate);
      _sub = musicMonitor.events.listen(_onEvent);
    } catch (e) {
      _log('recycle FAILED: $e');
    }
  }

  void _completeCommand() {
    _commandTimer?.cancel();
    _commandTimer = null;
    unawaited(_completeCommandAsync());
  }

  ///  命令收尾(异步):先冲刷(与圆钮松手同工)——流式final
  ///  与冲刷结果可能不同,末段以冲刷结果为准
  Future<void> _completeCommandAsync() async {
    _log('completeCommand called, segs=${_segments.length}');
    if (!_continuous) return;
    try {
      final json = await musicMonitor.voskFlush();
      final texts = _textsOf(json);
      if (texts.isNotEmpty) {
        final flushed = texts.first.trim();
        //  冲刷结果须是真词(unk/空不替换),且不短于原末段
        if (flushed.isNotEmpty &&
            !flushed.contains('unk') &&
            _segments.isNotEmpty &&
            flushed != _segments.last &&
            flushed.length >= _segments.last.length) {
          _log('flush修正末段: '
              '"${_segments.last}" -> "$flushed"');
          _segments[_segments.length - 1] = flushed;
        }
      }
    } catch (e) {
      _log('flush failed: $e');
    }
    final text = _segKnownText().trim();
    _lastCommandSegments = List.of(_segments);
    _segmentAlts.clear();
    //  命令完成即清段(曾跨命令累积:"heads pass ocean heads
    //  pass ocean"越滚越长)
    _segments.clear();
    _segKnownFinals = '';
    _segKnownPartial = '';
    //  命令间重启识别器(用户:麦克风识别方法应与圆钮相同)——
    //  0.9秒静音既是本条口令的尾,也是下一条的"按下":
    //  每条口令一个全新识别器,连续流的解码器状态污染与
    //  断句漂移归零,单词不再被斩碎(extend曾碎成"a courtesy")
    if (text.isNotEmpty) {
      Future.microtask(_recycleSession);
    }
    if (text.isNotEmpty) {
      _commandSeq++;
      final alts = <SpeechRecognitionAlternative>[
        SpeechRecognitionAlternative(text, 1.0),
        if (_lastCommandSegments.length == 1)
          for (final t in _sessionAlts)
            if (t != text) SpeechRecognitionAlternative(t, 1.0),
      ];
      _lastResult = SpeechRecognitionResult(alts, true);
      _log('command complete (${_lastCommandSegments.length} seg): '
          '"$text"');
      _notify();
    }
    _sessionText = '';
    _sessionAlts.clear();
    _streamSegments = 0;
    _streamMergeTimer?.cancel();
    _streamMergeTimer = null;
  }

  void _segReset() {
    _segments.clear();
    _segmentAlts.clear();
    _segInSegment = false;
    _segLastLoudAt = null;
    _segStartKnown = '';
    _segKnownFinals = '';
    _segKnownPartial = '';
    _partialSeen.clear();
  }

  ///  振幅事件驱动分段(采样与连续同一套)
  ///  segDbLog: 每2秒一条状态诊断(db/段数/静音时长)
  DateTime? _segDbLogAt;
  void _segmentStep(double db) {
    final now = DateTime.now();
    final lastLoud0 = _segLastLoudAt;
    if (_segDbLogAt == null ||
        now.difference(_segDbLogAt!).inMilliseconds > 2000) {
      _segDbLogAt = now;
      _log('segdiag db=${db.toStringAsFixed(1)} '
          'floor=${_noiseFloorDb.toStringAsFixed(1)} '
          'inSeg=$_segInSegment segs=${_segments.length} '
          'quiet=${lastLoud0 == null ? '?' : now.difference(lastLoud0!).inMilliseconds}ms');
    }
    //  底噪跟踪:**所有非语音帧**(明显低于开门线)都参与
    //  收敛,可上可下——初始估计偏差也不会死锁(曾:初始-50
    //  在底噪-40的房间永不向上收敛,开门线过低,段卡死)
    final speechT = _noiseFloorDb + 12;
    final quietT = _noiseFloorDb + 5;
    if (db < speechT - 2) {
      _noiseFloorDb = 0.9 * _noiseFloorDb + 0.1 * db;
      if (_noiseFloorDb < -60) _noiseFloorDb = -60;
      if (_noiseFloorDb > -25) _noiseFloorDb = -25;
    }
    //  看门狗:段开着且db悬在滞回带(非语音又不够"静"),
    //  累计1.5秒=底噪估低导致关门线够不到,快速上贴
    if (_segInSegment && db >= quietT && db < speechT) {
      _deadZoneMs += 100;
      if (_deadZoneMs >= 1500) {
        _noiseFloorDb = db - 5;
        if (_noiseFloorDb < -60) _noiseFloorDb = -60;
        if (_noiseFloorDb > -25) _noiseFloorDb = -25;
        _deadZoneMs = 0;
        _log('floor snapped to ${_noiseFloorDb.toStringAsFixed(1)} '
            '(was stuck)');
      }
    } else {
      _deadZoneMs = 0;
    }
    if (db > speechT) {
      _segLastLoudAt = now;
      if (!_segInSegment && _segments.length < 10) {
        _segInSegment = true;
        _segStartKnown = _segKnownText();
      }
      return;
    }
    if (db >= quietT) return;   //  滞回中间带:维持现状
    final lastLoud = _segLastLoudAt;
    if (lastLoud == null) return;
    final quietFor = now.difference(lastLoud);
    if (_segInSegment) {
      //  静音满0.3秒:收段,段文本=识别文字增量
      if (quietFor >= _segCloseSilence) {
        var text = _segKnownText();
        if (_segStartKnown.isNotEmpty && text.startsWith(_segStartKnown)) {
          text = text.substring(_segStartKnown.length);
        }
        text = text.trim();
        _segInSegment = false;
        if (text.isNotEmpty && _segments.length < 10) {
          _segments.add(text);
          _log('segment ${_segments.length} closed: "$text"');
          _notify();   //  上层(VoiceFlow)收段即查表
        }
      }
    } else if (!_sampleSession &&
        _segments.isNotEmpty &&
        quietFor >= _segArmSilence) {
      //  静音满0.9秒:本条口令结束——收尾送出后重新待命。
      //  仅连续模式(命令边界);**采样会话不做**——按钮按住
      //  即会话,慢分拍录音(do 停 so 停 do)中途不被冲掉
      //  (用户:已出现的分段结果经常被冲掉)
      _completeCommand();
      _segReset();
    }
  }

  ///  当前已知识别文字(累计final + 当前partial)
  String _segKnownText() => _segKnownFinals.isEmpty
      ? _segKnownPartial
      : (_segKnownPartial.isEmpty
          ? _segKnownFinals
          : '$_segKnownFinals $_segKnownPartial');

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
    _segReset();   //  新监听会话:分段状态清零
    _commandTimer?.cancel();
    _commandTimer = null;
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
    _segReset();   //  按下=新口令待命
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
    _commandTimer?.cancel();
    _commandTimer = null;
    _segReset();
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
    _streamMergeTimer?.cancel();
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
    _streamMergeTimer?.cancel();
    _streamMergeTimer = null;
    _streamSegments = 0;
    _sessionText = '';
    _sessionAlts.clear();
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
      _segmentPrefix = '';
      _sessionAlts.clear();
      _sub?.cancel();
      _sub = musicMonitor.events.listen(_onEvent);
      //  静音门限:圆钮(采样)与麦克风(持续监听)走完全同一
      //  声学处理(80Hz高通+能量闸门)——录记号和喊口令的
      //  音频路径必须一致,否则记号对不上还难查
      //  (用户原则:两种识别方法必须一致)
      await musicMonitor.voskStart(
          grammar: _grammarWords == null || _grammarWords!.isEmpty
              ? null : jsonEncode(_grammarWords),
          gate: Settings.silenceGate);
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
    //  分拍录音(用户发现:首拍出词后拍丢失):最终结果以
    //  分段机的**全程已知文本**为准——整个按住期间finals+
    //  partial的完整流水,不依赖vosk自己的零碎断句
    if (_sampleSession) {
      final known = _segKnownText().trim();
      if (known.length > _sessionText.trim().length) {
        debugPrint('finish: 分段全程文本更全,采用 "$known" '
            '(原 "$_sessionText")');
        _sessionText = known;
      }
    }
    //  闪现过的中间结果并入候选(曾显示又被修订的文本
    //  也保留——所见可存,不冲掉)
    for (final p in _partialSeen) {
      if (!_sessionAlts.contains(p)) _sessionAlts.add(p);
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
            if (_sampleSession) {
              _segKnownPartial = text;
              if (!_partialSeen.contains(text) &&
                  _partialSeen.length < 12) {
                _partialSeen.add(text);
              }
              //  采样显示用**全程累计文本**(finals+当前partial):
              //  中途停顿后vosk的partial会从零重起,只显示新半句
              //  像是"中断"——累计显示消除这个错觉
              final known = _segKnownText();
              if (known.trim().isNotEmpty) {
                _lastResult = SpeechRecognitionResult(
                    [SpeechRecognitionAlternative(known, 0.0)],
                    false);
                _notify();
              }
            } else {
              _lastResult = SpeechRecognitionResult(
                  [SpeechRecognitionAlternative(text, 0.0)], false);
              _notify();
            }
          }
        }
        break;
      case 'vosk_final':
        //  断句自动给出的最终结果;采样期间累计拼接,
        //  避免多词口令只取到前半段(带全部候选供上层挑选)
        final texts = _textsOf(event.text);
        _log('final: $texts');
        if (texts.isNotEmpty) {
          //  分段已知文本:采样与连续都累积(命令完成事件的
          //  文本来源——曾只给采样,连续模式命令永远空文本,
          //  流水线不跑)
          _segKnownFinals = _segKnownFinals.isEmpty
              ? texts.first : '$_segKnownFinals ${texts.first}';
          _segKnownPartial = '';
          if (_continuous) {
            //  连续模式:**vosk断句即段**(识别器的final天然
            //  按停顿切拍,比振幅门限稳得多);0.9秒无新final
            //  =口令结束,命令完成事件送出
            _segments.add(texts.first);
            _segmentAlts.add(texts);
            _sessionText = _sessionText.isEmpty
                ? texts.first : '$_sessionText ${texts.first}';
            if (_streamSegments == 0) {
              _sessionAlts
                ..clear()
                ..addAll(texts);
            }
            _streamSegments++;
            _commandTimer?.cancel();
            _commandTimer = Timer(_segArmSilence, _completeCommand);
            _notify();   //  段到达即通知(增量三表组装依赖此通知)
          } else {
            //  采样:同一轮内分段**原始**拼接、候选累积。
            //  不再做前缀段的规范形改写(用户原则:记号是
            //  识别器指纹,录什么存什么,改写交给口令员掌握)
            final seg = texts.first;
            _sessionText = _sessionText.isEmpty
                ? seg : '$_sessionText $seg';
            for (final t in texts) {
              if (!_sessionAlts.contains(t)) _sessionAlts.add(t);
            }
            _lastResult = SpeechRecognitionResult(
                [for (final t in _sessionAlts)
                  SpeechRecognitionAlternative(t, 1.0)],
                true);
          }
          _notify();
        }
        break;
      case 'speech_amplitude':
        if (event.level != null) {
          _lastLevel = event.level!;
          //  振幅驱动分段(0.3s收段):仅采样模式(录音显示);
          //  连续模式的分段由vosk断句final驱动(振幅门限在
          //  真实环境噪音下不稳,识别器断句天然按停顿切拍)
          if (_sampleSession && _isListening) {
            _segmentStep(event.level!);
          }
          if (_soundLevel) _notify();
        }
        break;
      case 'speech_error':
        //  采集线程死亡(系统长时间录音后回收/异常):
        //  干净复位监听状态,麦克风钮可再次启动,不卡死
        _lastError = 'native capture failed';
        if (_isListening) {
          _log('speech_error -> reset listening state');
          _sub?.cancel();
          _sub = null;
          musicMonitor.voskStop();
          _isListening = false;
          _continuous = false;
        }
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
