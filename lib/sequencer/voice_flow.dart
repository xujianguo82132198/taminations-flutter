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

import 'vosk_speech_to_text.dart'
    show SpeechRecognitionAlternative, SpeechRecognitionResult;

import '../dance_model.dart';
import '../extensions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'caller_store.dart';
import 'music_monitor.dart';
import 'dual_speech_to_text.dart';

///  口令员语音呼叫全流程(单例,存活于整个应用期间)
///
///  流程状态放在 widget 树之外的原因:输入行所在的
///  SequenceFrame 会因键盘开合等布局变化被销毁重建,
///  若状态存在 State 里,流程会随之中断。
///
///  状态机:
///    idle      - 未开始(或已结束)
///    calling   - 语音呼叫中(音乐功能未开启,小人按系统原设定节拍跳)
///    awaiting  - 音乐功能开启,提示"请播放背景音乐",等监听到音乐
///    detecting - 音乐已出现,麦克风按钮蓝色闪烁,后台节拍检测
///    ready     - 节拍已显示并接管 Dance Speed,语音识别进行中
class VoiceFlow extends ChangeNotifier {

  VoiceFlow._() {
    //  音乐监测事件监听:音乐按钮独立于语音流程,
    //  不能依赖 start() 才挂载
    _musicSub ??= musicMonitor.events.listen(_onEvent);
    musicMonitor.sendAliveProbe();
    //  始终持有语音识别器(Only模式隐藏输入行时PTT也能工作)
    speech ??= DualSpeechProvider();
  }
  static final VoiceFlow instance = VoiceFlow._();

  final musicMonitor = MusicMonitor();
  StreamSubscription<MusicEvent>? _musicSub;
  Timer? _orphanTimer;

  ///  当前输入行 State 注入的语音识别器(输入行重建时刷新)
  DualSpeechProvider? speech;

  ///  自动语音测试用的临时识别器(页面未打开时自建)
  DualSpeechProvider? _testSpeech;

  ///  输入行注入的"登录并打开映射表"回调(音乐按钮在未登录时
  ///  按下也需要走登录流程)
  Future<bool> Function()? loginRequest;

  ///  idle / awaiting / detecting / ready / calling
  String phase = 'idle';

  //  ---- 音乐节拍(独立于语音流程,常显按钮控制) ----
  ///  节拍正在生效(舞者按音乐节拍跳)
  bool musicDancing = false;
  ///  已取样的节拍缓存:再次按下直接采用,不必重新取样
  int cachedBpm = 0;

  ///  等待音乐的超时定时器(半分钟没听到音乐自动取消)
  Timer? _musicAwaitTimer;

  ///  音乐功能(播放提示/节拍检测/节拍接管/停止检测)开关。
  ///  默认关闭:登录后直接语音识别,动态小人按系统原设定节拍跳。
  ///  屏幕上的音乐按钮可随时开/关。
  bool musicEnabled = false;

  ///  检测到的节拍(每分钟拍数)
  int bpm = 0;

  ///  语音识别期间音乐是否已停止(等待重播后重新检测)
  bool musicStoppedDuringCall = false;

  ///  本机播放监测是否已见过"正在播放"(外部音源时不误报停止)
  bool playbackWasActive = false;


  ///  表退出标志:抑制 onDidRemovePage 的页面跳转
  ///  (flow.stop 引起重建时可能误触发页面移除回调)
  bool suppressBackNav = false;

  ///  最近一次错误('mic' 麦克风不可用,'speech' 识别不可用),UI 负责提示
  String? lastError;

  //  ---- 口令员信息(随流程存续,输入行重建不影响) ----
  //  ---- PTT 采样(按下说话/抬起出结果,用于映射表口令采集) ----
  ///  按住采样中(按钮按下)
  bool pttActive = false;

  //  ---- 分段取样(用户定义的口令结构) ----
  //  按下待命→声音起段→静音0.3秒收段;每段关闭查一次表
  //  (全程最多3次:前缀→口令→后缀),组合不冲掉,逐段显示
  ///  目录经验词:本口令员目录内**所有表**的记号词+口令
  ///  读法词(开表时收集)。采样语法纳入它们——Words 表学
  ///  的音节(do/so/doe)在 MS 表录音时也可解码
  Set<String> _dirWords = {};
  Set<String> _allDirWords = {};

  ///  分段检索门槛(先设0.5)
  static const sampleLookupThreshold = 0.5;
  ///  累计组合显示(合格结果累加,不冲掉)
  String dictationSegmentText = '';
  ///  已查表的段数
  int _segProcessedCount = 0;
  ///  第1段是否为前缀(否则它本身就是口令)
  bool _segFirstWasPrefix = false;

  ///  按下:开始单轮采样识别。
  ///  返回是否已启动(未登录或麦克风被音乐监测占用时不能启动)
  bool startSample() {
    if (!isActive) return false;   //  需先登录(选择映射表)
    if (phase == 'detecting' || phase == 'awaiting') return false;
    pttActive = true;
    //  同步 cancel 清理旧会话(防止 _client 残留导致 sample 被拒),
    //  紧接 sample 重置 _sampleSession=true,时序安全
    speech?.cancel();
    //  Only 采表:限定口令词表解码(口音发音吸附到标准口令词汇,
    //  大幅提高识别准确率);流式喊口令仍为自由识别。
    //  Words 关键词表:当前行是单词时用**隔离语法**——词表
    //  只有该词(+unk),解码器无联想可选,单音节结果必然可
    //  采集([unk]=未念到位,继续纠正;教口令员念到被听清)
    //  行级语法:录哪行,词表=该行口令的词+目录经验词。
    //  Words表单词行=严格隔离(词+unk);其他表=行词+经验词
    //  +unk——大词表联想被排除(单音节不再被"the"类高频词
    //  抢走),录音与喊口令仍同表同源
    //  录音语法=喊口令语法(用户铁律:识别方法必须一致——
    //  行级窄语法录出的记号,喊口令的宽语法永远产不出来,
    //  extend录成"extend"喊时被"and"抢走即此病)。
    //  Words校准表除外:隔离语法是校准的本意
    final row0 = currentDictationRow;
    if (row0 != null && _isWordsTable) {
      final w = row0.standardCall.trim().toLowerCase();
      if (w.isNotEmpty && !w.contains(' ')) {
        //  单词行 = 该词 + 已校准词库(用户方案:分段识别后
        //  接起来——先校准音节(s/pit),再分段念"s停plit",
        //  两拍各自落位拼接成"s pit"存入;严格隔离曾使
        //  拍子无法解码)
        final g = <String>[w, ...?_dirWords, '[unk]'];
        speech?.setSampleGrammar(g);
        debugPrint('word grammar for "$w" '
            '(+${_dirWords.length} calibrated)');
      } else {
        speech?.setSampleGrammar(_onlyTableWords());
      }
    } else {
      final callG = <String>{
        ...?_onlyTableWords(),
        ..._allDirWords,
      };
      speech?.setSampleGrammar([...callG, '[unk]']);
      debugPrint('sample grammar = call grammar '
          '(${callG.length} words)');
    }
    dictationPartial = '';
    dictationCandidates = [];
    dictationSegmentText = '';
    dictationRawText = '';
    _segProcessedCount = 0;
    _segFirstWasPrefix = false;
    conflictPending = false;
    //  开实时中间结果:边念边显示,反馈更快
    speech?.sample(localeId: 'en_US', partialResults: true);
    //  Only 模式:结果直接在 VoiceFlow 处理(输入行隐藏时 build 不跑)
    if (onlyMode)
      speech?.addListener(_onSampleResult);
    Future.microtask(() => _notify());
    return true;
  }

  ///  采表语法:当前表全部口令的**单词表**(词循环)。
  ///  只约束词汇范围,不强制组成完整口令——避免解码器
  ///  把短促发音"联想补全"成整条口令(如 step -> Scoot back),
  ///  保证"同一人多次读同一口令,识别结果相近"这一映射表
  ///  设计前提成立。
  List<String>? _onlyTableWords() {
    final t = callerTable;
    if (t == null) return null;
    final words = <String>{};
    for (final r in t.rows) {
      //  统一用读法形式(1-1/2 -> one and a half 等)
      final s = CallerTable.spokenForm(r.standardCall);
      for (final w in s.split(RegExp(r' +'))) {
        if (w.isNotEmpty) words.add(w);
      }
      //  已录记号的词也进语法(口令员自己的读法变体可解码)
      for (final token in r.recognized.split('|')) {
        for (final w in token.toLowerCase().split(RegExp(r' +'))) {
          if (w.isEmpty || w == 'unk' || w == '[unk]') continue;
          words.add(w);
        }
      }
    }
    //  目录经验词并入(Words表音节等跨表可解码)
    words.addAll(_dirWords);
    if (words.isEmpty) return null;
    return [...words, '[unk]'];
  }

  ///  抬起:收尾给出结果(结果在 hasResults 中被取走)
  Timer? _sampleTimeout;

  void endSample() {
    if (!pttActive) return;
    speech?.stop();
    _notify();
    //  8秒无结果:超时重置并提示(防卡死)
    _sampleTimeout?.cancel();
    _sampleTimeout = Timer(const Duration(seconds: 8), () {
      if (pttActive) {
        debugPrint('Sample timeout: resetting');
        pttActive = false;
        dictationText = '';
        final err = speech?.lastError ?? '';
        lastError = err.contains('11201')
            ? 'licc_quota'   //  讯飞额度用完
            : 'timeout';
        _notify();
      }
    });
  }

