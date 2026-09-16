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

import '../common_flutter.dart';
import 'caller_store.dart';
import 'music_monitor.dart';
import 'xfyun_speech_to_text.dart';

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

  VoiceFlow._();
  static final VoiceFlow instance = VoiceFlow._();

  final musicMonitor = MusicMonitor();
  StreamSubscription<MusicEvent>? _musicSub;
  Timer? _orphanTimer;

  ///  当前输入行 State 注入的语音识别器(输入行重建时刷新)
  SpeechToTextProvider? speech;

  ///  输入行注入的"登录并打开映射表"回调(音乐按钮在未登录时
  ///  按下也需要走登录流程)
  Future<bool> Function()? loginRequest;

  ///  idle / awaiting / detecting / ready / calling
  String phase = 'idle';

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

  ///  音乐节拍接管 Dance Speed 前的原设置
  String? savedDancerSpeed;

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
    speech?.cancel();   //  停掉连续识别,让出麦克风
    _notify();
    speech?.sample(localeId: 'en_US');
    return true;
  }

  ///  抬起:收尾给出结果(结果在 hasResults 中被取走)
  void endSample() {
    if (!pttActive) return;
    speech?.stop();
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

  ///  口令员在 Calls 画面点选的口令(输入行取走后清空)
  String? callSelection;

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
  void attach(SpeechToTextProvider speechProvider) {
    speech = speechProvider;
    _orphanTimer?.cancel();
    _orphanTimer = null;
  }

  ///  输入行销毁时调用:若短时间后没有新的输入行接入(即真正离开页面),
  ///  回收整个流程,避免后台残留监测
  void detach() {
    final s = speech;
    _orphanTimer?.cancel();
    _orphanTimer = Timer(const Duration(seconds: 5), () {
      //  若期间有新的输入行接入,speech 已被替换,流程继续
      if (speech == s)
        stop();
    });
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
  ///  用采样按钮增加记录、点行删除、自动排序;麦克风钮另起检索
  Future<void> startTableMode() async {
    await start(listen: false);
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

  //  结束流程(含人工退出):停止一切监测,恢复 Dance Speed,
  //  外部音乐节拍即刻截止使用,其节拍显示也随之消失
  void stop() {
    debugPrint('VoiceFlow.stop (phase=$phase)');
    musicEnabled = false;
    musicMonitor.stopMicMonitor();
    musicMonitor.stopPlaybackWatch();
    restoreDancerSpeed();
    bpm = 0;                        //  节拍清零,显示随之消失
    lastCandidate = null;           //  面板候选高亮清除
    lastCandidateError = 1.0;
    phase = 'idle';
    musicStoppedDuringCall = false;
    playbackWasActive = false;
    _notify();
  }

  //  音乐功能开关(屏幕上的"按下则以外来音乐节拍跳舞"按钮):
  //  未登录  - 按下 = 登录并直接进入音乐模式
  //  识别中(calling) - 按下 = 开启音乐功能,出现"请播放音乐"提示,
  //                     开始监听/节拍检测/节拍接管/停止检测
  //  音乐模式中 - 再按下 = 停止上述功能并恢复系统原设定节拍,
  //                     语音识别不受影响
  Future<void> toggleMusic() async {
    if (phase == 'idle') {
      //  未登录:走登录流程后直接以音乐模式启动
      await loginAndStart(withMusic: true);
      return;
    }
    if (!musicEnabled) {
      musicEnabled = true;
      if (phase == 'calling') {
        //  先停止语音识别释放麦克风,再启动音乐监测
        speech?.cancel();
        phase = 'awaiting';
        _notify();
        await musicMonitor.startMicMonitor();
      }
      //  awaiting/detecting/ready:音乐功能已在运行,无需额外动作
    } else {
      musicEnabled = false;
      musicMonitor.stopMicMonitor();
      musicMonitor.stopPlaybackWatch();
      restoreDancerSpeed();
      if (phase != 'calling') {
        phase = 'calling';
        _notify();
        //  若语音识别尚未开始(原先在等音乐/检测节拍),现在直接开始
        if (!(speech?.isListening ?? false))
          startListening();
      }
      _notify();
    }
  }

  Future<void> _onEvent(MusicEvent e) async {
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
        if (phase == 'detecting') {
          musicMonitor.stopMicMonitor();
          musicMonitor.startPlaybackWatch();
          playbackWasActive = false;
          bpm = e.value ?? 0;
          phase = 'ready';
          _notify();
          if (bpm > 0)
            takeOverDancerSpeed(bpm);
          //  稍等原生 AudioRecord 完全释放后再启动语音识别
          await Future.delayed(const Duration(milliseconds: 500));
          if (phase != 'ready') return;
          startListening();
        }
        break;
      case 'music_stopped':
        //  节拍检测阶段音乐消失(重试窗口中),回到等待
        if (phase == 'detecting') {
          phase = 'awaiting';
          _notify();
        }
        break;
      case 'playback_stopped':
        //  仅在确认过本机播放后生效,外部音源无法跟踪不误报
        if (phase == 'ready' && playbackWasActive) {
          playbackWasActive = false;
          musicStoppedDuringCall = true;
          _notify();
        }
        break;
      case 'playback_started':
        if (phase == 'ready') {
          playbackWasActive = true;
          //  音乐停止后又重新播放:取消识别,重新走节拍检测
          if (musicStoppedDuringCall) {
            musicStoppedDuringCall = false;
            speech?.cancel();
            musicMonitor.stopPlaybackWatch();
            musicMonitor.startMicMonitor();
            _notify();
          }
        }
        break;
      case 'error':
        lastError = 'mic';
        stop();
        break;
    }
  }

  //  节拍检测完成后自动进入语音识别
  void startListening() {
    final s = speech;
    if (s == null) return;
    s.initialize().whenComplete(() {
      if (s.isAvailable) {
        s.listen(
            localeId: 'en_US',
            partialResults: false,
            listenFor: const Duration(seconds: 10),
            pauseFor: const Duration(seconds: 5)
        );
        _notify();
      } else {
        lastError = 'speech';
        stop();
      }
    });
  }

  //  用检测到的节拍临时接管 Dance Speed,原设置保存待恢复
  void takeOverDancerSpeed(int value) {
    try {
      if (savedDancerSpeed == null && !Settings.speed.startsWith('BPM '))
        savedDancerSpeed = Settings.speed;
      Settings.speed = 'BPM $value';
    } catch (err) {
      debugPrint('takeOverDancerSpeed failed: $err');
    }
  }

  void restoreDancerSpeed() {
    final saved = savedDancerSpeed;
    if (saved != null) {
      savedDancerSpeed = null;
      try {
        Settings.speed = saved;
      } catch (err) {
        debugPrint('restoreDancerSpeed failed: $err');
      }
    }
  }

  void _notify() => notifyListeners();

}
