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

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

///  原生侧音乐监测事件
///  type 含义:
///    music_detected   -  麦克风监听到了音乐
///    bpm              -  节拍检测完成,value 为每分钟节拍数
///    music_stopped    -  麦克风监听到音乐停止
///    playback_started -  本机开始有音频播放(语音识别期间的监测手段)
///    playback_stopped -  本机音频播放全部停止
///    error            -  麦克风不可用等错误
class MusicEvent {

  final String type;
  final int? value;
  final double? level;
  final List<int>? audio;
  final String? text;

  const MusicEvent(this.type, this.value,
      {this.level, this.audio, this.text});

}

///  音乐监测(原生平台通道封装)
///  两种模式分时复用,因为麦克风同一时间只能由一方使用:
///  -  麦克风监测:等待音乐出现(能量判定)→ 节拍检测(RMS/onset 算法)
///  -  播放监测:语音识别占用麦克风期间,用系统播放状态回调监测音乐停止/重播
class MusicMonitor {

  static const _channel = MethodChannel('taminations/music');

  //  单例:平台通道的回调是全局唯一的,多实例会互相抢夺
  //  事件回调(后创建的实例收走事件,先创建实例的订阅落空)。
  //  VoiceFlow 与语音识别共用一个实例。
  static final MusicMonitor instance = MusicMonitor._();
  factory MusicMonitor() => instance;

  final _events = StreamController<MusicEvent>.broadcast();

  ///  原生事件流(broadcast,可多处订阅)
  Stream<MusicEvent> get events => _events.stream;

  MusicMonitor._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'event') {
        final args = call.arguments;
        if (args is Map) {
          final data = args['data'];
          _events.add(MusicEvent(
              args['type']?.toString() ?? '',
              args['value'] is int ? args['value'] as int : null,
              level: args['value'] is double ? args['value'] as double : null,
              audio: data is List ? List<int>.from(data) : null,
              text: args['text'] is String ? args['text'] as String : null));
        }
      }
    });
  }

  Future<void> startMicMonitor() async =>
      await _invoke('startMicMonitor');

  Future<void> stopMicMonitor() async =>
      await _invoke('stopMicMonitor');

  Future<void> startPlaybackWatch() async =>
      await _invoke('startPlaybackWatch');

  Future<void> stopPlaybackWatch() async =>
      await _invoke('stopPlaybackWatch');

  ///  注入一个回车键事件(语音识别输出完成后发送)
  Future<void> sendEnterKey() async =>
      await _invoke('sendEnterKey');

  ///  原生语音采集(44.1k MIC 源重采样 16k 推流),
  ///  替代 record 插件在本机采集静音的问题
  Future<void> startSpeechCapture() async =>
      await _invoke('startSpeechCapture');

  Future<void> stopSpeechCapture() async =>
      await _invoke('stopSpeechCapture');

  //  Vosk 离线识别:加载模型(首次运行从 assets 解包,需数秒)
  Future<bool> voskInit() async {
    try {
      return await _channel.invokeMethod('voskInit') ?? false;
    } on PlatformException catch (e) {
      debugPrint('MusicMonitor.voskInit failed: ${e.code} ${e.message}');
      return false;
    }
  }

  ///  开始离线识别(复用原生语音采集线程);
  ///  grammar 为口令词表 JSON(限定解码词汇,null=自由识别);
  ///  gate 为静音门限开关(持续监听传 true:静音/环境噪音不喂
  ///  识别器;PTT 采样传 false:按下即刻意语音)
  Future<void> voskStart({String? grammar, bool gate = false,
      bool consonant = false, double noiseSuppress = 0.4}) async {
    try {
      final args = <String, dynamic>{
        if (grammar != null) 'grammar': grammar,
        'gate': gate,
        'consonant': consonant,
        'noiseSuppress': noiseSuppress,
      };
      await _channel.invokeMethod('voskStart', args);
    } on PlatformException catch (e) {
      debugPrint('MusicMonitor.voskStart failed: ${e.code} ${e.message}');
    }
  }

  ///  停止识别并丢弃剩余内容
  Future<void> voskStop() async => await _invoke('voskStop');

  ///  冲刷:喂静音取finalResult但不停止会话(麦克风命令
  ///  完成时与圆钮松手同工)
  Future<String?> voskFlush() async {
    try {
      return await _channel.invokeMethod('voskFlush');
    } on PlatformException catch (e) {
      debugPrint('MusicMonitor.voskFlush failed: ''${e.code} ${e.message}');
      return null;
    }
  }

  ///  停止识别并把剩余语音收尾成最终结果(JSON 字符串)返回
  Future<String?> voskFinal() async {
    try {
      return await _channel.invokeMethod('voskFinal');
    } on PlatformException {
      return null;
    }
  }

  ///  即时查询本机是否有音乐正在播放
  Future<bool> isMusicPlaying() async {
    try {
      return await _channel.invokeMethod('checkMusicActive') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod(method);
    } on PlatformException catch (e) {
      //  平台不支持/资源占用时记录,由 UI 层的提示条兜底
      debugPrint('MusicMonitor.$method failed: ${e.code} ${e.message}');
    }
  }

  void dispose() {
    _events.close();
    _channel.setMethodCallHandler(null);
  }

  ///  启动探针:确认 Dart->原生通道可用(诊断用)
  void sendAliveProbe() {
    try { _channel.invokeMethod('dartAlive'); } catch (_) {}
  }

}