  ///  Only 模式采样结果处理:识别文字存入 dictationText
  void _onSampleResult() {
    final s = speech;
    if (s == null || !pttActive) return;
    //  ---- 分段取样:段关闭即查表(最多3次),组合累加不冲掉 ----
    //  (先于 hasResults 判定——收段时可能尚无中间结果)
    final segs = s.segments;
    if (segs.length < _segProcessedCount) {
      //  静音0.9秒后provider重新待命:新口令开始,组合清零
      _segProcessedCount = 0;
      _segFirstWasPrefix = false;
      dictationSegmentText = '';
    }
    var segChanged = false;
    while (_segProcessedCount < segs.length) {
      _processSampleSegment(_segProcessedCount, segs[_segProcessedCount]);
      _segProcessedCount++;
      segChanged = true;
    }
    if (segChanged) _notify();
    if (!s.hasResults) return;
    final result = s.lastResult;
    //  中间结果:实时更新显示(不作确认内容)
    if (!result!.finalResult) {
      final p = result.recognizedWords.trim();
      if (p != dictationPartial) {
        dictationPartial = p;
        _notify();
      }
      return;
    }
    //  只在采样会话完全结束后取结果:识别器在口令中间停顿时
    //  会先交出一段"最终结果"(如 "u turn"),不能当完整结果用,
    //  否则后面的词(back)全部丢失
    if (s.isListening) return;
    if (result == null || !result.finalResult) return;
    //  记号原则:默认取识别器自己的第一候选(原始听法),
    //  不做向口令靠拢的"联想纠正"——同一发音次次出同一记号,
    //  映射表负责"记号->口令"的对应;其余候选列出供点选
    String text = '';
    //  全部候选(去重,去 unk,最多 5 条)供点选;
    //  text 为第一候选(原始记号)
    final candidates = <String>[];
    for (final alt in result.alternates) {
      final t2 = alt.recognizedWords
          .replaceAll(RegExp(r'[^\w\s]'), ' ').trim();
      if (t2.isEmpty || t2 == 'unk' || t2 == '[unk]') continue;
      if (!candidates.contains(t2)) candidates.add(t2);
      if (candidates.length >= 8) break;
    }
    if (text.isEmpty && candidates.isNotEmpty) text = candidates.first;
    //  候选中恰有与本行标准口令一致者:直接选它为默认
    //  (识别出字面正确口令时无需人工点选)。比对用结构化
    //  分解:前缀(主语)可有可无,核心/左右/后缀须一致
    //  ——光标在 "Square Thru 2" 而喊出 "heads square
    //  thru two" 时也能自动选中
    final curRow = currentDictationRow;
    if (curRow != null) {
      final spoken =
          CallerTable.spokenForm(curRow.standardCall).toLowerCase();
      final plain =
          curRow.standardCall.toLowerCase()
              .replaceAll(RegExp(r'[^a-z ]'), '')
              .replaceAll(RegExp(r' +'), ' ').trim();
      final rowDec = CallerTable.decomposeCall(curRow.standardCall);
      final rowSig = '${rowDec.$2}|${rowDec.$3.join(' ')}'
          '|${rowDec.$4.join(' ')}';
      //  先找主语也一致(head≡heads)的候选;没有再接受
      //  主语不同但核心/左右/后缀一致的(跟哪个主语接近
      //  就采用哪个——人类就是这样做的)
      CallerRow? bestRow2;
      for (final pass in [0, 1]) {
        for (final c in candidates) {
          final cl = c.toLowerCase();
          if (cl == spoken || cl == plain) {
            text = c;
            debugPrint('exact-call candidate: "$c"');
            break;
          }
          final cd = CallerTable.decomposeCall(cl);
          final sig =
              '${cd.$2}|${cd.$3.join(' ')}|${cd.$4.join(' ')}';
          if (sig != rowSig) continue;
          final prefixOk = CallerTable.samePrefix(cd.$1, rowDec.$1);
          if (pass == 0 && !prefixOk) continue;
          text = c;
          debugPrint('exact-call candidate(pass$pass): "$c"');
          break;
        }
        if (text.isNotEmpty) break;
      }
      //  主语一致的候选存在时,优先光标跳到该主语行
      //  (跟哪个主语接近就调用哪个)
    }
    _sampleTimeout?.cancel();
    //  [unk]=语法没匹配上(读音与所有口令都太远):不写入,
    //  显示框提示没听清,采样状态复位以便再按重念
    if (text.isEmpty || text == 'unk' || text == '[unk]') {
      debugPrint('Only result: [unk] -> not accepted');
      dictationText = '';
      pttActive = false;
      s.removeListener(_onSampleResult);
      s.clearResults();
      lastError = 'not_heard';
      _notify();
      Future.delayed(const Duration(seconds: 3), () {
        if (lastError == 'not_heard') {
          lastError = null;
          _notify();
        }
      });
      return;
    }
    //  所见即所存(用户原则):黄框显示原始识别文本,
    //  存库同一份——记号是识别器的指纹,任何改写都会
    //  破坏查表前提(改写过的记号在麦克风识别时全对不上)
    dictationRawText = text;
    debugPrint('Only result: "$text" candidates=$candidates');
    //  分解诊断:每个候选的前缀/核心/后缀
    for (final c in candidates.take(3)) {
      final d = CallerTable.decomposeCall(c);
      debugPrint('  decomp "$c": prefix=[${d.$1.join(' ')}] '
          'core=[${d.$3.join(' ')}] suffix=[${d.$4.join(' ')}]');
    }
    lastError = null;
    dictationText = text;
    dictationCandidates = candidates.length > 1 ? candidates : [];
    pttActive = false;
    s.removeListener(_onSampleResult);
    s.clearResults();
    _notify();
  }

  ///  记号接龙(用户方案:先识别"wheel",光标移到最前,
  ///  再读"flutter"构成整个记号):新识别的文本拼到该行
  ///  已有记号的前面或后面,一次一笔,最后整词验证
  Future<void> mergeDictation({required bool front}) async {
    final t = callerTable;
    final row = currentDictationRow;
    if (t == null || row == null) return;
    final part = dictationRawText.isNotBlank
        ? dictationRawText : dictationText;
    if (part.isBlank || row.recognized.isBlank) return;
    final merged = front
        ? '$part ${row.recognized}'
        : '${row.recognized} $part';
    await t.updateRow(row.seq, recognized: merged, sort: false);
    debugPrint('记号接龙: ${row.recognized} + $part '
        '${front ? "(前接)" : "(后接)"} -> "$merged"');
    dictationText = '';
    dictationRawText = '';
    dictationCandidates = [];
    conflictPending = false;
    _notify();
  }

  ///  采样结果已消费
  void consumeSample() {
    pttActive = false;
    _notify();
  }

  ///  分段取样:第i段收段后的查表与组合(用户定义过程)。
  ///  段1=前缀(可无,无则它就是口令),段2=口令,段3=后缀;
  ///  每段查一次表(全程最多3次),合格结果累加组合,不冲掉
  void _processSampleSegment(int i, String text) {
    final table = callerTable;
    if (table == null) return;
    debugPrint('seg#$i "$text" -> lookup');
    if (i == 0) {
      //  查表优先:主语映射归表管理(多归一),段1先在表内
      //  检索——命中纯主语行即为前缀;命中口令行则本段就是
      //  口令(同一次查表结果直接用,不重复查)。未命中再退
      //  回内置归一基线(表里没有主语行时)
      final r0 = table.lookupForSample(text);
      if (r0.hit != null && r0.error <= sampleLookupThreshold) {
        final rd = CallerTable.decomposeCall(r0.hit!.standardCall);
        if (rd.$3.isEmpty && rd.$1.isNotEmpty) {
          //  纯主语行:前缀,多归一命中的规范主语
          _segFirstWasPrefix = true;
          dictationSegmentText = r0.hit!.standardCall;
          debugPrint('seg#0 prefix(table): "${r0.hit!.standardCall}" '
              '(err=${r0.error.toStringAsFixed(3)})');
          return;
        }
        //  口令行:无前缀口令,本段即口令
        _segFirstWasPrefix = false;
        final core = rd.$3.join(' ');
        dictationSegmentText = rd.$2 ? 'left $core' : core;
        debugPrint('seg#0 command(table): "$dictationSegmentText"');
        return;
      }
      final d = CallerTable.decomposeCall(text);
      //  内置基线:整段只有主语/分数词=前缀段,归一显示
      _segFirstWasPrefix = d.$3.isEmpty && d.$1.isNotEmpty;
      if (_segFirstWasPrefix) {
        dictationSegmentText = d.$1.join(' ');
        debugPrint('seg#0 prefix(baseline): "${dictationSegmentText}"');
        return;
      }
      _segLookupCommand(text);
      return;
    }
    if (i == 1 && _segFirstWasPrefix) {
      _segLookupCommand(text);
      return;
    }
    //  后缀段:与前面的组合一起进表匹配(查表#3)
    final d = CallerTable.decomposeCall(text);
    final suffixWords = <String>[...d.$4];
    //  Roll/Spread/Sweep 等后缀口令词在分解里留在核心,归入后缀
    if (d.$3.isNotEmpty &&
        d.$3.every((w) => CallerTable.suffixCallWords.contains(w))) {
      suffixWords.insertAll(0, d.$3);
    }
    //  纯读法分数段(one and a half)分解为主语词:同样作后缀
    if (suffixWords.isEmpty && d.$3.isEmpty && d.$1.isNotEmpty) {
      suffixWords.addAll(d.$1);
    }
    if (suffixWords.isEmpty) {
      debugPrint('seg#$i: not a suffix, ignored');
      return;
    }
    final combined =
        '$dictationSegmentText ${suffixWords.join(' ')}'.trim();
    final r = table.lookupForSample(combined);
    debugPrint('seg#$i suffix match: err=${r.error.toStringAsFixed(3)} '
        'row=${r.hit?.standardCall}');
    dictationSegmentText = (r.hit != null &&
            r.error <= sampleLookupThreshold)
        ? r.hit!.standardCall
        : combined;
  }

  ///  口令段查表(门槛 sampleLookupThreshold):命中行的
  ///  核心口令(含Left标记)拼入组合;不合格则组合保持不变
  void _segLookupCommand(String text) {
    final table = callerTable;
    if (table == null) return;
    final r = table.lookupForSample(text);
    debugPrint('seg command lookup: err=${r.error.toStringAsFixed(3)} '
        'row=${r.hit?.standardCall}');
    if (r.hit == null || r.error > sampleLookupThreshold) return;
    final rd = CallerTable.decomposeCall(r.hit!.standardCall);
    final core = rd.$3.join(' ');
    final withLeft = rd.$2 ? 'left $core' : core;
    dictationSegmentText = dictationSegmentText.isEmpty
        ? withLeft
        : '$dictationSegmentText $withLeft';
  }

  ///  最近一次语音查表的候选记录与误差(供界面居中突出显示;
  ///  候选是顺序查找中误差最小的记录,无论是否命中)
  CallerRow? lastCandidate;
  double lastCandidateError = 1.0;

  ///  注入回车键(语音识别输出完成后发送,与手动键入按回车一致)
  Future<void> sendEnterKey() => musicMonitor.sendEnterKey();

  ///  对识别句做映射表顺序查找(详见 CallerTable.lookupSequential)。
  ///  命中返回该记录,未命中返回 null;两种情况都记录候选供显示。
  CallerRow? lookupInTable(String sentence) {
    final table = callerTable;
    if (table == null) return null;
    final result = table.lookupSequential(sentence);
    lastCandidate = result.candidate;
    lastCandidateError = result.error;
    _notify();
    return result.hit;
  }

  ///  当前口令员姓名
  String callerName = '';

  ///  当前口令员密码(预留后续身份校验使用)
  // ignore: unused_field
  String _callerPassword = '';
  set callerPassword(String v) => _callerPassword = v;

  ///  当前口令员的映射表(登录确认后打开)
  CallerTable? callerTable;

