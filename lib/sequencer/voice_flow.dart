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
    //  大幅提高识别准确率);流式喊口令仍为自由识别
    speech?.setSampleGrammar(_onlyTableWords());
    dictationPartial = '';
    dictationCandidates = [];
    conflictPending = false;
    //  开实时中间结果:边念边显示,反馈更快
    speech?.sample(localeId: 'en_US', partialResults: true);
    //  Only 模式:结果直接在 VoiceFlow 处理(输入行隐藏时 build 不跑)
    if (onlyMode)
      speech?.addListener(_onSampleResult);
    Future.microtask(() => _notify());
    return true;
  }

  ///  读法变体:仅针对模型词典缺失的词(实测被忽略的只有
  ///  allemande/dosado/flutterwheel/rollaway 四个)。
  ///  变体词要少而稳——多余的短词(如 nat/sa)会与真口令词
  ///  (如 left)抢解码,反而把正确听法挤掉
  static const _wordVariants = <String, List<String>>{
    'dosado': ['doe', 'dough'],
    'allemande': ['alley', 'mande', 'mond'],
    'flutterwheel': ['flutter', 'wheel'],
    'rollaway': ['roll', 'away'],
    //  "spl"三连辅音难发:给 s-p 开头的近似词多几条解码路径
    'split': ['spilt', 'spit', 'splat'],
    //  词典缺失的法裔/复合词(实测被忽略):拆成近音常见词
    'acey': ['a see', 'ace', 'a c'],
    'deucey': ['do see', 'do c', 'deuce'],
  };

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
    }
    //  追加读法变体词(拆成单词加入)
    for (final w in words.toList()) {
      final vs = _wordVariants[w];
      if (vs != null) words.addAll(vs);
    }
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
    if (s == null || !pttActive || !s.hasResults) return;
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
    //  候选中恰有与本行标准口令读法完全一致者:直接选它为默认
    //  (识别出字面正确口令时无需人工点选)
    final curRow = currentDictationRow;
    if (curRow != null) {
      final spoken =
          CallerTable.spokenForm(curRow.standardCall).toLowerCase();
      final plain =
          curRow.standardCall.toLowerCase()
              .replaceAll(RegExp(r'[^a-z ]'), '')
              .replaceAll(RegExp(r' +'), ' ').trim();
      for (final c in candidates) {
        final cl = c.toLowerCase();
        if (cl == spoken || cl == plain) {
          text = c;
          debugPrint('exact-call candidate: "$c"');
          break;
        }
      }
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
    debugPrint('Only result: "$text" candidates=$candidates');
    lastError = null;
    dictationText = text;
    dictationCandidates = candidates.length > 1 ? candidates : [];
    pttActive = false;
    s.removeListener(_onSampleResult);
    s.clearResults();
    _notify();
  }

  ///  采样结果已消费
  void consumeSample() {
    pttActive = false;
    _notify();
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
    dictationSeqOverride = null;
    callerTable?.removeListener(_onTableChanged);
    callerTable = null;
    tableMode = false;
    panelMinimized = false;
    phase = 'idle';
    _notify();
    debugPrint('exitTable: done');
  }

  Future<CallerTable> openCallerTable(String name) async {
    final old = callerTable;
    if (old != null)
      old.removeListener(_onTableChanged);
    final table = await CallerTable.open(name);
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
  String dictationText = '';

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
    dictationText = text;
    dictationCandidates = [];
    conflictPending = false;
    _notify();
  }

  ///  当前表是否为 Only 工作表(表名以 _Only 结尾)
  bool get onlyMode =>
      callerTable != null && callerTable!.callerName.endsWith('_Only');
  ///  手动选中的采表行序号(点面板行可重选;null=自动取第一个空行)
  int? dictationSeqOverride;

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
    return null;
  }
  ///  源表名 = Only 表名去掉 "_<级别>_Only" 后缀
  ///  (如 "XuJianguo_plus_Only" -> "XuJianguo")
  String get onlySourceName {
    //  级别累积:plus 的 Only 表与 ms 的合并表合并(生成含
    //  ms+plus 全部口令的表);a1 与 plus 合并表合并,依此类推;
    //  ms 级用基础源表
    final n = callerTable?.callerName ?? '';
    final m = RegExp(r'_(plus|a1|a2|c1|c2|c3a|c3b|ms)_Only$')
        .firstMatch(n);
    if (m == null) return n;
    final base = n.substring(0, m.start);
    const order = ['ms', 'plus', 'a1', 'a2', 'c1', 'c2', 'c3a', 'c3b'];
    final lv = order.indexOf(m.group(1)!);
    if (lv <= 0) return base;
    return base + '_' + order[lv - 1];
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

  ///  采表确认:输入框文字写入当前待录行第2列,跳下一行
  Future<bool> confirmDictation(String text,
      {bool force = false}) async {
    final t = callerTable;
    final row = currentDictationRow;
    debugPrint('confirmDictation: text="$text" row=${row?.seq} '
        'table=${t?.callerName}');
    if (t == null || row == null || text.isBlank) return false;
    //  记号冲突检查:与其他行的记号几乎相同时两行会混淆
    //  (查表无法区分),拒绝写入并提示换候选
    final newToken = text.trim();
    for (final r in t.rows) {
      if (r.seq == row.seq) continue;
      for (final tk in r.recognized.split('|')) {
        if (tk.trim().isEmpty) continue;
        if (!force &&
            CallerTable.sentenceError(tk, newToken) < 0.12) {
          debugPrint('token conflict with row ${r.seq}: "$tk"');
          //  带上撞车行的口令名,让口令员知道是和哪条混了
          conflictPending = true;
          lastError =
              'token_conflict:${r.seq}:${r.standardCall}:'
              '再点一次黄框=仍要存入';
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
    }
    //  确认即替换:重新采同一条时删旧记号、记新记号
    await t.updateRow(row.seq,
        recognized: newToken, sort: false);
    conflictPending = false;
    dictationText = '';
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
    dictationSeqOverride = nextRow?.seq;
    _notify();
    return true;
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

  ///  增加记录:以选定的口令名新建一行(第2列空,待圆钮采样),
  ///  光标跳到新行
  Future<void> addRecordWithCall(String call) async {
    final t = callerTable;
    if (t == null) return;
    final name = call.trim().toLowerCase();
    //  同口令已存在:不重复添加,直接跳到已有行
    for (final r in t.rows) {
      if (r.standardCall.trim().toLowerCase() == name) {
        debugPrint('addRecord: "$call" already row ${r.seq}');
        dictationSeqOverride = r.seq;
        dictationText = '';
        _notify();
        return;
      }
    }
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

  ///  口令员在 Calls 画面选中口令:只填入输入行供继续编辑,
  ///  不直接存表;存表时机是口令执行正确(见 completeRecordInit)
  void selectCallForInit(String callTitle) {
    callSelection = callTitle;
    _notify();
  }

  ///  口令执行正确后,把整个口令一起存入记录并恢复识别
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
    speech = speechProvider;
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
    final s = speech;
    if (s == null) return;
    //  流式喊口令:同样限定口令短语,识别结果即为口令,
    //  查映射表(Levenshtein)直接命中,口音容错更好
    s.setSampleGrammar(_onlyTableWords());
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