  ///  打开(或新建)口令员映射表,记录变化会转发通知 UI 刷新
  ///  表退出:复位到进入时的画面状态,不影响原有功能。
  ///  停语音识别、清采表/候选/提示状态、解除表监听、
  ///  取消音乐取样(音乐生效中除外,其为独立功能)
  void exitTable() {
    debugPrint('exitTable: enter phase=$phase table=${callerTable?.callerName}');
    if (phase == 'awaiting' || phase == 'detecting')
      _cancelMusicSampling();
    speech?.cancel();
    pttActive = false;
    pendingRecord = null;
    lastCandidate = null;
    lastError = null;
    dictationText = '';
    dictationPartial = '';
    dictationCandidates = [];
    dictationSegmentText = '';
    dictationRawText = '';
    _segProcessedCount = 0;
    _segFirstWasPrefix = false;
    tokenCollisionRows = [];
    collisionNoticeShown = false;
    dictationSeqOverride = null;
    //  三表流水线复位
    tableFlags = '';
    prefixResult = '';
    callResult = '';
    suffixResult = '';
    assembledCall = '';
    _lastCommandSeq = 0;
    _prefixTable = null;
    _suffixTable = null;
    callerTable?.removeListener(_onTableChanged);
    callerTable = null;
    tableMode = false;
    panelMinimized = false;
    phase = 'idle';
    _notify();
    debugPrint('exitTable: done');
  }

  Future<CallerTable> openCallerTable(String name) async {
    //  防空表(用户要求:不能出现空表):新建表名必须带种库
    //  后缀(_Prefix_Only/_Sufix_Only/级别_Only,打开时自动
    //  种库),裸名且不存在则拒绝——不再凭空建空表
    final seedable = RegExp(
            r'^(Prefix|Sufix|Words|ms|plus|a1|a2|c1|c2|c3a|c3b)_Only$')
        .hasMatch(name.split('/').last);
    //  裸口令员名(无斜杠)→ 自动开其 ms 合并表(若已合并)
    if (!name.contains('/')) {
      if (await CallerTable.exists('$name/ms')) {
        return openCallerTable('$name/ms');
      }
    }
    if (!seedable && !await CallerTable.exists(name)) {
      throw Exception('表 "$name" 不存在。\n'
          '请用口令员目录形式:\n'
          '口令员名/Prefix_Only · 口令员名/Sufix_Only · '
          '口令员名/ms_Only\n'
          '(建表画面输入口令员姓名,选类型即自动生成)');
    }
    final old = callerTable;
    if (old != null)
      old.removeListener(_onTableChanged);
    final table = await CallerTable.open(name);
    //  Only 表打开时自动清理高于本级的口令
    //  (防止测试时误加的高级口令经合并带到其他级别)
    final m = RegExp(r'_(ms|plus|a1|a2|c1|c2|c3a|c3b)_Only$')
        .firstMatch(name);
    if (m != null) {
      await table.purgeAboveLevel(m.group(1)!);
      //  级别采录表建表:空表时插入该级别核心口令
      //  (不含子口令,MS 约84条)每条3行(3归1)
      final seededLv = await table.seedLevelRows(m.group(1)!);
      if (seededLv > 0)
        debugPrint('seedLevelRows(${m.group(1)}): '
            '${seededLv ~/ 3} calls x3 = $seededLv rows');
    }
    //  采录库表(用户定义的建表过程):*_Prefix_Only 插入
    //  前缀库、*_Sufix_Only 插入后缀库、*_Words_Only 插入
    //  关键词库(软件内置公共库,读音校准用),每条拷贝3行
    //  (3归1);级别表(ms等)不再种主语行
    final tp = name.split('/').last;
    final libKind = tp == 'Prefix_Only'
        ? 'prefix'
        : (tp == 'Sufix_Only'
            ? 'suffix'
            : (tp == 'Words_Only' ? 'words' : ''));
    if (libKind.isNotEmpty) {
      final n = await table.seedLibraryRows(libKind: libKind);
      if (n > 0)
        debugPrint('seedLibraryRows($libKind): $n rows (3归1)');
    }
    //  记号碰撞体检(所有表,合并表更关键——喊口令直接查它):
    //  口令不同而记号相同的行,亮出行号提示重新识别
    final cols = table.findTokenCollisions();
    tokenCollisionRows = [
      for (final c in cols)
        '第${c.$1}行「${c.$2}」↔ 第${c.$3}行「${c.$4}」'
        '(记号:${c.$5})'
    ];
    collisionNoticeShown = false;
    if (tokenCollisionRows.isNotEmpty)
      debugPrint('token collisions: ${tokenCollisionRows.length}');
    //  诊断:全表转储(排查记号与所闻差异)。
    //  记号必须是识别器原始输出;此转储用于比对"存的记号"
    //  与"麦克风实际听到"是否同一形态
    debugPrint('TABLE DUMP ${table.callerName} '
        '(${table.rows.length} rows)');
    for (final r in table.rows) {
      debugPrint('ROW ${r.seq}|${r.recognized}|${r.standardCall}');
    }
    //  两套词池:
    //  _dirWords=Words表(校准音节库,行级录音语法用,池小稳指纹)
    //  _callWords=全目录所有表的词+记号(喊口令语法用——
    //   前缀表heads/后缀表数字都要能解码,流水线三表才查得着)
    _dirWords = {};
    _allDirWords = {};
    try {
      final dir = name.split('/').first;
      final prefs = await SharedPreferences.getInstance();
      for (final n in CallerTable.listTableNames(prefs)) {
        if (!n.startsWith('$dir/')) continue;
        final lastSeg = n.split('/').last;
        final isWordsTable =
            lastSeg == 'Words_Only' || lastSeg == 'Words';
        final t = n == name ? table : await CallerTable.open(n);
        for (final r in t.rows) {
          final spokenWs = CallerTable.spokenForm(r.standardCall)
              .split(RegExp(r' +'))
              .where((w) => w.isNotEmpty);
          final tokenWs = r.recognized
              .split('|')
              .expand((token) => token.toLowerCase()
                  .split(RegExp(r' +')))
              .where((w) =>
                  w.isNotEmpty && w != 'unk' && w != '[unk]');
          _allDirWords.addAll(spokenWs);
          _allDirWords.addAll(tokenWs);
          if (isWordsTable) {
            _dirWords.addAll(spokenWs);
            _dirWords.addAll(tokenWs);
          }
        }
      }
      debugPrint('词池: 行级=${_dirWords.length} '
          '喊口令=${_allDirWords.length}');
    } catch (e) {
      debugPrint('目录经验词收集失败: $e');
    }
    callerTable = table;
    table.addListener(_onTableChanged);
    _notify();
    return table;
  }

  void _onTableChanged() => _notify();

  //  ---- 记录初始化 ----
  //  语音识别句在映射表中无近似记录时:插入一条新记录
  //  (识别句放第二列),暂停识别,由口令员补全第三列:
  //  键盘输入部分口令,或点击"Calls"到其页面选择——
  //  选中的口令先填入输入行,口令员可继续键入修改,
  //  直到口令执行正确,方把整个口令一起存入记录,
  //  并恢复语音识别。
  ///  待补全的新记录(null 表示当前没有进行中的记录初始化)
  CallerRow? pendingRecord;

  //  ---- Only 表采表模式(建表朗读录入) ----
  ///  Only 采表:待确认的识别文字(识别结果暂存,
  ///  "识别确认"后写入表中)
  ///  语音识别句(黄框显示,规范形仅供人看)
  String dictationText = '';

  ///  原始识别文本(未改写)——存库用这个:记号是识别器
  ///  指纹,存改写文本会破坏"同一人多次读同一口令识别
  /// 结果相近"的查表前提
  String dictationRawText = '';

  ///  采样中的实时中间结果(边念边显示,只作提示)
  String dictationPartial = '';

  ///  采样结束的候选识别结果(供口令员点选;
  ///  第一个为自动挑选的默认值)
  List<String> dictationCandidates = [];

  ///  冲突决断待定中(黄框再点一次=强制存入);
  ///  成功存入或新采样后清除,不随提示超时消失
  bool conflictPending = false;

  ///  口令员从候选中点选一条作为采表结果
  void chooseDictation(String text) {
    //  所见即所存:显示与存库都是原始识别文本
    dictationRawText = text;
    dictationText = text;
    dictationCandidates = [];
    conflictPending = false;
    _notify();
  }

  ///  增加行(用户定义):找到当前高亮行,在其**上方**插入
  ///  一个全空行(两列皆空,标准口令列留给口令员键入),
  ///  光标跳到新行——位置就在眼前,不用滚动寻找。
  ///  无高亮行时插到表首。返回新行(供口令编辑画面)
  Future<CallerRow?> addReadingRow() async {
    final t = callerTable;
    if (t == null || !onlyMode) return null;
    final cur = currentDictationRow;
    if (cur == null) return null;   //  无高亮行:界面询问位置
    return addReadingRowAt(cur.seq);
  }

  ///  在指定行之上插入全空行(增行功能的实际执行)
  Future<CallerRow?> addReadingRowAt(int aboveSeq) async {
    final t = callerTable;
    if (t == null) return null;
    final nr = await t.insertRowAbove(aboveSeq);
    dictationSeqOverride = nr.seq;
    dictationText = '';
    dictationRawText = '';
    _notify();
    return nr;
  }

  ///  清理全表后复位采表状态(行号已变)
  void afterTableCleanup() {
    dictationSeqOverride = null;
    dictationText = '';
    dictationRawText = '';
    dictationCandidates = [];
    conflictPending = false;
    _notify();
  }

  //  ---- 三表流水线(用户定义的喊口令过程) ----
  //  0.9秒静音=口令边界;0.3秒空隙分段;最长段=口令;
  //  前缀进Prefix非Only表(P),口令进当前合并表(_C),
  //  后缀进Sufix非Only表(_S);三结果分别存储防冲掉,
  //  最后组合送输入行加回车
  ///  进表标志显示块:P/_C/_S 递加(如"P_C_S")
  String tableFlags = '';
  ///  三个映射结果分别存储(防冲掉)
  String prefixResult = '';
  String callResult = '';
  String suffixResult = '';
  ///  组合完成的整条口令(输入行执行后由 consumeAssembled 清)
  //  ---- 语音Input模式(用户设计:圆钮+输入框) ----
  //  按下圆钮→清零输入框→说话→0.3秒断句→每句先查PSfix
  //  再查口令表→结果累加入输入框(替换最后一笔,不冲更早的)
  //  抬起→等口令员自己按回车
  ///  Input模式按钮按下中
  bool pttInputActive = false;
  ///  已确认的累加文本(不冲掉)
  String inputAccumulated = '';
  ///  当前待替换的最后一笔
  String inputPending = '';
  ///  当前句子的分段累积
  final List<String> _inputSegParts = [];

  ///  Input模式:按下→清零输入框,开始PTT采样
  bool startInputSample() {
    if (!isActive) return false;
    if (phase == 'detecting' || phase == 'awaiting') return false;
    pttInputActive = true;
    speech?.cancel();
    speech?.setSampleGrammar(_inputGrammar());
    dictationPartial = '';
    inputAccumulated = '';
    inputPending = '';
    _inputSegParts.clear();
    speech?.sample(localeId: 'en_US', partialResults: true);
    speech?.addListener(_onInputResult);
    Future.microtask(() => _notify());
    return true;
  }

  ///  Input模式:抬起→收尾,输入框保留累加结果
  void endInputSample() {
    if (!pttInputActive) return;
    speech?.removeListener(_onInputResult);
    speech?.cancel();
    pttInputActive = false;
    dictationPartial = '';
    _notify();
  }

  ///  Input模式语法:当前表+全目录(与喊口令一致)
  List<String>? _inputGrammar() {
    final callG = <String>{
      ...?_onlyTableWords(),
      ..._allDirWords,
    };
    return [...callG, '[unk]'];
  }

  ///  Input模式:输入框内容 = 累加+待替换
  String get inputBoxText =>
      [inputAccumulated, inputPending]
          .where((t) => t.isNotBlank)
          .join(' ');

  ///  Input模式结果处理
  void _onInputResult() {
    final s = speech;
    if (s == null || !pttInputActive || !s.hasResults) return;
    final result = s.lastResult;
    if (!result!.finalResult) {
      final p = result.recognizedWords.trim();
      if (p != dictationPartial) {
        dictationPartial = p;
        _notify();
      }
      return;
    }
    //  每个final都是一个"语句"(实时处理,不等松开)
    _processInputSentence(result);
  }

  ///  处理一个"语句"(0.3秒断句=一句话)
  void _processInputSentence(SpeechRecognitionResult result) {
    var text = result.recognizedWords.trim();
    if (text.isEmpty) return;
    //  先查PSfix,再查口令表
    String? matched;
    final psfix = _psfixTable;
    if (psfix != null && psfix.rows.isNotEmpty) {
      final r = psfix.lookupSequential(text);
      if (r.hit != null && r.error <= 0.45) {
        matched = r.hit!.standardCall;
      }
    }
    if (matched == null) {
      final act = callerTable;
      if (act != null) {
        final r = act.lookupSequential(text);
        if (r.hit != null && r.error <= 0.45) {
          matched = r.hit!.standardCall;
        }
      }
    }
    //  查到:用标准口令;查不到:用原始听法(口令员自己改)
    final display = matched ?? text;
    //  替换最后一笔(不冲更早的)
    inputPending = display;
    debugPrint('语音Input: "$text" -> "$display" '
        '(accumulated="$inputAccumulated")');
    _notify();
  }

  ///  Input模式:回车确认,把pending并入accumulated
  void confirmInputPending() {
    if (inputPending.isNotBlank) {
      inputAccumulated = inputBoxText;  //  当前全部内容→accumulated
      inputPending = '';
    }
  }

  ///  Input模式:结果通知→输入框实时更新(通过listener)
  void _pushToInputBox() {
    //  通知UI更新(输入框的controller由frame管理,
    //  通过notifyListeners让frame重建时写入)
  }

  ///  最近一次麦克风命令的识别文本(供「存」钮存入表行)
  String lastMicText = '';
  ///  递归识别过程(用户要看到):辅音家族导航的逐步结果
  List<String> recursiveSteps = [];
  String assembledCall = '';
  int _lastCommandSeq = 0;
  CallerTable? _prefixTable;
  CallerTable? _suffixTable;
  ///  PSfix合并表(用户设计:前缀+后缀一张表,识别只用
  ///  PSfix和口令表)。前缀/后缀由段的位置决定(前=前缀,后=后缀)
  CallerTable? _psfixTable;

  ///  目录名(=口令员名):名字 = "口令员/表名",
  ///  如 XuJianguo2/ms_Only -> XuJianguo2。
  ///  每个口令员一个目录,合并等操作都在目录内进行
  String get _dirOf {
    final n = callerTable?.callerName ?? callerName;
    final i = n.indexOf('/');
    return i < 0 ? n : n.substring(0, i);
  }

  ///  加载辅助表:优先PSfix(合并表),没有则回退Prefix/Sufix
  Future<CallerTable?> _loadPSfix() async {
    _psfixTable ??= await _loadAuxTable('${_dirOf}PSfix');
    if (_psfixTable != null && _psfixTable!.rows.isNotEmpty) {
      return _psfixTable;
    }
    //  PSfix不存在:现场合并Prefix+Sufix
    try {
      final prefs = await SharedPreferences.getInstance();
      final n = await CallerTable.mergeToPSfix(prefs, _dirOf);
      if (n > 0) {
        _psfixTable = await _loadAuxTable('${_dirOf}PSfix');
        return _psfixTable;
      }
    } catch (e) {
      debugPrint('mergeToPSfix failed: $e');
    }
    return null;
  }

  Future<CallerTable?> _loadAuxTable(String name) async {
    try {
      if (!await CallerTable.exists(name)) return null;
      return await CallerTable.open(name);
    } catch (_) {
      return null;
    }
  }

  ///  语音段处理(增量,用户设计:段到即查即显示):
  ///  Only 采表走采样路径;呼叫模式走三表状态机——
  ///  前缀段到→立即亮P并等口令(2.5秒);口令段累积拼接;
  ///  后缀段到齐或超时→组装执行。命令边界(识别器0.9秒
  ///  无新final)强制收尾
  Timer? _assembleTimer;
  int _lastSegLen = 0;
  final List<String> _callParts = [];
  bool _prefixSeen = false;
  DateTime? _lastSegmentAt;
  ///  前后缀最小间隔(用户:0.7秒)
  static const _prefixSuffixGap = Duration(milliseconds: 1500);

  void _onSpeech() {
    final s = speech;
    if (s == null || onlyMode) return;
    //  新段先处理(增量:段到即查即显示)——命令边界分支
    //  曾抢先return,段从未被处理(前缀一直不亮的原因)
    final segs = s.segments;
    if (segs.length > _lastSegLen) {
      while (_lastSegLen < segs.length) {
        final alts = _lastSegLen < s.segmentAlts.length
            ? s.segmentAlts[_lastSegLen]
            : const <String>[];
        unawaited(_onNewSegment(segs[_lastSegLen], alts));
        _lastSegLen++;
      }
      return;   //  段处理自设计时器收尾
    }
    //  命令边界(识别器0.9秒无新final):强制收尾
    if (s.commandSeq != _lastCommandSeq) {
      _lastCommandSeq = s.commandSeq;
      _assembleTimer?.cancel();
      _assembleTimer = null;
      _finishAssembly();
      _lastSegLen = 0;
    }
  }

  ///  新段:前缀?→亮P等口令;否则累积为口令;口令已定→后缀
  int _segIdx = 0;
  ///  前缀命中合理性守卫:碎片(<3字符/含unk)与词数相差
  ///  一倍以上的不认——曾单字母"a"命中"1 and 3"、
  ///  "[unk]"命中"3 and 4"(量化行的杂记号惹的祸)
  static bool _plausiblePrefixHit(String heard, String matched) {
    if (heard.contains('unk')) return false;
    if (heard.trim().length < 3) return false;
    //  骨架至少3个辅音("the"骨架th只有2个,碎片不当前缀)
    final sk = CallerTable.skeletonOf(heard);
    if (sk.length < 3) return false;
    final hw = heard.trim().split(' ').length;
    final mw = matched.trim().split(' ').length;
    return hw / mw >= 0.5 && mw / hw <= 2.0;
  }

  Future<void> _onNewSegment(String raw,
      List<String> alts) async {
    var text = raw.trim();
    if (text.isEmpty) return;
    //  新命令第一段:显示区清零(上一条的显示保留到此刻)
    if (_segIdx == 0) {
      tableFlags = '';
      prefixResult = '';
      callResult = '';
      suffixResult = '';
      _assemblyDone = false;
      _notify();
    }
    _segIdx++;
    //  间隔守卫:连续语音(<0.7秒)不进前缀判定
    final now = DateTime.now();
    final gapOk = _lastSegmentAt == null ||
        now.difference(_lastSegmentAt!) >= _prefixSuffixGap;
    _lastSegmentAt = now;
    //  未定前缀:整段先试前缀表(含段首剥离,需间隔≥0.7秒)
    if (!_prefixSeen && gapOk) {
      _prefixTable ??= await _loadPSfix();
      final pt = _prefixTable;
      if (pt != null && pt.rows.isNotEmpty) {
        //  进表先置标志(用户:便于确定故障点):
        //  …=正在查,值=查中,✗=查过未中
        prefixResult = '…';
        _notify();
        //  整段模糊查前缀表(记号=指纹,精确比对必失配)
        var r = pt.lookupSequential(text);
        if (r.hit != null &&
            r.error <= 0.30 &&
            _plausiblePrefixHit(
                text, CallerTable.spokenForm(r.hit!.standardCall))) {
          _prefixSeen = true;
          prefixResult = r.hit!.standardCall;
          tableFlags = 'P';
          _notify();
          debugPrint('段=前缀: "$text" -> $prefixResult '
              '(err=${r.error.toStringAsFixed(2)})');
          _armAssemblyTimer(const Duration(milliseconds: 2500));
          return;
        }
        //  整拍含前缀(如一拍"heads pass ocean"):按词前缀
        //  逐级试查前缀表,命中即剥离
        final words = text.split(' ');
        for (var k = 1; k < words.length; k++) {
          final head = words.sublist(0, k).join(' ');
          final rh = pt.lookupSequential(head);
          if (rh.hit != null &&
              rh.error <= 0.45 &&
              _plausiblePrefixHit(
                  head, CallerTable.spokenForm(rh.hit!.standardCall))) {
            _prefixSeen = true;
            prefixResult = rh.hit!.standardCall;
            tableFlags = 'P';
            _notify();
            debugPrint('段首前缀剥离: "$head" -> $prefixResult');
            text = words.sublist(k).join(' ').trim();
            break;
          }
        }
        if (text.isEmpty) {
          _armAssemblyTimer(const Duration(milliseconds: 2500));
          return;
        }
        //  候选找前缀:首选吞了前缀词时(如整拍念出,heads
        //  被吞到第9候选),扫各候选的词前缀,命中即收前缀,
        //  口令文本保持首选(其口令部分无损)
        for (final cand in alts) {
          if (cand == text) continue;
          final cw = cand.split(' ');
          for (var k = 1; k < cw.length; k++) {
            final head = cw.sublist(0, k).join(' ');
            final ra = pt.lookupSequential(head);
            if (ra.hit != null &&
                ra.error <= 0.45 &&
                _plausiblePrefixHit(
                    head, CallerTable.spokenForm(ra.hit!.standardCall))) {
              _prefixSeen = true;
              prefixResult = ra.hit!.standardCall;
              tableFlags = 'P';
              _notify();
              debugPrint('候选前缀: "$head"(候选"$cand") '
                  '-> $prefixResult');
              break;
            }
          }
          if (_prefixSeen) break;
        }
        if (prefixResult == '…' && !_prefixSeen) prefixResult = '✗';
      }
    }
    //  后缀判定:口令已有→本段试后缀表
    if (callResult.isNotBlank && callResult != '…' && gapOk) {
      _suffixTable ??= _prefixTable ?? await _loadPSfix();
      final st = _suffixTable;
      if (st != null && st.rows.isNotEmpty) {
        suffixResult = '…';
        _notify();
        final rs = st.lookupSequential(text);
        if (rs.hit != null && rs.error <= 0.45) {
          suffixResult = rs.hit!.standardCall;
          tableFlags += tableFlags.isEmpty ? 'S' : '_S';
          _notify();
          debugPrint('段=后缀: "$text" -> $suffixResult');
          _finishAssembly();
          return;
        }
        suffixResult = '✗';
        _notify();
      }
    }
    //  累积为口令段(进表标志:…=累积中/查表中)
    if (callResult.isBlank) {
      callResult = '…';
      tableFlags += tableFlags.isEmpty ? 'C' : '_C';
      _notify();
    }
    _callParts.add(text);
    _assembleTimer?.cancel();
    _assembleTimer = null;
    _armAssemblyTimer(const Duration(milliseconds: 900));
  }

  void _armAssemblyTimer(Duration d) {
    _assembleTimer?.cancel();
    _assembleTimer = Timer(d, _finishAssembly);
  }

  ///  收尾:口令段拼接查表,组装执行,状态复位
  Future<void> _finishAssembly() async {
    _assembleTimer?.cancel();
    _assembleTimer = null;
    if (_isRealValue(callResult) && _callParts.isEmpty) {
      //  口令已定且无新段:直接执行
      _executeAssembled();
      return;
    }
    if (_callParts.isEmpty) {
      _resetAssembly();
      return;
    }
    final callSeg = _callParts.join(' ');
    if (callSeg.isNotBlank && !callSeg.contains('unk')) lastMicText = callSeg;
    //  纯填充词判定(碎片曾"the the"命中Flutterwheel):
    //  闸门装在查表**之后**——先扫描(进表标志…),命中若为
    //  纯填充词再拒(用户:即使扫不到也要进表,过程要诚实)
    const fillers = {'the', 'a', 'an', 'and', 'of', 'to', 'in',
      'on', 'unk', '[unk]'};
    final allFiller = callSeg.trim().toLowerCase()
        .split(RegExp(r' +'))
        .every(fillers.contains);
    final act = callerTable;
    if (act != null) {
      final r = act.lookupSequential(callSeg);
      debugPrint('口令查表: "$callSeg" err=${r.error.toStringAsFixed(2)} '
          '-> ${r.hit?.standardCall}');
      //  递归识别法(用户算法定义,在常规查表后追加):
      ///  常规查表未中时,走辅音家族递归导航——日志全程
      ///  可见,命中则采用,家族缺失则提示
      if (r.hit == null || r.error > 0.45) {
        final candidates = act.rows
            .where((row) => row.recognized.isNotBlank ||
                row.standardCall.isNotBlank)
            .toList();
        final (hit2, steps, missingFam) =
            CallerTable.recursiveRecognize(callSeg, candidates);
        recursiveSteps = steps;
        for (final st in steps) {
          debugPrint('递归: $st');
        }
        _notify();
        if (missingFam != null) {
          debugPrint('递归缺家族: $missingFam');
        }
        if (hit2 != null) {
          debugPrint('递归命中: "$callSeg" -> '
              '"${hit2.standardCall}"');
          callResult = hit2.standardCall;
          lastCandidate = hit2;
          lastCandidateError = 0.0;
          if (!tableFlags.contains('C')) {
            tableFlags += tableFlags.isEmpty ? 'C' : '_C';
          }
          _notify();
          _armAssemblyTimer(const Duration(milliseconds: 900));
          _callParts.clear();
          return;
        }
      }
      if (r.hit != null && r.error <= 0.45) {
        if (allFiller) {
          debugPrint('命中但纯填充词,拒绝: "$callSeg" -> '
              '${r.hit!.standardCall}');
          _callParts.clear();
          if (callResult != '✗') callResult = '✗';
          _notify();
          _resetAssembly();
          return;
        }
        callResult = r.hit!.standardCall;
        //  命中行高亮(面板isCandidate依赖lastCandidate)
        lastCandidate = r.hit;
        lastCandidateError = r.error;
        if (!tableFlags.contains('C')) {
          tableFlags += tableFlags.isEmpty ? 'C' : '_C';
        }
        _notify();
        //  等后缀0.9秒,无则执行
        _armAssemblyTimer(const Duration(milliseconds: 900));
        _callParts.clear();
        return;
      }
      //  拼接未中:最后一段试后缀,其余再查口令
      if (_callParts.length >= 2) {
        final lastSeg = _callParts.removeLast();
        final callSeg2 = _callParts.join(' ');
        final r2 = act.lookupSequential(callSeg2);
        _suffixTable ??= _prefixTable ?? await _loadPSfix();
        final st = _suffixTable;
        String? sufHit;
        if (st != null) {
          for (final r3 in st.rows) {
            final cands = <String>[
              ...r3.recognized.split('|').map((t) => t.trim().toLowerCase()),
              CallerTable.spokenForm(r3.standardCall),
            ];
            if (cands.contains(lastSeg.toLowerCase())) {
              sufHit = r3.standardCall;
              break;
            }
          }
        }
        if (r2.hit != null && r2.error <= 0.45 && sufHit != null) {
          callResult = r2.hit!.standardCall;
          suffixResult = sufHit;
          tableFlags += '_C_S';
          _notify();
          _callParts.clear();
          _executeAssembled();
          return;
        }
        _callParts.add(lastSeg);
      }
    }
    _callParts.clear();
    if (_isRealValue(callResult)) {
      _executeAssembled();
    } else {
      debugPrint('口令未中,放弃: "$callSeg"');
      if (callResult != '✗') callResult = '✗';
      _notify();
      _resetAssembly();
    }
  }

  bool _assemblyDone = false;
  ///  真值=非空且非显示标记(…=查表中,✗=未中)——
  ///  标记绝不能被执行(曾把"…"当口令发出)
  static bool _isRealValue(String s) =>
      s.isNotBlank && s != '…' && s != '✗';
  void _executeAssembled() {
    //  双锁:执行标志 + 组合口令本身(界面消费前不重入——
    //  定时器/命令边界/新段三路竞争曾致双执行)
    if (_assemblyDone || assembledCall.isNotBlank) return;
    if (!_isRealValue(callResult)) {
      _resetAssembly();
      return;
    }
    //  保持_done=true直到新命令首段——曾复位即重置,
    //  命令边界随即二次执行
    _assemblyDone = true;
    //  三区都过真值滤(✗/…绝不能拼进口令——曾执行"✗ Sweep")
    assembledCall = [prefixResult, callResult, suffixResult]
        .where(_isRealValue)
        .join(' ');
    if (assembledCall.isBlank) {
      _resetAssembly();
      return;
    }
    debugPrint('三表组合执行: "$assembledCall"');
    _notify();
    _resetAssembly();
    //  执行后3秒自动清零三区(用户:实时状态,不留旧信息)
    Future.delayed(const Duration(seconds: 3), () {
      clearAllDisplays();  //  无条件清零(用户:超时必须清)
    });
  }

  void _resetAssembly() {
    _callParts.clear();
    _prefixSeen = false;
    _lastSegLen = 0;
    _segIdx = 0;
    Future.microtask(() {
      //  显示保留到下一条口令开始(由新段到达时清)
    });
  }

  ///  命令分段分析+三表检索+组合。
  ///  分段规则(用户定义):三段=前缀/口令/后缀;两段=最长段
  ///  是口令,另一段按位置定前后缀(在前=前缀,在后=后缀);
  ///  一段=只有口令
  Future<void> _processCommand(List<String> segsIn) async {
    var segs = segsIn;
    //  显示块已在 _onSpeech 清过;这里逐表检索,每进一表
    //  立即刷新显示(口令员看得见 P→P_C→P_C_S 的递加过程)
    if (segs.isEmpty) return;
    //  段首前缀剥离:整拍念出的口令(停顿短于识别器断句,
    //  如一拍"heads pass ocean")首段带着前缀词——从Prefix
    //  表的记号/读法里找最长的开头匹配,拆成前缀段+口令段
    {
      _prefixTable ??= await _loadPSfix();
      final table = _prefixTable;
      if (table != null && segs.isNotEmpty && segs[0].isNotEmpty) {
        final t0 = segs[0].toLowerCase();
        String? best;
        for (final r in table.rows) {
          final cands = <String>[
            ...r.recognized.split('|').map((t) => t.trim().toLowerCase()),
            CallerTable.spokenForm(r.standardCall),
          ];
          for (final c in cands) {
            if (c.isNotEmpty && t0.startsWith('$c ') && c.length > 1) {
              if (best == null || c.length > best.length) best = c;
            }
          }
        }
        if (best != null) {
          final rest = segs[0].substring(best.length + 1);
          segs = [rest, ...segs.sublist(1)];
          debugPrint('段首前缀剥离: "$best" + "$rest"');
        }
      }
    }
    //  整句优先:整条口令文本先直接查一次表——多拍记号
    //  (如 dosado 的 "do so do"分三拍念出)整条命中即单一
    //  口令,不再拆前缀/口令/后缀(录音怎么存,喊就怎么中)
    final act0 = callerTable;
    if (act0 != null) {
      final whole = segs.join(' ').trim();
      final rw = act0.lookupSequential(whole);
      if (rw.hit != null && rw.error <= 0.30) {
        callResult = rw.hit!.standardCall;
        lastCandidate = rw.hit;
        lastCandidateError = rw.error;
        tableFlags = 'C';
        assembledCall = callResult;
        debugPrint('whole-command hit: "$whole" -> "$callResult" '
            '(err=${rw.error.toStringAsFixed(2)})');
        _notify();
        return;
      }
    }
    String callSeg;
    String? prefixSeg;
    String? suffixSeg;
    if (segs.length == 1) {
      callSeg = segs[0];
    } else if (segs.length == 2) {
      callSeg = segs[0].length >= segs[1].length ? segs[0] : segs[1];
      final other = callSeg == segs[0] ? segs[1] : segs[0];
      if (callSeg == segs[0]) {
        suffixSeg = other;
      } else {
        prefixSeg = other;
      }
    } else {
      prefixSeg = segs[0];
      callSeg = segs.length == 3
          ? segs[1]
          : segs.sublist(1, segs.length - 1).join(' ');
      suffixSeg = segs.last;
    }
    final stem = _dirOf;
    //  前缀段 → Prefix 非Only表
    if (prefixSeg != null) {
      _prefixTable ??= await _loadAuxTable('${stem}Prefix');
      final t = _prefixTable;
      if (t != null && t.rows.isNotEmpty) {
        final r = t.lookupSequential(prefixSeg);
        debugPrint('P-lookup "$prefixSeg" '
            'err=${r.error.toStringAsFixed(2)} '
            '-> ${r.hit?.standardCall}');
        if (r.hit != null && r.error <= 0.30) {
          prefixResult = r.hit!.standardCall;
          tableFlags = 'P';
          _notify();
        }
      }
    }
    //  口令段 → 当前合并表
    final act = callerTable;
    if (act != null && callSeg.isNotBlank) {
      final r = act.lookupSequential(callSeg);
      debugPrint('C-lookup "$callSeg" '
          'err=${r.error.toStringAsFixed(2)} '
          '-> ${r.hit?.standardCall}');
      if (r.hit != null && r.error <= 0.45) {
        callResult = r.hit!.standardCall;
        tableFlags += tableFlags.isEmpty ? 'C' : '_C';
        _notify();
      }
    }
    //  后缀段 → Sufix 非Only表
    if (suffixSeg != null) {
      _suffixTable ??= await _loadAuxTable('${stem}Sufix');
      final t = _suffixTable;
      if (t != null && t.rows.isNotEmpty) {
        final r = t.lookupSequential(suffixSeg);
        debugPrint('S-lookup "$suffixSeg" '
            'err=${r.error.toStringAsFixed(2)} '
            '-> ${r.hit?.standardCall}');
        if (r.hit != null && r.error <= 0.45) {
          suffixResult = r.hit!.standardCall;
          tableFlags += tableFlags.isEmpty ? 'S' : '_S';
        }
      }
    }
    //  组合为整条口令(三个结果分别存储,最后组合)
    if (callResult.isNotBlank) {
      assembledCall = [prefixResult, callResult, suffixResult]
          .where((s) => s.isNotBlank)
          .join(' ');
      debugPrint('assembled "$assembledCall" [$tableFlags]');
    } else {
      debugPrint('pipeline miss: call lookup failed '
          'for "$callSeg" [flags=$tableFlags]');
    }
    _notify();
  }

  ///  口令已被输入行执行。三个显示区**保留**到下一条口令
  /// 开始时清零(用户:显示不能一闪而过,要看得见)
  ///  「存」钮:把最近一次麦克风识别文本存入选中行
  ///  (用户:用麦克风产出直接当指纹,不用圆钮的干净版)
  Future<void> saveMicToken() async {
    final t = callerTable;
    CallerRow? row;
    if (t != null && nonOnlySelectedSeq != null) {
      for (final r in t.rows) {
        if (r.seq == nonOnlySelectedSeq) {
          row = r;
          break;
        }
      }
    }
    if (t == null || row == null) {
      debugPrint('saveMicToken: 无选中行');
      return;
    }
    if (lastMicText.isBlank) {
      debugPrint('saveMicToken: 无识别文本');
      return;
    }
    final newToken = row.recognized.isNotBlank
        ? '${row.recognized}|$lastMicText'
        : lastMicText;
    await t.updateRow(row.seq, recognized: newToken, sort: false);
    debugPrint('saveMicToken: 第${row.seq}行 <- "$lastMicText"');
    _notify();
  }

  ///  清零三区+递归(开/关麦克风/X钮/点输入框/命令超时)
  void clearAllDisplays() {
    tableFlags = '';
    prefixResult = '';
    callResult = '';
    suffixResult = '';
    recursiveSteps = [];
    assembledCall = '';
    _callParts.clear();
    _prefixSeen = false;
    _lastSegLen = 0;
    _segIdx = 0;
    _assemblyDone = false;
    _notify();
  }

  void consumeAssembled() {
    assembledCall = '';
    _notify();
  }

  ///  表名最后一段(目录结构的表名部分):
  ///  XuJianguo2/Words/Words_Only -> Words_Only。
  ///  后缀判定一律用它,容忍目录层意外叠名
  String get _tablePart =>
      (callerTable?.callerName ?? '').split('/').last;

  ///  当前表是否为关键词训练表(.../Words_Only)
  bool get _isWordsTable => _tablePart == 'Words_Only';


  ///  当前表是否为 Only 工作表(表名以 _Only 结尾)
  bool get onlyMode =>
      callerTable != null && callerTable!.callerName.endsWith('_Only');
  ///  手动选中的采表行序号(点面板行可重选;null=自动取第一个空行)
  int? dictationSeqOverride;
  ///  非Only表的点击选中行序号(圆钮录音目标)
  int? nonOnlySelectedSeq;

  ///  选定某行作为当前采表目标(重新录入用)
  void selectDictationRow(int seq) {
    dictationSeqOverride = seq;
    dictationText = '';
    _notify();
  }

  ///  当前待录行:优先取手动选中的行,否则第一个第2列为空的行
  CallerRow? get currentDictationRow {
    final t = callerTable;
    if (t == null) return null;
    if (dictationSeqOverride != null) {
      for (final r in t.rows)
        if (r.seq == dictationSeqOverride) return r;
    }
    for (final r in t.rows)
      if (r.recognized.isBlank) return r;
    //  全部记录已录满:光标停在当前记录的下一条
    //  (最后一条则停回第一条),不再消失
    final cur = dictationSeqOverride;
    CallerRow? afterCur;
    bool seenCur = false;
    for (final r in t.rows) {
      if (seenCur) {
        afterCur = r;
        break;
      }
      if (r.seq == cur) seenCur = true;
    }
    return afterCur ?? (t.rows.isNotEmpty ? t.rows.first : null);
  }
  ///  源表名 = Only 表名去掉 "_<级别>_Only" 后缀
  ///  (如 "XuJianguo_plus_Only" -> "XuJianguo")
  String get onlySourceName {
    //  目录结构下源表都在同一目录内:
    //  库表(Prefix/Sufix)与已合并同名表合并——补录新库
    //  条目时旧读法不丢;级别表与低一级合并表合并
    //  (ms_Only 首次合并无源,可选;重合并以现有 ms 为源,
    //   已录口令不丢)
    final tp = _tablePart;
    final dir = _dirOf;
    if (tp == 'Prefix_Only') return '$dir/Prefix';
    if (tp == 'Sufix_Only') return '$dir/Sufix';
    final m = RegExp(r'^(plus|a1|a2|c1|c2|c3a|c3b|ms)_Only$')
        .firstMatch(tp);
    if (m == null) return callerTable?.callerName ?? callerName;
    const order = ['ms', 'plus', 'a1', 'a2', 'c1', 'c2', 'c3a', 'c3b'];
    final lv = order.indexOf(m.group(1)!);
    return '$dir/${order[lv <= 0 ? 0 : lv - 1]}';
  }
  ///  目标表名 = Only 表名去 "_Only"
  String get onlyTargetName =>
      (callerTable?.callerName ?? '').replaceAll('_Only', '');

  ///  当前 Only 表的级别序号(ms=0,plus=1,…);<0 表示无级别后缀
  int get _onlyLevelIdx {
    final n = callerTable?.callerName ?? '';
    const order = ['ms', 'plus', 'a1', 'a2', 'c1', 'c2', 'c3a', 'c3b'];
    final m = RegExp(r'_(plus|a1|a2|c1|c2|c3a|c3b|ms)_Only$')
        .firstMatch(n);
    return m == null ? -1 : order.indexOf(m.group(1)!);
  }

  ///  规范形:按分解重排(前缀归一 + Left + 核心 + 后缀)
  static String canonicalForm(String s) {
    final d = CallerTable.decomposeCall(s);
    final parts = <String>[
      ...d.$1,
      if (d.$2) 'left',
      ...d.$3,
      ...d.$4,
    ];
    final r = parts.join(' ').trim();
    return r.isEmpty ? s : r;
  }

  ///  采表确认:输入框文字写入当前待录行第2列,跳下一行
  ///  前5字母校验(用户严格限制):录音记号与标准口令的
  ///  前5个字母必须一致——确保指纹质量,再探讨递归识别
  static bool _prefix5Match(String token, String call) {
    String letters(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    final a = letters(token);
    final b = letters(call);
    if (a.length < 5 || b.length < 5) return true;  //  过短不卡
    return a.substring(0, 5) == b.substring(0, 5);
  }

  Future<bool> confirmDictation(String text,
      {bool force = false}) async {
    final t = callerTable;
    final row = currentDictationRow;
    debugPrint('confirmDictation: text="$text" row=${row?.seq} '
        'table=${t?.callerName}');
    if (t == null || row == null || text.isBlank) return false;
    //  存库用原始识别文本(记号=指纹,不改写);
    //  显示文本是规范形,只供人看
    if (dictationRawText.isNotBlank &&
        canonicalForm(dictationRawText) == text.trim()) {
      text = dictationRawText;
      debugPrint('confirmDictation: store raw "$text"');
    }
    //  记号检查:
    //  1) 同口令的两行记号雷同 = 两行完全相同(多对一重复建行
    //     的自然结果)——不再拦,提示后再点一次黄框即删除旧行
    //  2) 不同口令的记号雷同 = 真混淆(查表无法区分),保留
    //     警示,再点一次黄框=仍要存入(人类决断)
    final newToken = text.trim();
    CallerRow? identicalRow;
    for (final r in t.rows) {
      if (r.seq == row.seq) continue;
      final sameCall = r.standardCall.trim().toLowerCase() ==
          row.standardCall.trim().toLowerCase();
      for (final tk in r.recognized.split('|')) {
        final t2 = tk.trim();
        if (t2.isEmpty) continue;
        if (sameCall) {
          //  同口令:仅一字不差才算"两行完全相同"(提示删一行)。
          //  近似而不同的读法=多归1的正常内容,不拦不删
          //  (用户:没按"清理"钮不得删记录)
          if (t2.toLowerCase() == newToken.toLowerCase()) {
            debugPrint('identical rows: row ${r.seq} exact token');
            identicalRow = r;
            break;
          }
          continue;
        }
        //  跨口令记号雷同=真混淆(查表无法区分):警示,
        //  再点一次黄框=仍要存入(人类决断,force旁路)
        if (!force &&
            CallerTable.sentenceError(t2, newToken) < 0.12) {
          debugPrint('token conflict with row ${r.seq}: "$t2"');
          //  带上撞车行的口令名,让口令员知道是和哪条混了
          conflictPending = true;
          //  错误信息四段:行号|撞车行口令|撞车行记号|操作提示
          lastError =
              'token_conflict:${r.seq}|${r.standardCall}|'
              '$t2|记号雷同,再点一次黄框=仍要存入';
          _notify();
          Future.delayed(const Duration(seconds: 5), () {
            if (lastError != null &&
                lastError!.startsWith('token_conflict')) {
              lastError = null;
              _notify();
            }
          });
          return false;
        }
      }
      if (identicalRow != null) break;
    }
    //  两行完全相同:提示是否删除一行(再点一次=删旧行存新行)
    if (identicalRow != null && !force) {
      conflictPending = true;
      lastError =
          'token_conflict:${identicalRow.seq}|'
          '${identicalRow.standardCall}|'
          '${identicalRow.recognized.split('|').first}|'
          '两行完全相同,再点一次黄框=删除此行';
      _notify();
      Future.delayed(const Duration(seconds: 5), () {
        if (lastError != null &&
            lastError!.startsWith('token_conflict')) {
          lastError = null;
          _notify();
        }
      });
      return false;
    }
    if (force && identicalRow != null) {
      await t.removeRow(identicalRow.seq);
      debugPrint('identical rows: old row '
          '${identicalRow.seq} removed');
    }
    //  前5字母校验(用户严格限制):不过则提示,再点一次=仍存
    if (!_prefix5Match(newToken, row.standardCall) && !force) {
      debugPrint('前5字母不符: "$newToken" vs '
          '"${row.standardCall}"');
      conflictPending = true;
      lastError =
          'token_conflict:0|${row.standardCall}|'
          '$newToken|前5字母不符,再点一次=仍要存入';
      _notify();
      Future.delayed(const Duration(seconds: 5), () {
        if (lastError != null &&
            lastError!.startsWith('token_conflict')) {
          lastError = null;
          _notify();
        }
      });
      return false;
    }
    //  确认即替换:重新采同一条时删旧记号、记新记号
    await t.updateRow(row.seq,
        recognized: newToken, sort: false);
    conflictPending = false;
    dictationText = '';
    dictationRawText = '';
    //  家族传播已按用户要求取消:记号只能来自口令员
    //  自己的采样,变体(Left/分数/数字)也要各自录,
    //  完全留给口令员自己掌握
    dictationCandidates = [];
    //  确认后:光标移到下一个需要录入的行(第2列为空)。
    //  物理的下一行已录完则继续往下找,直到找到空行为止;
    //  后面全满时回到表内第一个空行补漏,全表录满则不设光标
    final ordered = [...t.rows]..sort((a, b) => a.seq.compareTo(b.seq));
    CallerRow? nextRow;
    for (final r in ordered) {
      if (r.seq > row.seq && r.recognized.isBlank) {
        nextRow = r;
        break;
      }
    }
    if (nextRow == null) {
      for (final r in ordered) {
        if (r.recognized.isBlank) {
          nextRow = r;
          break;
        }
      }
    }
    //  后面全满且无空行可补:停当前行的下一条
    //  (末行回第一条),不跳回第一行
    if (nextRow == null) {
      CallerRow? afterCur;
      bool seenCur = false;
      for (final r in ordered) {
        if (seenCur) {
          afterCur = r;
          break;
        }
        if (r.seq == row.seq) seenCur = true;
      }
      nextRow = afterCur ??
          (ordered.isNotEmpty ? ordered.first : null);
    }
    dictationSeqOverride = nextRow?.seq;
    _notify();
    return true;
  }

  ///  家族变体传播(人类学习法):录好一条口令后,同族
  ///  未录行(前缀/Left/数字/分数/后缀口令不同,口令核心
  ///  相同的行)自动推算记号——保留听到的口令核心,按变体
  ///  行的前缀/左右/后缀重组。例:录了 "Square Thru 4"
  ///  (听到 "square thru"),"Square Thru 3" 得
  ///  "square thru three","Left Square Thru 4" 得
  ///  "left square thru four"
  Future<int> _propagateToVariants(
      CallerTable t, CallerRow row, String token) async {
    final rowCore =
        CallerTable.decomposeCall(row.standardCall).$3.join(' ');
    if (rowCore.isEmpty) return 0;
    final tokCore = CallerTable.decomposeCall(token).$3;
    if (tokCore.isEmpty) return 0;
    var filled = 0;
    for (final r2 in t.rows) {
      if (r2.seq == row.seq || r2.recognized.isNotBlank) continue;
      final p2 = CallerTable.decomposeCall(r2.standardCall);
      //  口令核心必须相同(核心不同的行不传播)
      if (p2.$3.join(' ') != rowCore) continue;
      final words = [
        ...p2.$1,          //  变体行的前缀(heads/boys...)
        if (p2.$2) 'left', //  变体行的左右
        ...tokCore,        //  听到的口令核心(用户发音)
        ...p2.$4,          //  变体行的后缀(four/quarter/roll)
      ];
      final newTok = words.join(' ').trim();
      if (newTok.isEmpty) continue;
      await t.updateRow(r2.seq, recognized: newTok, sort: false);
      filled++;
    }
    return filled;
  }


  ///  完整口令结构的变体词表:前缀(heads/sides/boys/
  ///  girls/leaders/trailers/centers/ends/everyone)、
  ///  左右变体(left/right/wrong/way)、数字分数后缀
  ///  (one..six/quarter/half/and/a)、后缀口令(roll/spread,
  ///  只能跟在别的口令后)
  static const _variantWords = {
    'heads', 'sides', 'boys', 'girls', 'leaders', 'trailers',
    'centers', 'ends', 'everyone', 'men', 'women', 'couples',
    'left', 'right', 'wrong', 'way',
    'one', 'two', 'three', 'four', 'five', 'six',
    'quarter', 'half', 'and', 'a',
    'roll', 'spread',
  };

  List<(int, List<String>)>? _findInsertions(
      List<String> a, List<String> b) {
    if (b.length <= a.length) return null;
    //  找公共前缀
    var pre = 0;
    while (pre < a.length && pre < b.length && a[pre] == b[pre])
      pre++;
    //  找公共后缀
    final result = <(int, List<String>)>[];
    var ai = 0;
    var extra = <String>[];
    var extraAt = 0;
    for (var bi = 0; bi < b.length; bi++) {
      if (ai < a.length && a[ai] == b[bi]) {
        if (extra.isNotEmpty) {
          result.add((extraAt, extra));
          extra = [];
        }
        ai++;
      } else if (_variantWords.contains(b[bi])) {
        if (extra.isEmpty) extraAt = ai;
        extra.add(b[bi]);
      } else {
        return null;   //  非变体词差异
      }
    }
    if (extra.isNotEmpty) result.add((extraAt, extra));
    if (ai != a.length) return null;   //  a 的词未全部对上
    return result.isEmpty ? null : result;
  }

  ///  完成建表:与源表合并、总体排序、另存(去掉 Only)
  Future<int?> finishOnlyTable() async {
    final t = callerTable;
    if (t == null || !onlyMode) return null;
    final prefs = await SharedPreferences.getInstance();
    try {
      final count = await CallerTable.mergeAndSaveAs(
          prefs, t, onlySourceName, onlyTargetName,
          sourceRequired: _onlyLevelIdx > 0);
      return count;
    } catch (e) {
      debugPrint('finishOnlyTable failed: $e');
      lastError = 'merge_aborted:${e.toString()}';
      _notify();
      return null;
    }
  }

  ///  口令员在 Calls 画面点选的口令(输入行取走后清空)
  String? callSelection;

  ///  长按表名"增加记录"模式:Calls 页选中的口令
  ///  不填输入行,而是直接加为本表新记录
  bool awaitingAddRecord = false;

  ///  记号碰撞提示行(口令不同而记号相同,需重新识别),
  ///  开 Only 表时体检生成
  List<String> tokenCollisionRows = [];
  ///  本次开表是否已弹过碰撞提示
  bool collisionNoticeShown = false;

  ///  清空当前表全部记号(第2列),保留标准口令
  Future<int> clearTableTokens() async {
    final t = callerTable;
    if (t == null) return 0;
    final n = await t.clearAllTokens();
    dictationText = '';
    dictationSeqOverride = null;
    _notify();
    return n;
  }

  ///  增加记录:以选定的口令名新建一行(第2列空,待圆钮采样),
  ///  光标跳到新行。多对一:同一口令允许重复建行,
  ///  每行录一笔语音读法(合并时记号自动归并)
  Future<void> addRecordWithCall(String call) async {
    final t = callerTable;
    if (t == null) return;
    final row = await t.addRow(
        recognized: '', standardCall: call.trim());
    dictationSeqOverride = row.seq;
    dictationText = '';
    _notify();
  }

  ///  开始记录初始化:识别句写入新记录第二列。
  ///  返回新记录;表不存在时返回 null。
  Future<CallerRow?> startRecordInit(String sentence) async {
    final table = callerTable;
    if (table == null) return null;
    //  初始化期间暂停语音识别,避免后续识别句打断录入
    speech?.pause();
    pendingRecord = await table.addRow(recognized: sentence);
    _notify();
    return pendingRecord;
  }
  //  (startRecordInit 仅在 Only 表的补全流程中使用;
  //   非Only表圆钮改为存入所点行,见 sequence_frame)

  ///  口令员在 Calls 画面选中口令:只填入输入行供继续编辑,
  ///  不直接存表;存表时机是口令执行正确(见 completeRecordInit)
  void selectCallForInit(String callTitle) {
    callSelection = callTitle;
    _notify();
  }

  ///  口令执行正确后,把整个口令一起存入记录并恢复识别。
  ///  多对一:不去重——同口令可有多行,各存一笔读法
  Future<bool> completeRecordInit(String wholeCall) async {
    final table = callerTable;
    final row = pendingRecord;
    if (table == null || row == null) return false;
    await table.updateRow(row.seq, standardCall: wholeCall);
    pendingRecord = null;
    //  恢复语音识别
    speech?.resume();
    _notify();
    return true;
  }

  bool get isActive => phase != 'idle';

  ///  输入行创建/重建时调用,注入其语音识别器并取消孤儿回收
  void attach(DualSpeechProvider speechProvider) {
    speechProvider.removeListener(_onSpeech);
    speech = speechProvider;
    speechProvider.addListener(_onSpeech);
    _orphanTimer?.cancel();
    _orphanTimer = null;
  }

  ///  输入行销毁时调用:若短时间后没有新的输入行接入(即真正离开页面),
  ///  回收整个流程,避免后台残留监测
  void detach() {
    //  完全禁用孤儿回收:start()期间的布局重建会误触发
    //  detach→5秒后stop→表自动消失。退出表由"退出映射表"
    //  按钮或麦克风长按显式操作
  }

  //  登录确认后启动。withMusic=true 直接进入音乐模式(音乐按钮
  //  在未登录时按下);listen=false 为表管理模式(新按钮打开映射表,
  //  只做记录的增删排序,不启动连续识别)
  Future<void> start({bool withMusic = false, bool listen = true}) async {
    debugPrint('VoiceFlow.start withMusic=$withMusic listen=$listen');
    _musicSub ??= musicMonitor.events.listen(_onEvent);
    lastError = null;
    musicStoppedDuringCall = false;
    playbackWasActive = false;
    musicEnabled = withMusic;
    if (listen)
      tableMode = false;   //  检索(喊口令)模式
    //  麦克风检索模式不需要显示映射表;表管理模式要显示
    panelMinimized = listen;
    if (withMusic) {
      phase = 'awaiting';
      _notify();
      await musicMonitor.startMicMonitor();
    } else {
      phase = 'calling';
      _notify();
      if (listen)
        startListening();
    }
  }

  ///  表管理模式(新按钮打开映射表):显示面板,不启动连续识别,
  ///  用采样按钮增加记录、点行删除、自动排序;麦克风钮另起检索。
  ///  表管理模式下不启动(也不显示)音乐节拍检测环节
  bool tableMode = false;

  Future<void> startTableMode() async {
    //  保险:强制停掉可能残留的音乐监测环节,
    //  表管理模式下绝不启动音乐节拍检测
    musicEnabled = false;
    musicMonitor.stopMicMonitor();
    musicMonitor.stopPlaybackWatch();
    restoreDancerSpeed();
    await start(listen: false);
    tableMode = true;
    //  Only 表采表需要看表(展开);非 Only 表后台运行(收起,
    //  可手动展开),喊口令时面板也默认收起
    panelMinimized = !onlyMode;
    _notify();
  }

  //  映射表面板显隐(麦克风检索模式默认收起,表管理模式默认展开;
  //  口令员随时可手动切换,不影响后台)
  bool panelMinimized = false;
  void setPanelMinimized(bool value) {
    if (panelMinimized == value) return;
    panelMinimized = value;
    _notify();
  }

  ///  登录(如需要)并启动流程;登录取消返回 false
  Future<bool> loginAndStart({bool withMusic = false}) async {
    if (isActive) return false;
    final ok = await (loginRequest?.call() ?? Future.value(false));
    if (!ok) return false;
    await start(withMusic: withMusic);
    return true;
  }

  //  结束语音流程(麦克风退出):停止语音相关监测。
  //  音乐节拍独立于语音流程,不受此影响(由其按钮单独控制)
  ///  仅结束语音识别(表保持打开,麦克风钮再按可重启;
  ///  不清表、不动音乐节拍状态)
  void stopListening() {
    clearAllDisplays();
    debugPrint('VoiceFlow.stopListening (phase=$phase)');
    speech?.cancel();
    if (phase != 'awaiting' && phase != 'detecting')
      phase = callerTable != null ? 'calling' : 'idle';
    lastCandidate = null;
    lastCandidateError = 1.0;
    _notify();
  }

  void stop() {
    debugPrint('VoiceFlow.stop (phase=$phase)');
    speech?.cancel();
    bpm = 0;
    lastCandidate = null;
    lastCandidateError = 1.0;
    //  音乐节拍取样中不改阶段:口令员常切到音乐应用播放音乐,
    //  切后台触发的 stop 不应丢弃在途的节拍检测结果
    if (phase != 'awaiting' && phase != 'detecting')
      phase = 'idle';
    musicStoppedDuringCall = false;
    //  清除表引用:退出后再次打开时进入映射表选择画面
    callerTable = null;
    tableMode = false;
    dictationText = '';
    dictationSeqOverride = null;
    _notify();
  }

  //  音乐节拍按钮(屏幕常显):
  //  第 1 次按下:取音乐节拍并发送给系统,舞者按此节奏跳;
  //  第 2 次按下:停止采用节拍,恢复原设定速度(节拍缓存保留,
  //              音乐没停也只停止采用,不重新取样);
  //  音乐停止(系统检测到):等同第 2 次按下,自动恢复;
  //  第 3 次按下:直接输出原来的取样节拍,不必重新取样
  Future<void> toggleMusic() async {
    if (musicDancing) {
      _musicOff();
      return;
    }
    if (phase == 'awaiting' || phase == 'detecting') {
      //  等待/检测中再击一次:取消音乐节拍,退出取样
      _cancelMusicSampling();
      return;
    }
    //  有缓存且外部音乐仍在播放:直接采用上次节拍,不必重测;
    //  音乐已停止:不用旧值,重新要求播放并重新检测
    if (cachedBpm > 0 && await musicMonitor.isMusicPlaying()) {
      _musicOn(cachedBpm);
      return;
    }
    //  现场取样。先暂停流式识别让出麦克风
    //  (暂停接口会收尾当前轮并送出结果,取样完自动恢复)
    speech?.pause();
    musicEnabled = true;
    phase = 'awaiting';
    _notify();
    await musicMonitor.startMicMonitor();
    //  半分钟没听到音乐:自动取消退出(不影响其他过程)
    _musicAwaitTimer?.cancel();
    _musicAwaitTimer = Timer(const Duration(seconds: 30), () {
      if (phase == 'awaiting') {
        debugPrint('music await timeout -> auto cancel');
        _cancelMusicSampling();
      }
    });
  }

  //  取消音乐节拍取样(等待中再击 / 30秒超时 / 检测中再击):
  //  停麦监测、退出取样阶段、恢复语音,不影响其他过程
  void _cancelMusicSampling() {
    _musicAwaitTimer?.cancel();
    _musicAwaitTimer = null;
    musicMonitor.stopMicMonitor();
    musicEnabled = false;
    if (phase == 'awaiting' || phase == 'detecting')
      phase = callerTable != null ? 'calling' : 'idle';
    speech?.resume();
    _notify();
  }

  //  节拍生效:接管速度,并开启音乐停止检测;
  //  若此前为取样暂停了流式识别,现在自动恢复
  void _musicOn(int bpm) {
    _musicAwaitTimer?.cancel();
    _musicAwaitTimer = null;
    speech?.resume();
    cachedBpm = bpm;
    takeOverDancerSpeed(bpm);
    musicMonitor.stopMicMonitor();
    musicMonitor.startPlaybackWatch();
    playbackWasActive = false;
    musicDancing = true;
    //  恢复基础阶段(语音未登录则 idle)
    if (phase == 'awaiting' || phase == 'detecting')
      phase = callerTable != null ? 'calling' : 'idle';
    _notify();
  }

  //  节拍停用:恢复原设定速度(缓存保留);
  //  若流式识别此前被暂停,自动恢复喊口令
  void _musicOff() {
    speech?.resume();
    restoreDancerSpeed();
    musicMonitor.stopMicMonitor();
    musicMonitor.stopPlaybackWatch();
    musicDancing = false;
    musicEnabled = false;
    if (phase == 'awaiting' || phase == 'detecting')
      phase = callerTable != null ? 'calling' : 'idle';
    _notify();
  }

  Future<void> _onEvent(MusicEvent e) async {
    //  自动化测试触发:等同按下音乐节拍按钮
    if (e.type == 'auto_music') {
      await toggleMusic();
      return;
    }
    //  自动语音测试:直接采样 8 秒(不依赖映射表与页面,
    //  识别结果见日志,用于验证采集->讯飞->文本链路)
    if (e.type == 'auto_voice') {
      debugPrint('auto_voice: sampling 8s');
      _testSpeech?.dispose();
      final s = speech ?? (_testSpeech = DualSpeechProvider());
      s.cancel();
      s.addListener(() {
        if (s.hasResults) {
          debugPrint('auto_voice RESULT: '
              '"${s.lastResult!.recognizedWords}"');
          s.clearResults();
        }
      });
      s.sample(localeId: 'en_US');
      return;
    }
    if (e.type == 'auto_voice_end') {
      debugPrint('auto_voice: end sampling');
      speech?.stop();
      _testSpeech?.stop();
      return;
    }
    //  音乐功能已关闭时不处理(可能有关闭瞬间在途的事件)
    if (!musicEnabled) return;
    switch (e.type) {
      case 'music_detected':
        if (phase == 'awaiting' || phase == 'ready') {
          phase = 'detecting';
          _notify();
        }
        break;
      case 'bpm':
        //  取样激活即接收(期间 phase 可能因切后台被 stop 干扰)
        if (!musicDancing) {
          //  取样完成:节拍生效(接管速度,监测音乐停止)
          _musicOn(e.value ?? 0);
        }
        break;
      case 'music_stopped':
        //  取样阶段音乐消失(重试窗口中),回到等待
        if (phase == 'detecting') {
          phase = 'awaiting';
          _notify();
        }
        break;
      case 'playback_stopped':
        //  节拍生效期间外部音乐停止:等同再次按下按钮,
        //  自动停用节拍并恢复原设定速度(仅本机播放可检测)
        if (musicDancing && playbackWasActive) {
          playbackWasActive = false;
          _musicOff();
        }
        break;
      case 'playback_started':
        //  节拍生效期间音乐继续/重播:不重新取样,直接沿用
        if (musicDancing)
          playbackWasActive = true;
        break;
      case 'error':
        lastError = 'mic';
        _musicOff();
        break;
    }
  }

  //  节拍检测完成后自动进入语音识别
  void startListening() {
    clearAllDisplays();
    final s = speech;
    if (s == null) return;
    //  麦克风识别开始:面板保持打开(用户:要看到系统选了
    // 哪条口令,命中行高亮,不关表)
    //  喊口令:语法=当前表+全目录词池(前缀/后缀表的词
    //  都在场,三表流水线才解码得到)
    final callG = <String>{
      ...?_onlyTableWords(),
      ..._allDirWords,
    };
    s.setSampleGrammar([...callG, '[unk]']);
    s.initialize().whenComplete(() {
      if (s.isAvailable) {
        s.listen(localeId: 'en_US');
        _notify();
      } else {
        lastError = 'speech';
        stop();
      }
    });
  }

  //  用检测到的节拍临时接管跳舞速度(覆盖通道):
  //  全程不修改用户的速度设定,动态小人按节拍跳;
  //  退出时清除覆盖,原速度选择自动继续生效
  void takeOverDancerSpeed(int value) {
    DanceModel.musicBpmOverride = value;
  }

  void restoreDancerSpeed() {
    DanceModel.musicBpmOverride = null;
  }

  void _notify() => notifyListeners();

}
