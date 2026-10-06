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
import 'dart:convert' show jsonDecode;

import 'package:auto_size_text/auto_size_text.dart';
import 'dart:io' as io;

import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter_file_dialog/flutter_file_dialog.dart' as ffd;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart' as fm;
import 'package:flutter/services.dart' as fs;
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart' as pp;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../common_flutter.dart';
import '../pages/calls_page.dart';
import '../pages/page.dart';
import 'abbreviations_model.dart';
import 'caller_store.dart';
import 'sequencer_model.dart';
import 'voice_flow.dart';
import 'dual_speech_to_text.dart';

class SequenceFrame extends fm.StatefulWidget {
  @override
  _SequenceFrameState createState() => _SequenceFrameState();
}

class _SequenceFrameState extends fm.State<SequenceFrame> {

  final ItemScrollController itemScrollController = ItemScrollController();
  final ItemPositionsListener itemPositionsListener = ItemPositionsListener.create();

  @override
  void initState() {
    super.initState();
    //  监听 VoiceFlow:表退出后恢复输入行(含打开表按钮)
    VoiceFlow.instance.addListener(_onFlowChanged);
  }

  @override
  void dispose() {
    VoiceFlow.instance.removeListener(_onFlowChanged);
    super.dispose();
  }

  void _onFlowChanged() {
    if (mounted) setState(() {});
  }

  @override
  fm.Widget build(fm.BuildContext context) {
    return pp.Consumer<SequencerModel>(
         builder: (context, model, child) {
           return fm.LayoutBuilder(
             builder: (context,constraints) => fm.Column(
               children: [
                 //  口令输入行(原来的位置:紧跟动画区,始终显示)
                 SequencerEditLine(),
                 //  Only 采表:识别结果大字显示(显示框+圆钮+表退出)
                 OnlyCombinedBar(),
                 //  音乐节拍按钮已移至跳舞区左下角(叠加显示,
                 //  不占输入区行数,降低键盘弹起时的布局挤压)
                 CallerTablePanel(),
                 //  采表模式不需要序列列表(表格独占剩余空间)
                 if (!isSmallAndCompact(context) &&
                     !VoiceFlow.instance.onlyMode)
                   fm.Expanded(
                       child: ScrollablePositionedList.builder(
                         itemScrollController: itemScrollController,
                         itemPositionsListener: itemPositionsListener,
                         itemCount: model.calls.length,
                         itemBuilder: itemBuilder,
                       )
                   ),
                 fm.Container(
                   constraints: const fm.BoxConstraints.expand(height: 1),
                     child: fm.Text(model.errorString,key: fm.Key('Error text'),style: fm.TextStyle(fontSize: 0.01)))
               ],
             ),
           );
         },
    );
  }

  //  Builder for one item of the list
  fm.Widget itemBuilder(fm.BuildContext context, int index) {
    return pp.Consumer<SequencerModel>(
        builder: (context, model, child) {
          final currentCall = model.currentCall;
          SequencerCall? call;
          try {
            call = model.calls[index];
          } on Error { call = null; };
          if (currentCall == index) {
            later(() {
              itemScrollController.scrollTo(
                  index: max(index-5, 0),
                  duration: Duration(seconds: 1),
                  curve: fm.Curves.easeInOutCubic);
            });
          }
          return fm.Container(
            decoration: fm.BoxDecoration(
                border: fm.Border(top: fm.BorderSide(width: 1, color: Color.BLACK))),
            child: fm.Material(
              color: (index == currentCall)
                  ? Color.YELLOW
                  : (call?.level?.color ?? Color.WHITE),
              child:
                  model.isComment(call?.name ?? '#')
                      ? _OneLine(call?.name ?? '','')
                      : fm.InkWell(
                      highlightColor: call?.level?.color.darker() ?? Color.WHITE,
                      onTap: () {
                        model.animateAtCall(index);
                      },
                      child: _OneLine(call?.name ?? '',call?.level?.name ?? ''))
            )
          );
        });
  }

}

class SequenceEditButtons extends fm.StatelessWidget {
  @override
  fm.Widget build(fm.BuildContext context) {
    return fm.Container(
      color: Color.FLOOR,
      child: fm.Row(
        children: [
          SequencerUndoButton(),
          SequencerResetButton(),
          SequencerCopyButton(),
          SequencerPasteButton()
        ]
      )
    );
  }
}

///  "按播放音乐节拍跳舞"开关按钮(音乐功能可选项)
///  未按下(默认):小人按系统原设定节拍跳,无任何音乐检测;
///  按下:出现"请播放背景音乐"提示 → 节拍检测(麦克风按钮蓝色闪烁)
///  → 节拍显示并接管 Dance Speed → 音乐停止检测;
///  再次按下:停止上述功能并恢复系统原设定节拍。
///  语音识别不受此按钮影响。未登录时按下无效。
///  Only 采表:识别结果显示条(黄底大字,点=确认,长按=完成建表)
///  Only 模式独立按钮行(📂+采样圆钮),监听 VoiceFlow
///  退出后自动隐藏
///  Only 模式合并行:黄色显示区(左)+圆采样钮(右)
///  点黄色区=识别确认,长按=完成建表
class OnlyCombinedBar extends fm.StatefulWidget {
  @override
  _OnlyCombinedBarState createState() => _OnlyCombinedBarState();
}

class _OnlyCombinedBarState extends fm.State<OnlyCombinedBar> {
  final flow = VoiceFlow.instance;

  @override
  void initState() {
    super.initState();
    flow.addListener(_on);
  }
  @override
  void dispose() {
    flow.removeListener(_on);
    super.dispose();
  }
  void _on() {
    if (mounted && !flow.pttActive) setState(() {});
  }

  @override
  fm.Widget build(fm.BuildContext context) {
    if (!flow.onlyMode) return fm.SizedBox.shrink();
    return fm.Padding(
      padding: fm.EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: fm.Row(children: [
        //  黄色显示区(点击=确认,长按=完成建表)。
        //  独立子组件自行监听刷新:采样中也要即时显示"正在聆听",
        //  而外层(带 PTT 手势)在采样期间保持不重建以保护指针事件
        fm.Expanded(child: _OnlyDictationBox()),
        fm.SizedBox(width: 6),
        //  圆形采样按钮(外观同样独立刷新:按下立刻变蓝)
        fm.Listener(
          behavior: fm.HitTestBehavior.opaque,
          onPointerDown: (e) => flow.startSample(),
          onPointerUp: (e) => flow.endSample(),
          onPointerCancel: (e) => flow.endSample(),
          child: _OnlyPttButton(),
        ),
        fm.SizedBox(width: 6),
        //  表退出:从面板标题栏移来(Only 模式在此,不挡记录)
        _OnlyExitButton(),
      ]),
    );
  }
}

///  Only 模式表退出钮(圆钮右侧):退出当前表,回映射表选择
class _OnlyExitButton extends fm.StatelessWidget {
  @override
  fm.Widget build(fm.BuildContext context) {
    final flow = VoiceFlow.instance;
    return fm.InkWell(
      onTap: () => flow.exitTable(),
      child: fm.Container(
        height: 48,
        padding: fm.EdgeInsets.symmetric(horizontal: 12),
        alignment: fm.Alignment.center,
        decoration: fm.BoxDecoration(
            color: Color.RED,
            borderRadius: fm.BorderRadius.circular(24)),
        child: fm.Row(children: [
          fm.Icon(fm.Icons.exit_to_app, size: 20, color: Color.WHITE),
          fm.SizedBox(width: 4),
          fm.Text('表退出',
              style: fm.TextStyle(
                  fontSize: 16,
                  fontWeight: fm.FontWeight.bold,
                  color: Color.WHITE)),
        ]),
      ),
    );
  }
}

///  Only 显示区:识别结果/聆听状态大字显示。
///  自行监听 VoiceFlow(含采样期间),保证按下立即有画面反馈
class _OnlyDictationBox extends fm.StatefulWidget {
  @override
  _OnlyDictationBoxState createState() => _OnlyDictationBoxState();
}

class _OnlyDictationBoxState extends fm.State<_OnlyDictationBox> {
  final flow = VoiceFlow.instance;

  @override
  void initState() {
    super.initState();
    flow.addListener(_on);
  }
  @override
  void dispose() {
    flow.removeListener(_on);
    super.dispose();
  }
  void _on() {
    if (mounted) setState(() {});
  }

  //  冲突提示详细内容:与哪一行、什么口令、什么记号雷同
  //  (err 格式:token_conflict:行号|口令|记号|操作提示)
  String conflictMessage(String err) {
    final p = err.split('|');
    final seq = p[0].split(':')[1];
    final call = p.length > 1 ? p[1] : '';
    final token = p.length > 2 ? p[2] : '';
    final hint = p.length > 3 ? p[3] : '';
    return '✕ 与第$seq行雷同:「$call」(记号:$token) $hint';
  }

  //  输入口令 -> 列出全部匹配行。对话框内容固定高度,
  //  列表 Expanded 填满——有界父级内滚动与点击可靠
  Future<void> _prefixSearchDialog() async {
    final controller = fm.TextEditingController();
    CallerRow? selected;
    await fm.showDialog(
        context: context,
        builder: (ctx) => fm.StatefulBuilder(builder: (ctx, setD) {
              List<CallerRow> matches = [];
              final p = controller.text.trim().toLowerCase();
              final t = flow.callerTable;
              if (p.isNotEmpty && t != null) {
                for (final r in t.rows) {
                  if (r.standardCall.toLowerCase().startsWith(p))
                    matches.add(r);
                }
                if (matches.isEmpty) {
                  for (final r in t.rows) {
                    if (r.standardCall.toLowerCase().contains(p))
                      matches.add(r);
                  }
                }
              }
              return fm.AlertDialog(
                title: fm.Text('搜索口令(第三列)',
                    style: fm.TextStyle(fontSize: 20)),
                content: fm.SizedBox(
                  width: double.maxFinite,
                  height: 560,
                  child: fm.Column(
                    children: [
                      fm.TextField(
                        controller: controller,
                        autofocus: true,
                        style: fm.TextStyle(fontSize: 24),
                        decoration: fm.InputDecoration(
                            hintText: '如: cir',
                            hintStyle: fm.TextStyle(fontSize: 20)),
                        onChanged: (_) => setD(() {}),
                      ),
                      fm.Padding(
                          padding: fm.EdgeInsets.only(top: 6, bottom: 4),
                          child: fm.Row(children: [
                            fm.Text(
                                matches.isEmpty
                                    ? (p.isEmpty ? '请输入字母' : '(无匹配行)')
                                    : '待显示 ${matches.length} 行'
                                      '${matches.length > 14 ? '(可滚动)' : ''}',
                                style: fm.TextStyle(
                                    fontSize: 16, color: Color.GRAY)),
                            fm.Spacer(),
                            if (p.isNotEmpty && matches.isEmpty)
                              fm.TextButton.icon(
                                  onPressed: () async {
                                    final tb = flow.callerTable;
                                    if (tb == null) return;
                                    final row = await tb.addRow(
                                        recognized: '',
                                        standardCall:
                                            controller.text.trim());
                                    selected = row;
                                    fm.Navigator.of(ctx).pop();
                                  },
                                  icon: fm.Icon(fm.Icons.add,
                                      color: Color.BLUE),
                                  label: fm.Text('添加自定义口令',
                                      style: fm.TextStyle(
                                          fontSize: 18,
                                          color: Color.BLUE))),
                          ])),
                      fm.Expanded(
                          child: fm.ListView.builder(
                        physics: fm.AlwaysScrollableScrollPhysics(),
                        itemCount: matches.length,
                        itemBuilder: (lctx, i) {
                          final m = matches[i];
                          return fm.ListTile(
                            dense: true,
                            title: fm.Text('第${m.seq}行  ${m.standardCall}',
                                style: fm.TextStyle(fontSize: 20)),
                            onTap: () {
                              selected = m;
                              fm.Navigator.of(ctx).pop();
                            },
                          );
                        },
                      )),
                    ],
                  ),
                ),
                actions: [
                  fm.TextButton(
                      onPressed: () => fm.Navigator.of(ctx).pop(),
                      child: fm.Text('关闭',
                          style: fm.TextStyle(fontSize: 18))),
                ],
              );
            }));
    if (selected != null) flow.selectDictationRow(selected!.seq);
  }

  @override
  fm.Widget build(fm.BuildContext context) {
    return fm.GestureDetector(
      onTap: () {
        if (flow.pttActive) return;
        //  冲突警示后再点一次黄框=人类决断:强制存入
        //  (AI 已陈述理由,决定权在人类;标志不超时)
        if (flow.conflictPending &&
            flow.dictationText.isNotBlank) {
          flow.confirmDictation(flow.dictationText, force: true);
          return;
        }
        if (flow.dictationText.isNotBlank) {
          flow.confirmDictation(flow.dictationText);
        } else if (flow.callerTable != null) {
          //  空闲时点显示框:输入标准口令前几个字母,
          //  自动查到该行并选中为当前采表行
          _prefixSearchDialog();
        }
      },
      onLongPress: () async {
        final n = await flow.finishOnlyTable();
        if (n == null && mounted) {
          final err = flow.lastError ?? '';
          fm.ScaffoldMessenger.of(context).showSnackBar(fm.SnackBar(
              backgroundColor: Color.RED,
              duration: const Duration(seconds: 5),
              content: fm.Text(
                  err.startsWith('merge_aborted:')
                      ? err.replaceFirst('merge_aborted:', '')
                      : '合并未完成',
                  style: fm.TextStyle(fontSize: 18))));
        }
        if (n != null && mounted)
          fm.ScaffoldMessenger.of(context).showSnackBar(
              fm.SnackBar(backgroundColor: Color.BLUE,
                  content: fm.Text(
                      '已另存 ${flow.onlyTargetName}(共$n条)',
                      style: fm.TextStyle(fontSize: 18))));
      },
      child: fm.AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: fm.EdgeInsets.all(4),
        //  采样中浅蓝底"正在聆听",有结果黄底,平时白底
        color: flow.pttActive
            ? Color(0xffcfe8ff)
            : (flow.dictationText.isNotBlank ? Color.YELLOW : Color.WHITE),
        constraints: fm.BoxConstraints(minHeight: 44),
        alignment: fm.Alignment.centerLeft,
        //  有候选时:上方当前结果,下方候选条(点选即采用)
        child: flow.dictationCandidates.isEmpty
            ? fm.Text(
            flow.lastError == 'licc_quota'
                ? '⚠ 额度'
                : (flow.lastError != null &&
                        flow.lastError!.startsWith('token_conflict')
                    ? conflictMessage(flow.lastError!)
                    : (flow.lastError == 'not_heard'
                    ? '✕ 没听清,请再按住重念'
                    : (flow.pttActive
                    ? (flow.dictationSegmentText.isNotBlank
                        //  分段取样:每段查表结果累加组合(不冲掉),
                        //  后跟当前段的实时识别
                        ? '${flow.dictationSegmentText} | ● ${flow.dictationPartial}'
                        : (flow.dictationPartial.isNotBlank
                        ? '● ${flow.dictationPartial}'
                        : '● 正在聆听…(松开结束)'))
                    : (flow.dictationText.isNotBlank
                        ? '${flow.dictationText} →'
                        : '🎙 朗读')))),
            style: fm.TextStyle(fontSize: 20,
                fontWeight: fm.FontWeight.bold))
            : fm.Column(
                mainAxisSize: fm.MainAxisSize.min,
                crossAxisAlignment: fm.CrossAxisAlignment.start,
                children: [
                  fm.Text(
                      flow.dictationText.isNotBlank
                          ? '${flow.dictationText} →'
                          : '🎙 朗读',
                      style: fm.TextStyle(fontSize: 20,
                          fontWeight: fm.FontWeight.bold)),
                  //  候选条:点一下即选为采表结果。
                  //  条目多时自动滚动(可上下滑动观察),
                  //  不挤压显示框也不溢出屏幕
                  fm.SingleChildScrollView(
                    physics: fm.AlwaysScrollableScrollPhysics(),
                    child: fm.Wrap(
                        spacing: 6,
                        runSpacing: 2,
                      children: [
                        for (final c in flow.dictationCandidates)
                          fm.InkWell(
                            onTap: () => flow.chooseDictation(c),
                                child: fm.Container(
                                  padding: fm.EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  decoration: fm.BoxDecoration(
                                      border: fm.Border.all(
                                          color: Color.BLUE,
                                          width: 1.5),
                                      borderRadius:
                                          fm.BorderRadius.circular(6),
                                      color: Color.WHITE),
                                  child: fm.Text(c,
                                      style: fm.TextStyle(
                                          fontSize: 16,
                                          color: Color.BLUE,
                                          fontWeight:
                                              fm.FontWeight.bold)),
                                ),
                          )
                      ]),
                  ),
                ]),
      ),
    );
  }
}

///  Only 圆形采样按钮外观:按下采样时变蓝放大,
///  松开还原。独立子组件,采样期间可安全刷新
class _OnlyPttButton extends fm.StatefulWidget {
  @override
  _OnlyPttButtonState createState() => _OnlyPttButtonState();
}

class _OnlyPttButtonState extends fm.State<_OnlyPttButton> {
  final flow = VoiceFlow.instance;

  @override
  void initState() {
    super.initState();
    flow.addListener(_on);
  }
  @override
  void dispose() {
    flow.removeListener(_on);
    super.dispose();
  }
  void _on() {
    if (mounted) setState(() {});
  }

  @override
  fm.Widget build(fm.BuildContext context) {
    //  图标恒定(录音图标),尺寸恒定;状态只用背景色表达:
    //  黑=空闲,蓝=采样中——图标不切换,便于说明书描述
    final active = flow.pttActive;
    return fm.AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 48,
      height: 48,
      alignment: fm.Alignment.center,
      decoration: fm.BoxDecoration(
          color: active ? fm.Colors.blue : Color.BLACK,
          shape: fm.BoxShape.circle),
      child: fm.Icon(fm.Icons.record_voice_over,
          color: Color.WHITE, size: 24),
    );
  }
}

class OnlyButtonRow extends fm.StatefulWidget {
  @override
  _OnlyButtonRowState createState() => _OnlyButtonRowState();
}

class _OnlyButtonRowState extends fm.State<OnlyButtonRow> {
  final flow = VoiceFlow.instance;

  @override
  void initState() {
    super.initState();
    flow.addListener(_on);
  }
  @override
  void dispose() {
    flow.removeListener(_on);
    super.dispose();
  }
  void _on() {
    //  PTT 活动期间不重建:重建会断掉 InkWell 手势(onTapUp 丢失)
    if (mounted && !flow.pttActive) setState(() {});
  }

  @override
  fm.Widget build(fm.BuildContext context) {
    if (!flow.onlyMode) return fm.SizedBox.shrink();
    return fm.Padding(
      padding: fm.EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: fm.Row(children: [
        
        fm.Spacer(),
        fm.InkWell(
          onTapDown: (_) {
            debugPrint('PTT down');
            flow.startSample();
          },
          onTapUp: (_) => flow.endSample(),
          onTapCancel: () => flow.endSample(),
          child: fm.Container(
            width: 60, height: 60,
            alignment: fm.Alignment.center,
            decoration: fm.BoxDecoration(
                color: flow.pttActive ? fm.Colors.blue : Color.BLACK,
                shape: fm.BoxShape.circle),
            child: fm.Icon(fm.Icons.record_voice_over,
                color: Color.WHITE, size: 32),
          ),
        ),
      ]),
    );
  }
}

class OnlyDisplayBar extends fm.StatefulWidget {
  @override
  _OnlyDisplayBarState createState() => _OnlyDisplayBarState();
}

class _OnlyDisplayBarState extends fm.State<OnlyDisplayBar> {
  final flow = VoiceFlow.instance;

  @override
  void initState() {
    super.initState();
    flow.addListener(_onChanged);
  }
  @override
  void dispose() {
    flow.removeListener(_onChanged);
    super.dispose();
  }
  void _onChanged() {
    if (mounted) setState(() {});
    //  记号碰撞体检:口令不同而语音识别(第2列)相同的行,
    //  亮出行号提示重新识别(每次开表提示一次)
    if (mounted &&
        flow.tokenCollisionRows.isNotEmpty &&
        !flow.collisionNoticeShown) {
      flow.collisionNoticeShown = true;
      Future.microtask(() => _showCollisionDialog());
    }
  }

  //  碰撞行号清单(需重新识别)
  Future<void> _showCollisionDialog() async {
    await fm.showDialog(
        context: context,
        builder: (ctx) => fm.AlertDialog(
              title: fm.Text('记号相同,需重新识别',
                  style: fm.TextStyle(fontSize: 22, color: Color.RED)),
              content: fm.SizedBox(
                width: double.maxFinite,
                height: 420,
                child: fm.ListView(children: [
                  fm.Text(
                      '以下各行标准口令不同而语音识别(第2列)相同,'
                      '喊口令时无法区分。请对相关行用圆钮重新采样:',
                      style: fm.TextStyle(fontSize: 18)),
                  for (final line in flow.tokenCollisionRows)
                    fm.Padding(
                        padding: fm.EdgeInsets.only(top: 6),
                        child: fm.Text(line,
                            style: fm.TextStyle(
                                fontSize: 18, color: Color.RED))),
                ]),
              ),
              actions: [
                fm.TextButton(
                    onPressed: () => fm.Navigator.of(ctx).pop(),
                    child: fm.Text('知道了',
                        style: fm.TextStyle(fontSize: 18))),
              ],
            ));
  }

  @override
  fm.Widget build(fm.BuildContext context) {
    if (!flow.onlyMode) return fm.SizedBox.shrink();
    return fm.GestureDetector(
      onTap: () {
        if (flow.dictationText.isNotBlank)
          flow.confirmDictation(flow.dictationText);
      },
      onLongPress: () async {
        final n = await flow.finishOnlyTable();
        if (n == null && mounted) {
          final err = flow.lastError ?? '';
          fm.ScaffoldMessenger.of(context).showSnackBar(fm.SnackBar(
              backgroundColor: Color.RED,
              duration: const Duration(seconds: 5),
              content: fm.Text(
                  err.startsWith('merge_aborted:')
                      ? err.replaceFirst('merge_aborted:', '')
                      : '合并未完成',
                  style: fm.TextStyle(fontSize: 18))));
        }
        if (n != null && mounted)
          fm.ScaffoldMessenger.of(context).showSnackBar(
              fm.SnackBar(backgroundColor: Color.BLUE,
                  content: fm.Text(
                      '已另存 ${flow.onlyTargetName}(共$n条)',
                      style: fm.TextStyle(fontSize: 18))));
      },
      child: fm.Container(
        width: double.infinity,
        color: flow.dictationText.isNotBlank ? Color.YELLOW : Color.WHITE,
        padding: fm.EdgeInsets.symmetric(vertical: 3, horizontal: 6),
        child: fm.Text(
            flow.lastError == 'licc_quota'
                ? '⚠ 今日讯飞额度已用完,明天再试'
                : (flow.pttActive
                    ? '● 正在聆听... (松开结束)'
                    : (flow.dictationText.isNotBlank
                    ? '识别结果: ${flow.dictationText}  (点=确认)'
                        : '(按住🎙朗读,抬起出结果)')),
            style: fm.TextStyle(fontSize: 22,
                fontWeight: fm.FontWeight.bold)),
      ),
    );
  }
}

///  Only 采表工具栏:识别确认 / 完成建表
class OnlyTableToolbar extends fm.StatefulWidget {
  @override
  _OnlyTableToolbarState createState() => _OnlyTableToolbarState();
}

class _OnlyTableToolbarState extends fm.State<OnlyTableToolbar> {
  final flow = VoiceFlow.instance;
  final _textController = fm.TextEditingController();

  @override
  void initState() {
    super.initState();
    flow.addListener(() { if (mounted) setState(() {}); });
  }
  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  fm.Widget build(fm.BuildContext context) {
    if (!flow.onlyMode) return fm.SizedBox.shrink();
    return fm.Padding(
      padding: fm.EdgeInsets.only(top: 2, left: 4, right: 4),
      child: fm.Row(children: [
        fm.Expanded(child: Button('识别确认', onPressed: () {
          //  从序列器输入行取文字
          if (flow.dictationText.isNotBlank)
            flow.confirmDictation(flow.dictationText);
        })),
        fm.SizedBox(width: 6),
        fm.Expanded(child: Button('完成建表', onPressed: () async {
          final n = await flow.finishOnlyTable();
          if (n == null && mounted) {
            final err = flow.lastError ?? '';
            fm.ScaffoldMessenger.of(context).showSnackBar(
                fm.SnackBar(backgroundColor: Color.RED,
                    duration: const Duration(seconds: 5),
                    content: fm.Text(
                        err.startsWith('merge_aborted:')
                            ? err.replaceFirst('merge_aborted:', '')
                            : '合并未完成',
                        style: fm.TextStyle(fontSize: 18))));
          }
          if (n != null && mounted)
            fm.ScaffoldMessenger.of(context).showSnackBar(
                fm.SnackBar(backgroundColor: Color.BLUE,
                    content: fm.Text(
                        '已另存 ${flow.onlyTargetName}(共$n条)',
                        style: fm.TextStyle(fontSize: 18))));
        })),
      ]),
    );
  }
}

///  当前口令员映射表面板:流程期间全程显示表内全部记录,
///  四列依次为 序号 / 语音识别结果 / 标准口令 / 口令所属级别,
///  记录增删时实时刷新(经 VoiceFlow 转发 CallerTable 的变更通知)
class CallerTablePanel extends fm.StatefulWidget {
  @override
  _CallerTablePanelState createState() => _CallerTablePanelState();
}

class _CallerTablePanelState extends fm.State<CallerTablePanel> {

  final flow = VoiceFlow.instance;
  final itemScrollController = ItemScrollController();

  CallerRow? _lastScrolledCandidate;
  CallerRow? _lastScrolledPending;
  CallerRow? _lastScrolledCursor;

  //  显隐状态由 VoiceFlow 持有(检索模式自动收起,表管理模式展开,
  //  手动切换随时可用,输入行重建不丢)
  bool get minimized => flow.panelMinimized;

  //  列宽(可拖动调整,持久保存,重开应用不丢):
  //  序号列宽为像素值;识别结果列占(识别+标准)两列总宽的比例
  double _recognizedRatio = 0.25;
  double _seqColW = 36;
  static const _ratioPrefKey = '映射表识别列宽占比';
  static const _seqWidPrefKey = '映射表序号列宽';
  static const double _dragColW = 30;  //  列宽把手列固定宽
  double _twoColsW = 1;                //  最近一次布局的两列总宽

  @override
  void initState() {
    super.initState();
    flow.addListener(_onChanged);
    _loadRatio();
  }

  Future<void> _loadRatio() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getDouble(_ratioPrefKey);
      if (v != null && v >= 0.12 && v <= 0.88) {
        setState(() => _recognizedRatio = v);
      }
      final s = prefs.getDouble(_seqWidPrefKey);
      if (s != null && s >= 28 && s <= 140) {
        setState(() => _seqColW = s);
      }
    } catch (_) {}
  }

  Future<void> _saveRatio() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_ratioPrefKey, _recognizedRatio);
      await prefs.setDouble(_seqWidPrefKey, _seqColW);
    } catch (_) {}
  }

  //  拖动序号列把手:直接按像素增减序号列宽
  void _onSeqDrag(fm.DragUpdateDetails d) {
    setState(() {
      _seqColW = (_seqColW + d.delta.dx).clamp(28.0, 140.0);
    });
  }

  //  拖动把手:按位移占两列总宽的比例调整列宽分配
  void _onDividerDrag(fm.DragUpdateDetails d) {
    setState(() {
      _recognizedRatio =
          (_recognizedRatio + d.delta.dx / _twoColsW).clamp(0.12, 0.88);
    });
  }

  @override
  void dispose() {
    flow.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    //  表变化时重置跟踪(新表打开时触发首次滚动)
    final t = flow.callerTable;
    if (t != null && !identical(t, _lastTable)) {
      _lastTable = t;
      _lastScrolledCursor = null;
      _lastScrolledPending = null;
      _lastScrolledCandidate = null;
    }
    _scrollToCenterIfNeeded();
  }
  CallerTable? _lastTable;

  //  需要居中显示的记录,按优先级:
  //  1) 录入时新插入的待补全记录(先插入,排序,居中显示,高亮)
  //  2) 语音查表的候选记录
  void _scrollToCursor() {
    final table = flow.callerTable;
    if (table == null || minimized || !flow.onlyMode) return;
    final cursor = flow.currentDictationRow;
    if (cursor == null) return;
    //  同一光标只定位一次:识别期间每次局部结果都会触发
    //  _onChanged,若不判重,jumpTo 会在整个说话过程中
    //  反复执行,面板不断跳动(用户手动滚动也被拉回)
    if (_scrolledCursorSeq == cursor.seq) return;
    _scrolledCursorSeq = cursor.seq;
    final index = table.rows.indexOf(cursor);
    if (index < 0) return;
    //  jumpTo 立即定位,不用动画(动画期间行会消失)
    fm.WidgetsBinding.instance.addPostFrameCallback((_) {
      itemScrollController.jumpTo(
          index: index,
          alignment: 0.15);  //  光标行在显示区约第2行位置
    });
  }
  int? _scrolledCursorSeq;

  void _scrollToCenterIfNeeded() {
    final table = flow.callerTable;
    if (table == null || minimized) return;
    //  Only 模式:光标行强制定位到固定物理位置(第2行)
    if (flow.onlyMode) {
      _scrollToCursor();
      return;
    }
    //  非 Only 模式:候选/待补全记录居中
    CallerRow? target;
    final pending = flow.pendingRecord;
    if (pending != null && !identical(pending, _lastScrolledPending)) {
      _lastScrolledPending = pending;
      target = pending;
    }
    final candidate = flow.lastCandidate;
    //  按行号判断是否新候选(identical 在表重建后失配)
    if (target == null && candidate != null &&
        candidate.seq != (_lastScrolledCandidate?.seq ?? -1)) {
      _lastScrolledCandidate = candidate;
      target = candidate;
    }
    if (target == null) return;
    final index = table.rows.indexWhere((r) => identical(r, target));
    if (index < 0) return;
    fm.WidgetsBinding.instance.addPostFrameCallback((_) {
      itemScrollController.scrollTo(
          index: index, alignment: 0.5, duration: Duration(milliseconds: 300));
    });
  }

  //  长按行弹菜单(编辑第3列/删除该行)。
  //  所有表可用:合并表若混入坏行(如误采样到错误行的记号),
  //  长按删除即可修复,不必重建整表
  Future<void> _rowActionMenu(CallerRow row) async {
    final action = await fm.showDialog<String>(
        context: context,
        builder: (ctx) => fm.AlertDialog(
          title: fm.Text('第${row.seq}行'),
          content: fm.Text(
              '${row.recognized} → ${row.standardCall}',
              style: fm.TextStyle(fontSize: 18)),
          actions: [
            fm.TextButton(
                onPressed: () => fm.Navigator.of(ctx).pop('edit'),
                child: fm.Text('编辑口令')),
            fm.TextButton(
                onPressed: () => fm.Navigator.of(ctx).pop('delete'),
                child: fm.Text('删除',
                    style: fm.TextStyle(color: Color.RED))),
            fm.TextButton(
                onPressed: () => fm.Navigator.of(ctx).pop(),
                child: fm.Text('取消')),
          ],
        ));
    if (action == 'edit') {
      await _editStandardCall(row);
    } else if (action == 'delete') {
      await _deleteRow(row);
    }
  }

  //  Only 模式:手动编辑第3列(标准口令)内容。
  //  返回确认的文本(取消返回 null)——"键入口令"路径
  //  复用此画面,由调用方做去重等后续处理
  Future<String?> _editStandardCall(CallerRow row) async {
    final controller = fm.TextEditingController()
      ..text = row.standardCall;
    final confirmed = await fm.showDialog<String>(
        context: context,
        builder: (ctx) => fm.AlertDialog(
          title: fm.Text('第${row.seq}行 口令编辑'),
          content: fm.TextField(
            controller: controller,
            autofocus: true,
            maxLines: 2,
            style: fm.TextStyle(fontSize: 22),
            decoration: fm.InputDecoration(
                labelText: '标准口令',
                labelStyle: fm.TextStyle(fontSize: 18)),
          ),
          actions: [
            fm.TextButton(
                onPressed: () => fm.Navigator.of(ctx).pop(),
                child: fm.Text('取消')),
            fm.TextButton(
                onPressed: () =>
                    fm.Navigator.of(ctx).pop(controller.text),
                child: fm.Text('确定')),
          ],
        ));
    controller.dispose();
    if (confirmed != null && confirmed.trim().isNotBlank) {
      final table = flow.callerTable;
      if (table != null)
        await table.updateRow(row.seq,
            standardCall: confirmed.trim(), sort: false);
    }
    return confirmed;
  }

  //  口令员删除所选记录(带确认)
  Future<void> _deleteRow(CallerRow row) async {
    final table = flow.callerTable;
    if (table == null) return;
    final confirmed = await fm.showDialog<bool>(
        context: context,
        builder: (ctx) => fm.AlertDialog(
          title: fm.Text('删除记录'),
          content: fm.Text(
              '确定删除第${row.seq}条?\n${row.recognized} → '
              '${row.standardCall.isBlank ? '(待补全)' : row.standardCall}',
              style: fm.TextStyle(fontSize: 20)),
          actions: [
            fm.TextButton(onPressed: () => fm.Navigator.of(ctx).pop(false),
                child: fm.Text('取消')),
            fm.TextButton(onPressed: () => fm.Navigator.of(ctx).pop(true),
                child: fm.Text('删除')),
          ],
        ));
    if (confirmed == true)
      await table.removeRow(row.seq);
  }

  @override
  fm.Widget build(fm.BuildContext context) {
    final table = flow.callerTable;
    //  有表即显示(收起条);语音会话是否激活不影响
    if (table == null)
      return fm.SizedBox.shrink();
    //  极小化:只显示标题行
    if (minimized)
      return fm.InkWell(
        onTap: () {
          flow.setPanelMinimized(false);
          //  展开后把待补全/候选记录居中
          _lastScrolledPending = null;
          _lastScrolledCandidate = null;
          _scrollToCenterIfNeeded();
        },
        child: fm.Container(
          width: double.infinity,
          color: Color.FLOOR,
          padding: fm.EdgeInsets.only(left: 12, top: 3, bottom: 3),
          child: fm.Row(children: [
            fm.Icon(fm.Icons.unfold_more, size: 20),
            fm.SizedBox(width: 6),
            fm.Text(
                '${flow.callerName}(${table.rows.length}条)'
                '${flow.tableFlags.isNotBlank ? ' ${flow.tableFlags}' : ''} ▸',
                style: fm.TextStyle(
                    fontWeight: fm.FontWeight.bold, fontSize: 16)),
          ]),
        ),
      );
    //  展开时:Only 采表占满剩余空间(表面板最大化);
    //  其他模式固定高度,不自动扩大,不影响跳舞区域
    final body = fm.LayoutBuilder(builder: (context, constraints) {
        //  两列(识别结果/标准口令)总宽 =
        //  面板宽 - 内边距 - 序号列 - 两个把手槽
        _twoColsW = constraints.maxWidth -
            12 - 8 - _seqColW - _dragColW * 2;
        if (_twoColsW < 100) _twoColsW = 100;
        final recogW = _twoColsW * _recognizedRatio;
        return fm.Column(
          crossAxisAlignment: fm.CrossAxisAlignment.start,
          children: [
            //  第一行:表名(口令员名/条数,居中)+ 极小化
            fm.Container(
              width: double.infinity,
              color: Color.FLOOR,
              padding: fm.EdgeInsets.only(left: 12, top: 2, bottom: 2),
              child: fm.Row(children: [
                fm.Expanded(
                  child: fm.GestureDetector(
                    //  Only表:长按=增加记录;非Only表:长按=按口令
                    //  搜索行(滚动定位+高亮)
                    onLongPress:
                        flow.onlyMode ? _addRecordDialog : _panelSearch,
                    child: fm.Center(
                      child: fm.Text(
                      '${flow.callerName}(${table.rows.length}条)'
                          '${flow.tableFlags.isNotBlank ? ' ${flow.tableFlags}' : ''}',
                      style: fm.TextStyle(
                      fontWeight: fm.FontWeight.bold, fontSize: 16)),
                    ),
                  ),
                ),
                //  Only表:增行(多归一扩容)与清理全表按钮
                if (flow.onlyMode) ...[
                  fm.InkWell(
                    onTap: () async {
                      //  高亮行上方插入全空行,随即进入口令编辑
                      //  (键入标准口令;取消则留空行以后再填)。
                      //  无高亮行时:询问操作者插入位置(行号)
                      CallerRow? row;
                      if (flow.currentDictationRow != null) {
                        row = await flow.addReadingRow();
                      } else {
                        final t = flow.callerTable;
                        if (t == null || t.rows.isEmpty) return;
                        //  询问操作者插入位置(行号)
                        final posCtl = fm.TextEditingController();
                        final input = await fm.showDialog<String>(
                            context: context,
                            builder: (pctx) => fm.AlertDialog(
                              title: fm.Text('增行位置',
                                  style: fm.TextStyle(fontSize: 22)),
                              content: fm.TextField(
                                  controller: posCtl,
                                  autofocus: true,
                                  keyboardType:
                                      fm.TextInputType.number,
                                  style: fm.TextStyle(fontSize: 22),
                                  decoration: fm.InputDecoration(
                                      hintText:
                                          '插到第几行之上?(1-${t.rows.length})',
                                      hintStyle:
                                          fm.TextStyle(fontSize: 18))),
                              actions: [
                                fm.TextButton(
                                    onPressed: () =>
                                        fm.Navigator.of(pctx).pop(),
                                    child: fm.Text('取消',
                                        style: fm.TextStyle(
                                            fontSize: 18))),
                                fm.TextButton(
                                    onPressed: () => fm.Navigator.of(pctx)
                                        .pop(posCtl.text),
                                    child: fm.Text('确定',
                                        style: fm.TextStyle(
                                            fontSize: 18))),
                              ],
                            ));
                        posCtl.dispose();
                        final n = int.tryParse((input ?? '').trim());
                        if (n == null || n < 1 || n > t.rows.length) {
                          return;
                        }
                        row = await flow.addReadingRowAt(n);
                      }
                      if (row != null && mounted) {
                        await _editStandardCall(row);
                      }
                    },
                    child: fm.Container(
                      margin: fm.EdgeInsets.only(right: 6),
                      padding: fm.EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: fm.BoxDecoration(
                          border: fm.Border.all(color: Color.BLUE),
                          borderRadius:
                              fm.BorderRadius.circular(6)),
                      child: fm.Text('增行',
                          style: fm.TextStyle(
                              fontSize: 14, color: Color.BLUE,
                              fontWeight: fm.FontWeight.bold)),
                    ),
                  ),
                  fm.InkWell(
                    onTap: _cleanupTableDialog,
                    child: fm.Container(
                      margin: fm.EdgeInsets.only(right: 6),
                      padding: fm.EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: fm.BoxDecoration(
                          border: fm.Border.all(color: Color.RED),
                          borderRadius:
                              fm.BorderRadius.circular(6)),
                      child: fm.Text('清理',
                          style: fm.TextStyle(
                              fontSize: 14, color: Color.RED,
                              fontWeight: fm.FontWeight.bold)),
                    ),
                  ),
                ],
                //  表退出:红底白字大按钮
                //  (Only 模式移到下方圆钮旁,不占面板行)
                if (!flow.onlyMode)
                fm.Container(
                  decoration: fm.BoxDecoration(
                      color: Color.RED,
                      borderRadius: fm.BorderRadius.circular(6)),
                  margin: fm.EdgeInsets.only(right: 6),
                  child: fm.InkWell(
                    onTap: () {
                      //  退出:完整复位到进入时画面
                      flow.exitTable();
                    },
                    borderRadius: fm.BorderRadius.circular(6),
                    child: fm.Padding(
                      padding: fm.EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      child: fm.Row(children: [
                        fm.Icon(fm.Icons.exit_to_app,
                            size: 18, color: Color.WHITE),
                        fm.SizedBox(width: 4),
                        fm.Text('表退出',
                            style: fm.TextStyle(fontSize: 16,
                                fontWeight: fm.FontWeight.bold,
                                color: Color.WHITE)),
                      ]),
                    ),
                  ),
                ),
                //  极小化按钮:关闭显示,后台工作不受影响
                fm.InkWell(
                  onTap: () => flow.setPanelMinimized(true),
                  child: fm.Padding(
                    padding:
                        fm.EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: fm.Icon(fm.Icons.unfold_less, size: 20),
                  ),
                ),
              ]),
            ),
            //  第二行:列头(三列标题 + 两个可拖动列宽把手)
            _headerRow(recogW),
            fm.Expanded(
              child: table.rows.isEmpty
                  ? fm.Container(
                      alignment: fm.Alignment.center,
                      child: fm.Text('(空表,语音识别将进入记录初始化)',
                          style: fm.TextStyle(
                              fontSize: 18, color: Color.BLACK)))
                  : ScrollablePositionedList.builder(
                      itemScrollController: itemScrollController,
                      padding: fm.EdgeInsets.zero,
                      itemCount: table.rows.length,
                      itemBuilder: (context, index) {
                        final row = table.rows[index];
                        //  Only 采表:当前目标行(光标)蓝底+箭头标记
                        final isCursor = flow.onlyMode &&
                            identical(flow.currentDictationRow, row);
                        //  待补全的记录(第三列为空)黄色;
                        //  语音查表的候选记录蓝色边框突出显示
                        final pending = !flow.onlyMode &&
                            row.standardCall.isBlank &&
                            identical(flow.pendingRecord, row);
                        //  命中候选高亮:按行号比对(identical 在
                        //  表对象重建后会失配,导致只居中不高亮)
                        final isCandidate = flow.lastCandidate != null &&
                            flow.lastCandidate!.seq == row.seq;
                        return fm.InkWell(
                          //  Only 模式:点行=选定为采表目标;
                          //   长按=编辑第3列/删除
                          //  非Only表只读(增删只在Only表做)
                          onTap: () => flow.onlyMode
                              ? flow.selectDictationRow(row.seq)
                              : null,
                          onLongPress:
                              flow.callerTable != null
                              ? () => _rowActionMenu(row)
                              : null,
                          child: fm.Container(
                            color: isCursor
                                ? Color(0xff87CEEB)
                                : (pending
                                    ? Color.YELLOW
                                    : (isCandidate ? Color(0xffe0f0ff) : null)),
                            decoration: pending || isCandidate
                                ? null
                                : fm.BoxDecoration(
                                    border: fm.Border(
                                        bottom: fm.BorderSide(
                                            width: 1,
                                            color: Color.LIGHTGREY))),
                            padding: fm.EdgeInsets.only(
                                left: 12, right: 8),
                            child: fm.Row(
                              crossAxisAlignment:
                                  fm.CrossAxisAlignment.start,
                              children: [
                                fm.SizedBox(
                                    width: _seqColW,
                                    child: fm.Text('${row.seq}',
                                        style: fm.TextStyle(
                                            fontSize: 16,
                                            height: 1.3,
                                            color: Color.BLACK,
                                            fontWeight: (isCandidate ||
                                                    isCursor)
                                                ? fm.FontWeight.bold
                                                : null))),
                                //  与列头把手1对齐的占位槽
                                fm.SizedBox(width: _dragColW),
                                fm.SizedBox(
                                    width: recogW,
                                    child: fm.Text(row.recognized,
                                        maxLines: 5,
                                        overflow: fm.TextOverflow.visible,
                                        style: fm.TextStyle(
                                            fontSize: 16,
                                            height: 1.3,
                                            fontWeight: isCandidate
                                                ? fm.FontWeight.bold
                                                : null))),
                                //  与列头把手2对齐:箭头居中
                                fm.SizedBox(
                                  width: _dragColW,
                                  child: fm.Center(
                                      child: fm.Text('→',
                                          style: fm.TextStyle(
                                              fontSize: 16,
                                              height: 1.3))),
                                ),
                                fm.Expanded(
                                    child: fm.Text(
                                        row.standardCall.isBlank
                                            ? '(待补全)'
                                            : row.standardCall,
                                        style: fm.TextStyle(
                                            fontSize: 16,
                                            height: 1.3,
                                            color: Color.BLACK,
                                            fontWeight:
                                                fm.FontWeight.bold))),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      });
    //  Only 采表:面板占满剩余空间;其他模式固定高度 240
    return flow.onlyMode
        ? fm.Expanded(
            child: fm.Container(color: Color.WHITE, child: body))
        : fm.Container(height: 240, color: Color.WHITE, child: body);
  }

  //  非Only表:按第3列口令前缀搜索,点选滚动定位并高亮
  Future<void> _panelSearch() async {
    final controller = fm.TextEditingController();
    await fm.showDialog(
        context: context,
        builder: (ctx) => fm.StatefulBuilder(builder: (ctx, setD) {
              List<CallerRow> matches = [];
              final p = controller.text.trim().toLowerCase();
              final t = flow.callerTable;
              if (p.isNotEmpty && t != null) {
                for (final r in t.rows) {
                  if (r.standardCall.toLowerCase().startsWith(p))
                    matches.add(r);
                }
                if (matches.isEmpty) {
                  for (final r in t.rows) {
                    if (r.standardCall.toLowerCase().contains(p))
                      matches.add(r);
                  }
                }
              }
              return fm.AlertDialog(
                title: fm.Text('搜索口令(第三列)',
                    style: fm.TextStyle(fontSize: 20)),
                content: fm.Column(
                    mainAxisSize: fm.MainAxisSize.min,
                    children: [
                      fm.TextField(
                        controller: controller,
                        autofocus: true,
                        style: fm.TextStyle(fontSize: 24),
                        decoration: fm.InputDecoration(
                            hintText: '如: boys',
                            hintStyle: fm.TextStyle(fontSize: 20)),
                        onChanged: (_) => setD(() {}),
                      ),
                      fm.SizedBox(height: 8),
                      //  待显示行数提示(多时告知可滚动)
                      fm.Text(
                          matches.isEmpty
                              ? (p.isEmpty ? '请输入字母' : '(无匹配行)')
                              : '待显示 ${matches.length} 行'
                                '${matches.length > 8 ? '(可上下滚动)' : ''}',
                          style: fm.TextStyle(
                              fontSize: 16, color: Color.GRAY)),
                      fm.SizedBox(height: 4),
                      if (matches.isNotEmpty)
                        fm.SizedBox(
                          height: 500,
                          width: double.infinity,
                          child: fm.ListView.builder(
                            physics:
                                fm.AlwaysScrollableScrollPhysics(),
                            itemCount: matches.length,
                            itemBuilder: (lctx, i) {
                              final m = matches[i];
                              return fm.ListTile(
                                dense: true,
                                title: fm.Text(
                                    '第${m.seq}行  ${m.standardCall}',
                                    style:
                                        fm.TextStyle(fontSize: 19)),
                                onTap: () {
                                  flow.lastCandidate = m;
                                  final index =
                                      t!.rows.indexOf(m);
                                  if (index >= 0) {
                                    fm.WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                      itemScrollController.jumpTo(
                                          index: index,
                                          alignment: 0.3);
                                    });
                                  }
                                  fm.Navigator.of(ctx).pop();
                                },
                              );
                            },
                          ),
                        ),
                    ]),
                actions: [
                  fm.TextButton(
                      onPressed: () => fm.Navigator.of(ctx).pop(),
                      child: fm.Text('关闭',
                          style: fm.TextStyle(fontSize: 18))),
                ],
              );
            }));
  }

  //  长按表名(仅Only表):增加记录——经 CALL 口令选择,
  //  防长口令手工输入出错;选完自动加行,再用圆钮采样
  //  清理全表(采录完成后统一做):删空识别行、
  //  第2,3列完全相同的行只保留1行(带确认)
  Future<void> _cleanupTableDialog() async {
    final t = flow.callerTable;
    if (t == null || !flow.onlyMode) return;
    final empty = t.rows
        .where((r) => r.recognized.trim().isEmpty)
        .length;
    final ok = await fm.showDialog<bool>(
        context: context,
        builder: (ctx) => fm.AlertDialog(
              title: fm.Text('清理全表',
                  style: fm.TextStyle(fontSize: 22)),
              content: fm.Text(
                  '1. 删除空识别行($empty行)\n'
                  '2. 第2,3列完全相同的行只保留1行\n\n'
                  '确定清理?',
                  style: fm.TextStyle(fontSize: 18)),
              actions: [
                fm.TextButton(
                    onPressed: () => fm.Navigator.of(ctx).pop(false),
                    child: fm.Text('取消',
                        style: fm.TextStyle(fontSize: 18))),
                fm.TextButton(
                    onPressed: () => fm.Navigator.of(ctx).pop(true),
                    child: fm.Text('确定清理',
                        style: fm.TextStyle(
                            fontSize: 18, color: Color.RED))),
              ],
            ));
    if (ok != true || !mounted) return;
    final (del, dup) = await t.cleanupTable();
    flow.afterTableCleanup();
    if (mounted)
      fm.ScaffoldMessenger.of(context).showSnackBar(fm.SnackBar(
          backgroundColor: Color.BLUE,
          content: fm.Text(
              '已删空行$del行,去重$dup行,剩${t.rows.length}行',
              style: fm.TextStyle(fontSize: 18))));
  }

  Future<void> _addRecordDialog() async {
    if (!flow.onlyMode) return;
    //  结果类型 Object:按钮返回 true/'type'/'clear' 混合类型,
    //  用 showDialog<bool> 会在 pop('type') 时类型断言崩溃,
    //  对话框关不掉
    final go = await fm.showDialog<Object>(
        context: context,
        builder: (ctx) => fm.AlertDialog(
              title: fm.Text('增加记录',
                  style: fm.TextStyle(fontSize: 22)),
              content: fm.Text(
                  '点"去选择口令"到 CALL 列表点选;\n'
                  '或点"键入口令"用键盘手动输入。\n'
                  '执行正确后存为新记录,再用圆钮采样。',
                  style: fm.TextStyle(fontSize: 18)),
              actions: [
                fm.TextButton(
                    onPressed: () => fm.Navigator.of(ctx).pop(false),
                    child: fm.Text('取消',
                        style: fm.TextStyle(fontSize: 18))),
                fm.TextButton(
                    onPressed: () => fm.Navigator.of(ctx).pop(true),
                    child: fm.Text('去选择口令',
                        style: fm.TextStyle(
                            fontSize: 18, color: Color.BLUE))),
                //  手动键入:输入行清空,弹键盘等口令员输入
                fm.TextButton(
                    onPressed: () => fm.Navigator.of(ctx).pop('type'),
                    child: fm.Text('键入口令',
                        style: fm.TextStyle(
                            fontSize: 18, color: Color.BLUE))),
                //  换识别体系后整体重录:清空全部记号
                fm.TextButton(
                    onPressed: () =>
                        fm.Navigator.of(ctx).pop('clear'),
                    child: fm.Text('清空全部记号',
                        style: fm.TextStyle(
                            fontSize: 18, color: Color.RED))),
              ],
            ));
    if (go == 'type') {
      //  键入路径:先插入一条新记录,随即进入该行的"口令编辑"
      //  画面(专用输入框,回车只存入不执行跳舞——主输入行
      //  回车会执行跳舞,不能用)。读法等价去重:已有同口令
      //  行则撤回新行,光标跳到已有行
      debugPrint('增加记录: 键入口令 被点击');
      final table = flow.callerTable;
      if (table == null) return;
      final row = await table.addRow(recognized: '', standardCall: '');
      final typed = await _editStandardCall(row);
      final text = typed?.trim() ?? '';
      if (text.isEmpty) {
        //  取消/空:撤回刚插入的空行
        await table.removeRow(row.seq);
        return;
      }
      //  多对一:同口令就要重复建行——每次键入都是新行,
      //  各录一笔语音读法,不跳已有行(合并时记号自动归并)
      flow.selectDictationRow(row.seq);
      return;
    }
    if (go == 'clear') {
      final ok2 = await fm.showDialog<bool>(
          context: context,
          builder: (cctx) => fm.AlertDialog(
                title: fm.Text('清空全部记号?',
                    style: fm.TextStyle(fontSize: 22)),
                content: fm.Text(
                    '将清空本表全部已录记号(第2列),\n'
                    '标准口令保留。之后每个口令家族\n'
                    '重录一条即可自动填满全族。\n'
                    '确定清空?',
                    style: fm.TextStyle(fontSize: 18)),
                actions: [
                  fm.TextButton(
                      onPressed: () =>
                          fm.Navigator.of(cctx).pop(false),
                      child: fm.Text('取消',
                          style: fm.TextStyle(fontSize: 18))),
                  fm.TextButton(
                      onPressed: () =>
                          fm.Navigator.of(cctx).pop(true),
                      child: fm.Text('确定清空',
                          style: fm.TextStyle(
                              fontSize: 18, color: Color.RED))),
                ],
              ));
      if (ok2 == true && mounted) {
        final n = await flow.clearTableTokens();
        if (mounted)
          fm.ScaffoldMessenger.of(context).showSnackBar(fm.SnackBar(
              backgroundColor: Color.BLUE,
              content: fm.Text('已清空 $n 行记号,可重录',
                  style: fm.TextStyle(fontSize: 18))));
      }
      return;
    }
    if (go != true || !mounted) return;
    flow.awaitingAddRecord = true;
    try {
      pp.Provider.of<TamState>(context, listen: false)
          .change(detailPage: DetailPage.CALLS);
    } catch (_) {}
  }

  //  列头行(表顶端):序号 / 语音识别结果 / 标准口令 标题,
  //  两个拖动把手:序号|识别列之间、识别|标准列之间(左右拖改列宽)
  fm.Widget _headerRow(double recogW) {
    final style = fm.TextStyle(
        fontSize: 15,
        height: 1.3,
        color: Color(0xff444444),
        fontWeight: fm.FontWeight.bold);
    fm.Widget handle(void Function(fm.DragUpdateDetails) onDrag) =>
        fm.SizedBox(
          width: _dragColW,
          child: fm.GestureDetector(
            behavior: fm.HitTestBehavior.opaque,
            onHorizontalDragUpdate: onDrag,
            onHorizontalDragEnd: (_) => _saveRatio(),
            child: fm.Center(
              child: fm.RotatedBox(
                quarterTurns: 1,
                child: fm.Icon(fm.Icons.drag_handle,
                    size: 24, color: Color(0xff1976d2)),
              ),
            ),
          ),
        );
    //  列标题:单行显示,列宽不足时自动缩小字号,绝不换行
    fm.Widget label(String t) => fm.FittedBox(
        fit: fm.BoxFit.scaleDown,
        child: fm.Text(t, maxLines: 1, style: style));
    return fm.Container(
      width: double.infinity,
      color: Color(0xffe8e8e8),
      padding: fm.EdgeInsets.only(left: 12, right: 8, top: 1, bottom: 1),
      child: fm.Row(children: [
        fm.SizedBox(width: _seqColW, child: label('序号')),
        handle(_onSeqDrag),
        fm.SizedBox(width: recogW, child: label('识别结果')),
        handle(_onDividerDrag),
        fm.Expanded(child: label('标准口令')),
      ]),
    );
  }

}

class SequencerEditLine extends fm.StatefulWidget {
  @override
  _SequencerEditLineState createState() => _SequencerEditLineState();
}

class _SequencerEditLineState extends fm.State<SequencerEditLine>
    with fm.WidgetsBindingObserver, fm.SingleTickerProviderStateMixin {

  fm.TextEditingController textFieldController = fm.TextEditingController();
  final focusNode = fm.FocusNode();
  final ItemScrollController itemScrollController = ItemScrollController();
  final ItemPositionsListener itemPositionsListener = ItemPositionsListener.create();
  late DualSpeechProvider speechProvider;
  var _lastError = '';
  var _isVoiceCall = false;

  //  ---- 背景音乐/节拍/语音识别流程 ----
  //  流程状态(含口令员姓名/映射表)由 VoiceFlow 单例持有
  //  (输入行会因键盘开合被销毁重建,状态放在 State 里会被打断),
  //  这里只负责 UI 展示与交互
  final flow = VoiceFlow.instance;
  fm.AnimationController? _blinkController;
  var _blinkOn = false;

  @override
  void initState() {
    super.initState();
    fm.WidgetsBinding.instance.addObserver(this);
    if (!TamUtils.isTouchDevice)
      later(() {
        focusNode.requestFocus();
      });
    speechProvider = DualSpeechProvider();
    flow.attach(speechProvider);
    flow.addListener(_onFlowChanged);
    //  供音乐按钮在未登录时触发的"登录并打开映射表"回调
    flow.loginRequest = _loginAndOpenTable;
    //  麦克风按钮蓝色闪烁动画:250ms 一个周期,亮/暗各 125ms = 4 次/秒
    _blinkController = fm.AnimationController(
        vsync: this, duration: const Duration(milliseconds: 250))
      ..addListener(() {
        final on = _blinkController!.value < 0.5;
        if (on != _blinkOn && mounted)
          setState(() => _blinkOn = on);
      });
  }

  //  PTT"按下圆钮,读右侧口令"提示浮层(按下显示,抬起消失)
  fm.OverlayEntry? _pttHint;

  void _showPttHint() {
    _hidePttHint();
    _pttHint = fm.OverlayEntry(builder: (ctx) => fm.Positioned(
        bottom: 120, left: 0, right: 0,
        child: fm.IgnorePointer(
          child: fm.Center(
            child: fm.Container(
              color: Color.BLUE,
              padding: const fm.EdgeInsets.symmetric(
                  vertical: 10, horizontal: 24),
              child: const fm.Text('按下圆钮,读右侧口令',
                  style: fm.TextStyle(fontSize: 24, color: Color.WHITE)),
            ),
          ),
        )));
    fm.Overlay.of(context).insert(_pttHint!);
  }

  void _hidePttHint() {
    _pttHint?.remove();
    _pttHint = null;
  }

  //  流程状态变化 → 刷新 UI,并驱动闪烁与动画即时变速
  void _onFlowChanged() {
    if (!mounted) return;
    //  记录初始化:Calls 页选中的口令填入输入行,供继续键入修改
    final selection = flow.callSelection;
    if (selection != null) {
      flow.callSelection = null;
      //  长按表名"增加记录":不填输入行,直接加为新记录行
      if (flow.awaitingAddRecord) {
        flow.awaitingAddRecord = false;
        flow.addRecordWithCall(selection);
        return;
      }
      textFieldController.text = selection;
      //  Only 采表模式:只填文字,不弹键盘不抢焦点
      //  (操作者用语音+确认按钮,无需键盘)
      if (!flow.onlyMode) {
        focusNode.requestFocus();
        setState(() {
          virtualKeyboardSetVisible(true);
        });
      } else {
        //  Only 模式:强制刷新显示(不弹键盘)
        setState(() {});
      }
    }
    if (flow.phase == 'detecting')
      _blinkController?.repeat();
    else {
      _blinkController?.stop();
      if (_blinkOn) _blinkOn = false;
    }
    _showFlowError();
    setState(() {});
    //  速度变化(接管/恢复)时,若动画在播立即应用
    _applyDancerSpeed();
  }

  //  触摸设备上弹出输入键盘
  void virtualKeyboardSetVisible(bool visible) {
    try {
      pp.Provider.of<VirtualKeyboardVisible>(context, listen: false)
          .isVisible = visible;
    } catch (_) {}
  }

  @override
  void dispose() {
    fm.WidgetsBinding.instance.removeObserver(this);
    //  只断开 UI 监听,流程本体由 VoiceFlow 单例继续;
    //  若 5 秒后没有新的输入行接入(真正离开页面)则自动回收
    flow.removeListener(_onFlowChanged);
    flow.detach();
    //  登录回调若仍指向本实例则清除(输入行重建时新实例已重新注册)
    if (flow.loginRequest == _loginAndOpenTable)
      flow.loginRequest = null;
    //  延迟到微任务里销毁语音监听,避免在 dispose 过程中
    //  notifyListeners 触发已卸载的组件重建
    Future.microtask(() {
      speechProvider.cancel();
      //  不 dispose:VoiceFlow 还在用它(Only 模式下采样按钮需要)
      //  dispose 会导致后续 startSample 因 disposed=true 被拒
    });
    _hidePttHint();
    _blinkController?.dispose();
    textFieldController.dispose();
    fs.SystemChannels.textInput.invokeMethod('TextInput.hide');
    focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(fm.AppLifecycleState state) {
    //  切到后台/应用被销毁时,直接停止语音监听并释放麦克风,
    //  回到前台后需要重新点击麦克风开启
    if (state == fm.AppLifecycleState.paused ||
        state == fm.AppLifecycleState.hidden ||
        state == fm.AppLifecycleState.detached) {
      speechProvider.cancel();
      flow.stop();
    }
  }

  @override
  fm.Widget build(fm.BuildContext context) {
    return  pp.ChangeNotifierProvider.value(
        value: speechProvider,
        child: pp.Consumer4<SequencerModel,
            AbbreviationsModel,
            DualSpeechProvider,
            VirtualKeyboardVisible>(
    builder: (context, model, abbreviations, speech, virtualKeyboard, child) {

      //  If doing voice input, show errors in the snack bar
      //  because the error text of the EditText is not visible
      if (_isVoiceCall && model.errorString.isNotBlank && model.errorString != _lastError) {
        _lastError = model.errorString;
        model.errorString = '';
        later(() {
          fm.ScaffoldMessenger.of(context).showSnackBar(fm.SnackBar(
              backgroundColor: Color.RED,
              duration: Duration(seconds: 5),
              content: fm.Text(_lastError,
                  style: GoogleFonts.roboto(fontSize: 20))
          ));
        });
        //  After the same duration as the SnackBar reset the last error
        //  so the user will see another messoage on repeating the same error
        afterDelay(() { _lastError = ''; },Duration(seconds:5));
      }
      //  Process any results from the speech recognizer
      //  只处理最终结果:中间结果仅供黄框实时显示,
      //  不得流入输入框、不得触发表内自动执行
      if (speech.hasResults && speech.lastResult!.finalResult) {
        //  0) PTT 采样结果(按下说话/抬起出结果):专用于映射表
        //     口令语音采集。Only 模式由 VoiceFlow 处理(黄框待确认),
        //     非 Only 模式进入记录初始化
        if (flow.pttActive) {
          //  采样只以松开按钮为准结束:按住期间识别器在停顿处
          //  给出的分段最终结果由 VoiceFlow 拼接累计,这里不消费,
          //  否则采样会中途自行退出(结果不出黄框)
          if (speech.isListening) {
            //  仍在按住中:不处理
          } else {
          final sample = speech.lastResult!.alternates
              .map((a) => a.recognizedWords.replaceAll('\W'.r, ' ').trim())
              .firstWhere((st) => st.isNotBlank, orElse: () => '');
          flow.consumeSample();
          if (flow.onlyMode) {
            //  结果只进黄框待确认(不动输入框、不发回车)
            speech.clearResults();
          } else if (sample.isNotBlank) {
            later(() async {
              final row = await flow.startRecordInit(sample);
              if (row == null || !mounted) return;
              fm.ScaffoldMessenger.of(context).showSnackBar(fm.SnackBar(
                  backgroundColor: Color.BLUE,
                  duration: const Duration(seconds: 4),
                  content: fm.Text(
                      '已采集"$sample":请键盘输入正确口令,'
                      '执行正确后自动存表。',
                      style: GoogleFonts.roboto(fontSize: 20))));
            });
            speech.clearResults();
          } else {
            later(() {
              if (!mounted) return;
              fm.ScaffoldMessenger.of(context).showSnackBar(fm.SnackBar(
                  backgroundColor: Color.RED,
                  duration: const Duration(seconds: 4),
                  content: fm.Text('未采集到语音:请按住按钮说话,说完再抬起。',
                      style: GoogleFonts.roboto(fontSize: 20))));
            });
            speech.clearResults();
          }
          }
        }
        //  1) 喊口令(三表流水线,用户定义):静音0.9秒=口令
        //     边界,VoiceFlow 按分段检索 Prefix(P)/当前合并
        //     表(_C)/Sufix(_S)三表,结果分别存储防冲掉,最后
        //     组合为整条口令;这里只负责送输入行+回车执行。
        //     Only 采表模式绝不自动执行口令
        else if (!flow.onlyMode) {
          if (flow.assembledCall.isNotBlank) {
            final call = flow.assembledCall;
            flow.consumeAssembled();
            debugPrint('pipeline execute: "$call"');
            later(() {
              _isVoiceCall = true;
              _sendOneLine(model, call);
            });
          } else {
            debugPrint('pipeline: no assembled call -> ignored');
          }
        }
        //  处理完一条结果后立即清空,防止 build 重复消费同一结果
        speech.clearResults();
      }

      return fm.Container(
        color: Color.WHITE,
        padding: fm.EdgeInsets.only(left: 3),
        child: fm.Column(
          mainAxisSize: fm.MainAxisSize.min,
          children: [

            fm.Row(
              children: [

            //   Accept keyboard input if web site
            //  or if user has tapped box on a device
            if (virtualKeyboard.isVisible || !TamUtils.isTouchDevice)
              fm.Expanded(
                child: fm.TextField(
                  key: fm.Key('Sequencer Input'),
                  focusNode: focusNode,
                  controller: textFieldController,
                  onTapOutside: (event) {
                    fm.FocusManager.instance.primaryFocus?.unfocus();
                  },
                  decoration: fm.InputDecoration(
                      hintText: 'Enter calls',
                      suffixIcon: fm.IconButton(
                          icon:fm.Icon(fm.Icons.clear),
                        onPressed: () {
                          textFieldController.clear();
                          //  清除输入框的同时清掉错误提示并刷新UI
                          //  (口令没进执行队列,只在框内;清框即恢复);
                          //  errorString 是普通字段,赋值不会自动
                          //  notifyListeners,必须显式刷新
                          if (model.errorString.isNotEmpty) {
                            model.errorString = '';
                            model.notifyListeners();
                          }
                          //  底部错误 SnackBar 一并撤下
                          fm.ScaffoldMessenger.of(context)
                              .removeCurrentSnackBar();
                          //  语音错误标志复位,避免后续误报
                          _isVoiceCall = false;
                        },
                      ),
                      errorStyle: fm.TextStyle(fontSize: 20,
                          color: model.errorString.contains('Note') ? fm.Colors.blue : fm.Colors.red),
                      errorMaxLines: 20,
                      errorText: model.errorString.isEmpty ? null : model.errorString),
                  enableSuggestions: true,
                  style: fm.TextStyle(fontSize: 24),
                      //  Code to run when user presses Enter
                      onSubmitted: (value) {
                        //  空文本直接忽略(包括语音输出后注入的回车
                        //  触发的重复提交)
                        if (value.isBlank) return;
                        _isVoiceCall = false;
                        _sendOneLine(model, value);
                      },
                ),
              )

            //  Touch device - don't show keyboard until user
            //  taps the input line
            else
              fm.Expanded(
                  child:fm.Material(
                    color: Color.WHITE,
                    child: fm.InkWell(
                      key: fm.ValueKey('Tap to start Sequence'),
                      onTap: () {
                        setState(() {
                          virtualKeyboard.isVisible = true;
                          focusNode.requestFocus();
                        });
                      },
                      //  文字与右侧按钮留出间距,不贴不盖
                      child: fm.Padding(
                        padding: fm.EdgeInsets.only(right: 10),
                      //  提示按表状态区分:
                      //  无表=三行操作指引;Only表=圆钮采表;非Only表=麦克风喊口令
                      child: flow.callerTable == null
                          ? fm.Text.rich(
                              fm.TextSpan(children: [
                                fm.TextSpan(
                                    text: 'Tap here for KEY input;\n'),
                                //  Calls钮=右侧按钮列的 Calls 文字钮,
                                //  此处内嵌迷你同款样式
                                //  与右侧按钮列 Calls 钮同款样式
                                //  (灰边+白灰渐变+圆角+粗体)
                                fm.WidgetSpan(
                                    alignment:
                                        fm.PlaceholderAlignment.middle,
                                    child: fm.Row(
                                        mainAxisSize:
                                            fm.MainAxisSize.min,
                                        children: [
                                          fm.Text('Tap ',
                                              textScaler: fm.TextScaler.noScaling,
                                                  style: fm.TextStyle(
                                                  fontSize: 14,
                                                  height: 1.4)),
                                          fm.Container(
                                              padding: fm.EdgeInsets
                                                  .symmetric(
                                                      horizontal: 5,
                                                      vertical: 1),
                                              decoration:
                                                  fm.ShapeDecoration(
                                                      shape: fm
                                                          .RoundedRectangleBorder(
                                                              side: fm
                                                                  .BorderSide(
                                                                      color: Color
                                                                          .GRAY
                                                                              .darker()),
                                                              borderRadius:
                                                                  fm.BorderRadius.circular(10)),
                                                      gradient: fm
                                                          .LinearGradient(
                                                              begin: fm
                                                                  .Alignment
                                                                  .topCenter,
                                                              end: fm
                                                                  .Alignment
                                                                  .bottomCenter,
                                                              colors: [
                                                            Color(
                                                                0xffffffff),
                                                            Color(
                                                                0xffa0a0a0)
                                                          ])),
                                              child: fm.Text('Calls',
                                                  textScaler: fm.TextScaler.noScaling,
                                                  style: fm.TextStyle(
                                                      fontSize: 14,
                                                      fontWeight: fm
                                                          .FontWeight
                                                          .bold))),
                                          fm.Text(' for Selection input;',
                                              textScaler: fm.TextScaler.noScaling,
                                                  style: fm.TextStyle(
                                                  fontSize: 14,
                                                  height: 1.4)),
                                        ])),
                                fm.TextSpan(text: '\n'),
                                fm.TextSpan(text: 'Tap '),
                                //  open钮=打开表按钮的文件夹图标
                                fm.WidgetSpan(
                                    alignment:
                                        fm.PlaceholderAlignment.middle,
                                    child: fm.Icon(
                                        fm.Icons.folder_open, size: 18)),
                                fm.TextSpan(
                                    text: ' to open Mapping Table for '),
                                //  MIK钮=麦克风图标
                                fm.WidgetSpan(
                                    alignment:
                                        fm.PlaceholderAlignment.middle,
                                    child: fm.Icon(fm.Icons.mic, size: 18)),
                                fm.TextSpan(text: ' input.'),
                              ]),
                              style: fm.TextStyle(
                                  fontSize: 15, height: 1.4))
                          : fm.Text(
                              flow.onlyMode
                                  ? '圆钮按下,读口令,读完抬起'
                                  : '按下麦克风钮,语音发布口令',
                              maxLines: 1,
                              overflow: fm.TextOverflow.ellipsis,
                              style: fm.TextStyle(fontSize: 20)),
                      ),
                    ),
                  )
              ),

            //  Mic icon for touch devices to do voice input
            //  点击麦克风先要求输入口令员姓名和密码,确认后打开(或新建)
            //  该口令员的映射表,之后才开始语音识别
            //  Only 采表的识别确认/完成建表由黄色显示框承担:
            //  点一下=确认,长按=完成建表(编辑行不再放这两个按钮)
            //  打开表按钮:负责映射表的选择与打开/退出
              if (TamUtils.canListen)
                fm.TextButton(
                  style: fm.TextButton.styleFrom(
                      padding: fm.EdgeInsets.symmetric(horizontal: 2),
                      minimumSize: fm.Size(36, 36)),
                  //  已打开表时禁止操作(变灰);关闭表后恢复
                  onPressed: flow.isActive ? null : () async {
                    if (!await _loginAndOpenTable()) return;
                    flow.startTableMode();
                  }, child: fm.Icon(
                  fm.Icons.folder_open,
                  color: flow.isActive ? Color.GRAY : Color.BLACK,
                  size: 28,
                  )
              ),
              //  PTT 采样按钮:只负责按下朗读,抬起结束
              //  按下说话,抬起结束并给出识别结果,
              //  结果直接进入记录初始化(写入映射表第二列)
              if (TamUtils.canListen)
                fm.Listener(
                  onPointerDown: (_) {
                    //  此按钮只负责"按下朗读,抬起结束"
                    //  打开表由独立的"打开表"按钮负责
                    if (!flow.isActive) return;
                    if (flow.startSample())
                      _showPttHint();
                  },
                  onPointerUp: (_) {
                    _hidePttHint();
                    flow.endSample();
                  },
                  onPointerCancel: (_) {
                    _hidePttHint();
                    flow.endSample();
                  },
                  child: fm.Container(
                    padding: fm.EdgeInsets.all(2),
                    child: fm.Icon(
                      //  未开表:灰色禁用;采样中蓝色(按住);平时黑色
                      fm.Icons.record_voice_over,
                      color: flow.callerTable == null
                          ? Color.GRAY
                          : (flow.pttActive
                              ? fm.Colors.blue
                              : Color.BLACK),
                      size: 28),
                  ),
                ),
              //  语音识别钮:无表时点击=选级别自动打开该级别
              //  映射表(不带 Only);开表后点击=开关流式检索
              if (TamUtils.canListen)
                //  麦克风钮:仅打开了非Only映射表才可操作
                //  (识别在该表内选择,表已含级别)
                fm.TextButton(
                  onPressed: flow.callerTable == null || flow.onlyMode
                      ? null : () async {
                    //  采样中/音乐节拍取样中不响应
                    if (flow.pttActive) return;
                    if (flow.phase == 'awaiting' ||
                        flow.phase == 'detecting')
                      return;
                    if (flow.isActive) {
                      if (speechProvider.isListening) {
                        //  流式检索中:点击结束——只退出语音识别,
                        //  表保持打开(再按可重启识别)
                        flow.stopListening();
                      } else {
                        //  表管理模式:点击开始流式检索
                        //  (只查表执行,面板自动收起);
                        //  语音输入全程不弹键盘——收起焦点与虚拟键盘,
                        //  防止每次执行口令后键盘弹出遮挡画面
                        focusNode.unfocus();
                        setState(() {
                          virtualKeyboardSetVisible(false);
                        });
                        //  表保持展开:命中行居中+高亮显示
                        flow.setPanelMinimized(false);
                        flow.startListening();
                      }
                      return;
                    }
                    //  表已开未激活:直接进入流式检索
                    flow.start();
                  },
                  //  长按麦克风:退出当前表,回到映射表选择
                  //  (可删除/重命名/另存/导入导出/换表)
                  onLongPress:
                      flow.callerTable == null || flow.onlyMode
                          ? null : () async {
                    if (flow.pttActive) return;
                    flow.stop();
                    speechProvider.cancel();
                    await _loginAndOpenTable();
                  },
                  //  麦克风钮保持原样式(纯图标,无圆底):
                  //  灰=不可用;红=流式识别中;蓝闪=节拍检测中;
                  //  平时黑色
                  child: fm.Icon(
                  fm.Icons.mic,
                  color: flow.callerTable == null || flow.onlyMode
                      ? Color.GRAY
                      : (flow.phase == 'detecting'
                          ? (_blinkOn ? fm.Colors.blue : Color.BLACK)
                          : ((speechProvider.isListening && !flow.pttActive)
                              ? Color.RED : Color.BLACK)),
                  size: 32,
                  )
                  )
              ]
            )
          ]
        )
      );
    }
        )
    );
  }

  //  口令员登录弹窗:姓名从下拉列表选择已有映射表(也可输入新姓名
  //  新建表),再输入密码,两者都填写后才能确认
  //  返回 true 表示用户已确认,姓名会记住供下次预填
  //  按钮状态由 controller listener 驱动,不依赖 onChanged,
  //  任何输入途径(键盘/输入法/程序写入)都能可靠触发
  // ------------------------------------------------ 映射表管理

  fm.Widget _tableMgmtButton(fm.BuildContext ctx, bool enabled,
      String label, Future<void> Function() action) =>
    fm.TextButton(
        onPressed: enabled ? () => action() : null,
        style: fm.TextButton.styleFrom(
            padding: fm.EdgeInsets.symmetric(horizontal: 5),
            minimumSize: fm.Size(36, 28),
            textStyle: fm.TextStyle(fontSize: 13)),
        child: fm.Text(label));

  Future<String?> _inputDialog(String title, String hint,
      {String initial = ''}) async {
    final controller = fm.TextEditingController()..text = initial;
    final result = await fm.showDialog<String>(
        context: context,
        builder: (ctx) => fm.AlertDialog(
          title: fm.Text(title),
          content: fm.TextField(
            controller: controller,
            autofocus: true,
            decoration: fm.InputDecoration(
                hintText: hint, labelStyle: fm.TextStyle(fontSize: 20)),
            style: fm.TextStyle(fontSize: 24),
          ),
          actions: [
            fm.TextButton(onPressed: () => fm.Navigator.of(ctx).pop(),
                child: fm.Text('取消')),
            fm.TextButton(
                onPressed: () => fm.Navigator.of(ctx).pop(controller.text),
                child: fm.Text('确定')),
          ],
        ));
    controller.dispose();
    final value = result?.trim();
    return (value == null || value.isBlank) ? null : value;
  }

  Future<void> _refreshTableNames(
      SharedPreferences prefs, List<String> tableNames) async {
    //  自动清除空表(0行):登录时误建的裸名空表不再残留
    for (final n in CallerTable.listTableNames(prefs)) {
      final raw = prefs.getString('口令员表 $n');
      var empty = false;
      try {
        final d = jsonDecode(raw ?? '{}');
        empty = d is! Map ||
            d['rows'] is! List ||
            (d['rows'] as List).isEmpty;
      } catch (_) {
        empty = true;
      }
      if (empty) {
        await CallerTable.deleteTable(prefs, n);
        debugPrint('空表已自动清除: $n');
      }
    }
    tableNames.clear();
    tableNames.addAll(CallerTable.listTableNames(prefs));
  }

  //  删除映射表
  Future<void> _manageDeleteTable(SharedPreferences prefs,
      List<String> tableNames, String name) async {
    final confirmed = await fm.showDialog<bool>(
        context: context,
        builder: (ctx) => fm.AlertDialog(
          title: fm.Text('删除映射表'),
          content: fm.Text('确定删除"$name"的映射表?不可恢复。',
              style: fm.TextStyle(fontSize: 20)),
          actions: [
            fm.TextButton(onPressed: () => fm.Navigator.of(ctx).pop(false),
                child: fm.Text('取消')),
            fm.TextButton(onPressed: () => fm.Navigator.of(ctx).pop(true),
                child: fm.Text('删除')),
          ],
        ));
    if (confirmed == true) {
      await CallerTable.deleteTable(prefs, name);
      await _refreshTableNames(prefs, tableNames);
    }
  }

  //  重命名映射表,成功返回新表名
  Future<String?> _manageRenameTable(SharedPreferences prefs,
      List<String> tableNames, String oldName) async {
    final newName = await _inputDialog('重命名映射表', '新表名', initial: oldName);
    if (newName == null || newName == oldName) return null;
    final ok = await CallerTable.renameTable(prefs, oldName, newName);
    if (ok) {
      await _refreshTableNames(prefs, tableNames);
      return newName;
    }
    _mgmtSnackBar('重命名失败:新表名已存在');
    return null;
  }

  //  另存为:复制当前表到新表名
  Future<void> _manageSaveTableAs(SharedPreferences prefs,
      List<String> tableNames, String sourceName) async {
    final targetName = await _inputDialog('另存为', '新表名', initial: sourceName);
    if (targetName == null || targetName == sourceName) return;
    final ok = await CallerTable.saveTableAs(prefs, sourceName, targetName);
    if (ok)
      await _refreshTableNames(prefs, tableNames);
    else
      _mgmtSnackBar('另存失败:目标表名已存在');
  }

  //  导入 ysb 文件(经文件管理器选择位置),成功返回导入的表名
  Future<String?> _manageImportYsb(SharedPreferences prefs,
      List<String> tableNames) async {
    fp.FilePickerResult? picked;
    try {
      picked = await fp.FilePicker.pickFiles(
          type: fp.FileType.custom,
          allowedExtensions: ['ysb', 'YSB', 'Ysb']);
    } catch (e) {
      _mgmtSnackBar('打开文件选择器失败:$e');
      return null;
    }
    final path = picked?.files.single.path;
    if (path == null) return null;
    String content;
    try {
      content = await io.File(path).readAsString();
    } catch (e) {
      _mgmtSnackBar('读取文件失败:$e');
      return null;
    }
    final defaultName = io.File(path)
        .uri.pathSegments.last.replaceFirst('(?i)\\.ysb\$'.r, '');
    final targetName = await _inputDialog('导入为映射表', '表名',
        initial: defaultName);
    if (targetName == null) return null;
    final ok = await CallerTable.importYsb(prefs, targetName, content);
    if (ok) {
      await _refreshTableNames(prefs, tableNames);
      _mgmtSnackBar('已导入"$targetName"');
      return targetName;
    }
    _mgmtSnackBar('导入失败:文件格式无效');
    return null;
  }

  //  导出 ysb 文件:先写临时文件,再经系统"文件管理器"
  //  (SAF 另存为对话框)由口令员选择保存位置。
  //  file_picker 的 saveFile 不支持 Android,故用 flutter_file_dialog
  Future<void> _manageExportYsb(SharedPreferences prefs, String name) async {
    final content = CallerTable.exportYsb(prefs, name);
    if (content == null) return;
    try {
      final tmp = io.File('${io.Directory.systemTemp.path}/$name.ysb');
      await tmp.writeAsString(content, flush: true);
      final saved = await ffd.FlutterFileDialog.saveFile(
          params: ffd.SaveFileDialogParams(
              sourceFilePath: tmp.path,
              fileName: '$name.ysb'));
      if (saved != null && saved.isNotBlank)
        _mgmtSnackBar('已导出 $saved');
    } catch (e) {
      _mgmtSnackBar('导出失败:$e');
    }
  }

  void _mgmtSnackBar(String message) {
    if (!mounted) return;
    fm.ScaffoldMessenger.of(context).showSnackBar(fm.SnackBar(
        backgroundColor: Color.BLUE,
        duration: Duration(seconds: 3),
        content: fm.Text(message, style: fm.TextStyle(fontSize: 18))));
  }

  //  映射表选择画面(点麦克风后弹出):
  //  第一行为空行(光标在此,可键入新表名),其下为全部映射表列表
  //  (初始光标指向第一个);菜单区初始只有"导入"可用,选择某个表后
  //  其他按钮可用而"导入"变不可用;点"打开"(或"删除"验令后)才要求
  //  输入口令;被选择的表名高亮
  Future<bool> _showCallerLogin(fm.BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    //  可变列表:表管理(删除/重命名/导入)后即时刷新
    final tableNames = CallerTable.listTableNames(prefs);
    final nameController = fm.TextEditingController();
    final passwordController = fm.TextEditingController();
    final passwordFocus = fm.FocusNode();
    var selected = '';   //  选中的表名(空表示未选)
    var opened = false;
    //  口令阶段:点"打开"或"删除"后,在同一个对话框内切换到
    //  口令输入(不弹新对话框——部分系统不允许新对话框自动弹键盘),
    //  口令框出现即聚焦,键盘直接打开
    var passwordMode = '';
    var passwordShown = false;
    await fm.showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => fm.StatefulBuilder(
          builder: (ctx, setState) {
            final text = nameController.text.trim();
            //  打开钮只对已存在的表可用(虚=禁止):
            //  新表名必须走"建表→创建",不能凭空打开
            final openName =
                selected.isNotBlank ? selected : text;
            final canOpen = openName.isNotBlank &&
                tableNames.contains(openName);
            //  口令阶段:标题与内容切换为口令输入
            if (passwordMode.isNotBlank) {
              if (!passwordShown) {
                passwordShown = true;
                fm.WidgetsBinding.instance.addPostFrameCallback((_) {
                  passwordFocus.requestFocus();
                  fs.SystemChannels.textInput
                      .invokeMethod('TextInput.show');
                });
              }
              //  口令确认:回车或"确定"触发
              Future<void> doConfirm() async {
                final pwd = passwordController.text;
                if (pwd.isBlank) return;
                flow.callerPassword = pwd;
                if (passwordMode == '打开') {
                  flow.callerName = selected.isNotBlank
                      ? selected : nameController.text.trim();
                  opened = true;
                  fm.Navigator.of(ctx).pop();
                } else if (passwordMode == '删除') {
                  //  必须 await 删除完成再刷新,否则列表仍显示已删表
                  await _manageDeleteTable(prefs, tableNames, selected);
                  setState(() {
                    passwordMode = '';
                    selected = '';
                    passwordController.clear();
                    passwordShown = false;
                  });
                }
              }
              return fm.AlertDialog(
                title: fm.Text('$passwordMode - 请输入口令'),
                content: fm.TextField(
                  controller: passwordController,
                  focusNode: passwordFocus,
                  autofocus: true,
                  obscureText: true,
                  decoration: fm.InputDecoration(
                      labelText: '口令',
                      labelStyle: fm.TextStyle(fontSize: 20)),
                  style: fm.TextStyle(fontSize: 24),
                  onSubmitted: (_) => doConfirm(),
                ),
                actions: [
                  fm.TextButton(onPressed: () {
                    setState(() {
                      passwordMode = '';
                      passwordController.clear();
                      passwordShown = false;
                    });
                  }, child: fm.Text('返回')),
                  fm.TextButton(onPressed: doConfirm,
                      child: fm.Text('确定')),
                ],
              );
            }
            return fm.AlertDialog(
              title: fm.Text('映射表选择'),
              content: fm.Column(
                mainAxisSize: fm.MainAxisSize.min,
                children: [
                  //  第一行:空行,光标在此(可键入新表名新建映射表)
                  fm.TextField(
                    controller: nameController,
                    autofocus: true,
                    decoration: fm.InputDecoration(
                        hintText: '(输入新表名或从下方选择)',
                        hintStyle: fm.TextStyle(fontSize: 18)),
                    style: fm.TextStyle(fontSize: 24),
                    onChanged: (_) => setState(() { selected = ''; }),
                  ),
                  fm.SizedBox(height: 6),
                  //  全部映射表列表,初始光标指向第一个
                  fm.Container(
                    constraints: fm.BoxConstraints(maxHeight: 150),
                    width: double.infinity,
                    decoration: fm.BoxDecoration(
                        border: fm.Border.all(color: Color.LIGHTGREY)),
                    child: tableNames.isEmpty
                        ? fm.Padding(
                            padding: fm.EdgeInsets.all(10),
                            child: fm.Text('(暂无映射表,可导入或输入新表名)',
                                style: fm.TextStyle(fontSize: 18)))
                        : fm.ListView.builder(
                            shrinkWrap: true,
                            padding: fm.EdgeInsets.zero,
                            itemCount: tableNames.length,
                            itemBuilder: (lctx, index) {
                              final name = tableNames[index];
                              final isSelected = name == selected;
                              //  未选时初始光标指向第一个
                              final isFocusedFirst =
                                  selected.isBlank && index == 0;
                              return fm.InkWell(
                                //  选中只以列表高亮显示,
                                //  不把表名回填到上面的输入行
                                onTap: () => setState(() {
                                  selected = name;
                                }),
                                child: fm.Container(
                                  color: isSelected
                                      ? Color.BLUE
                                      : (isFocusedFirst
                                          ? Color(0xffe0e0ff)
                                          : null),
                                  padding: fm.EdgeInsets.only(
                                      left: 12, top: 4, bottom: 4),
                                  child: fm.Text(name,
                                      style: fm.TextStyle(
                                          fontSize: 22,
                                          color: isSelected
                                              ? Color.WHITE
                                              : Color.BLACK,
                                          fontWeight: isSelected
                                              ? fm.FontWeight.bold : null)),
                                ),
                              );
                            },
                          ),
                  ),
                  fm.SizedBox(height: 6),
                  //  菜单区:未选表时只有"导入"可用;
                  //  选中表后其他按钮可用,"导入"变不可用
                  fm.Wrap(
                    spacing: 4,
                    runSpacing: 2,
                    children: [
                      _tableMgmtButton(ctx, selected.isNotBlank, '删除',
                          () async {
                        //  删除要求先输入口令(同框切换到口令阶段)
                        passwordController.clear();
                        setState(() { passwordMode = '删除'; });
                      }),
                      _tableMgmtButton(ctx, selected.isNotBlank, '重命名',
                          () async {
                        final newName = await _manageRenameTable(
                            prefs, tableNames, selected);
                        if (newName != null)
                          setState(() { selected = newName; });
                      }),
                      _tableMgmtButton(ctx, selected.isNotBlank, '另存为',
                          () async {
                        await _manageSaveTableAs(prefs, tableNames, selected);
                        setState(() {});
                      }),
                      _tableMgmtButton(ctx, true, '建表', () async {
                        //  建 Only 工作表:选源表+类型。
                        //  状态(表名控制器/类型)必须在 StatefulBuilder
                        //  外面持有——builder 闭包每次 lset 重建都会
                        // 重新执行,闭包内变量会重置(曾致选了 Prefix
                        //  表名仍弹回 _ms)
                        final prefs2 = await SharedPreferences.getInstance();
                        final srcNames = CallerTable.listTableNames(prefs2)
                            .where((n) => !n.endsWith('_Only')).toList();
                        var src = nameController.text.trim().isNotBlank
                            ? nameController.text.trim()
                            : (srcNames.isNotEmpty ? srcNames.first : '');
                        var lv = 'ms';
                        final typeRe = RegExp(
                            r'_(Prefix|Sufix|ms|plus|a1|a2|c1|c2|c3a|c3b)$');
                        String stemOf(String s) =>
                            s.trim().replaceFirst(typeRe, '');
                        final nameCtl = fm.TextEditingController();
                        //  初始表名只有名字本身——不带类型后缀;
                        //  后缀只在下拉选择了类型之后才出现
                        nameCtl.text = stemOf(src);
                        final level = await fm.showDialog<String>(
                            context: context,
                            builder: (lctx) =>
                                fm.StatefulBuilder(builder: (lctx, lset) {
                              void applyType(String t) {
                                lv = t;
                                final stem = stemOf(nameCtl.text);
                                if (stem.isEmpty) return;
                                nameCtl.text = '${stem}_$t';
                                lset(() {});
                              }
                              return fm.AlertDialog(
                                title: fm.Text('建表(建Only工作表)'),
                                content: fm.Column(
                                  mainAxisSize: fm.MainAxisSize.min,
                                  children: [
                                    fm.TextField(
                                        controller: nameCtl,
                                        style: fm.TextStyle(fontSize: 22),
                                        decoration: fm.InputDecoration(
                                            labelText: '表名',
                                            labelStyle:
                                                fm.TextStyle(fontSize: 18))),
                                    fm.DropdownButton<String>(
                                        value: lv,
                                        isExpanded: true,
                                        items: [for (final l in
                                          ['Prefix','Sufix','ms','plus','a1','a2','c1','c2','c3a','c3b'])
                                          fm.DropdownMenuItem(
                                              value: l, child: fm.Text(l))],
                                        onChanged: (v) =>
                                            applyType(v ?? lv)),
                                  ],
                                ),
                                actions: [
                                  fm.TextButton(
                                      onPressed: () =>
                                          fm.Navigator.of(lctx).pop(),
                                      child: fm.Text('取消')),
                                  fm.TextButton(
                                      onPressed: () =>
                                          fm.Navigator.of(lctx).pop(
                                              '${stemOf(nameCtl.text)}|$lv'),
                                      child: fm.Text('创建')),
                                ],
                              );
                            }));
                        nameCtl.dispose();
                        if (level == null || !level.contains('|')) {
                          return;
                        }
                        final parts = level.split('|');
                        debugPrint('建表: name=${parts[0]} '
                            'type=${parts[1]}');
                                        final onlyName =
                                            '${parts[0]}_${parts[1]}_Only';
                                        final t = await CallerTable
                                            .open(onlyName);
                                        //  按选择引入不同数据:
                                        //  Prefix=前缀库18条,Sufix=后缀库
                                        //  13条,级别=该级别核心口令家族
                                        //  (与Calls页总数一致,MS=82);
                                        //  均每条3行(3归1)
                                        final seededN =
                                            parts[1] == 'Prefix'
                                          ? await t.seedLibraryRows(
                                              suffix: false)
                                          : (parts[1] == 'Sufix'
                                          ? await t.seedLibraryRows(
                                              suffix: true)
                                          : await t.seedLevelRows(
                                              parts[1]));
                                        debugPrint('建表种库: $onlyName '
                                            '$seededN rows');
                                        await _refreshTableNames(
                                            prefs2, tableNames);
                                        setState(() { selected = onlyName; });
                                        _mgmtSnackBar('已创建 $onlyName '
                                            '${t.rows.length}条,请点打开');
                                      }),
                      _tableMgmtButton(ctx, selected.isBlank, '导入',
                          () async {
                        final imported = await _manageImportYsb(
                            prefs, tableNames);
                        if (imported != null)
                          setState(() { selected = imported; });
                      }),
                      _tableMgmtButton(ctx, selected.isNotBlank, '导出',
                          () async {
                        await _manageExportYsb(prefs, selected);
                      }),
                      //  表补全:把口令库全部口令预写入映射表,
                      //  使喊口令时标准说法即可命中
                      //  合并:把选中的 _Only 表与源表合并排序另存
                      _tableMgmtButton(ctx,
                          selected.endsWith('_Only'),
                          '合并', () async {
                        //  源表名 = 下一级合并表(ms 用基础源表)
                        //  级别累积:plus与ms合并表合并,依此类推
                        final mReg = RegExp(
                                r'_(plus|a1|a2|c1|c2|c3a|c3b|ms)_Only$')
                            .firstMatch(selected);
                        const lvOrder = [
                          'ms', 'plus', 'a1', 'a2', 'c1', 'c2', 'c3a', 'c3b'
                        ];
                        final lvIdx = mReg == null
                            ? 0 : lvOrder.indexOf(mReg.group(1)!);
                        final base = mReg == null
                            ? selected
                            : selected.substring(0, mReg.start);
                        final src = lvIdx > 0
                            ? base + '_' + lvOrder[lvIdx - 1]
                            : base;
                        //  目标表名 = 去掉 "_Only"
                        final dst = selected.replaceAll('_Only', '');
                        final ok = await fm.showDialog<bool>(
                            context: context,
                            builder: (mctx) => fm.AlertDialog(
                              title: fm.Text('合并映射表'),
                              content: fm.Text(
                                  '把 "$selected" 与 "$src" 合并\n'
                                  '另存为 "$dst"?',
                                  style: fm.TextStyle(fontSize: 20)),
                              actions: [
                                fm.TextButton(
                                    onPressed: () =>
                                        fm.Navigator.of(mctx).pop(false),
                                    child: fm.Text('取消')),
                                fm.TextButton(
                                    onPressed: () =>
                                        fm.Navigator.of(mctx).pop(true),
                                    child: fm.Text('合并')),
                              ],
                            ));
                        if (ok != true) return;
                        //  打开 Only 表并执行合并
                        final onlyTable =
                            await flow.openCallerTable(selected);
                        final count = await CallerTable.mergeAndSaveAs(
                            prefs, onlyTable, src, dst,
                            sourceRequired: lvIdx > 0);
                        _mgmtSnackBar(
                            '已合并另存 $dst(共$count条)');
                        await _refreshTableNames(prefs, tableNames);
                        setState(() { selected = dst; });
                      }),
                      _tableMgmtButton(ctx, selected.isNotBlank, '补全',
                          () async {
                        final ok = await fm.showDialog<bool>(
                            context: context,
                            builder: (dctx) => fm.AlertDialog(
                              title: fm.Text('补全映射表'),
                              content: fm.Text(
                                  '把口令库中全部口令写入"$selected"的映射表?'
                                  '\n(已存在的识别句不会重复)',
                                  style: fm.TextStyle(fontSize: 20)),
                              actions: [
                                fm.TextButton(
                                    onPressed: () =>
                                        fm.Navigator.of(dctx).pop(false),
                                    child: fm.Text('取消')),
                                fm.TextButton(
                                    onPressed: () =>
                                        fm.Navigator.of(dctx).pop(true),
                                    child: fm.Text('补全')),
                              ],
                            ));
                        if (ok != true || !mounted) return;
                        //  打开表并补全
                        final t = await flow.openCallerTable(selected);
                        final added = await t.populateAllCalls();
                        _mgmtSnackBar('补全完成:新增 $added 条,'
                            '共 ${t.rows.length} 条');
                        setState(() {});
                      }),
                    ],
                  ),
                ],
              ),
              actions: [
                fm.TextButton(onPressed: () {
                  fm.Navigator.of(ctx).pop();
                }, child: fm.Text('取消')),
                //  "确定"改为"打开":选中表或输入新表名后可用,
                //  打开时才要求输入口令
                //  选中映射表后"打开"按钮高亮,提示下一步操作
                fm.TextButton(
                    style: selected.isNotBlank
                        ? fm.TextButton.styleFrom(
                            backgroundColor: Color.BLUE,
                            foregroundColor: Color.WHITE)
                        : null,
                    onPressed: canOpen ? () async {
                      //  新建表:名字含级别后缀(无 _Only)自动追加
                      final name = selected.isNotBlank
                          ? selected : nameController.text.trim();
                      final isNew = !tableNames.contains(name);
                      if (isNew &&
                          name.contains(
                              RegExp(r'_(plus|a1|a2|c1|c2|c3a|c3b)$')) &&
                          !name.endsWith('_Only')) {
                        final onlyName = '${name}_Only';
                        nameController.text = onlyName;
                        //  显示提示
                        _mgmtSnackBar('已自动追加 _Only: $onlyName');
                      }
                      //  打开要求输入口令(同框切换到口令阶段)
                      passwordController.clear();
                      setState(() { passwordMode = '打开'; });
                    } : null,
                    child: fm.Text('打开')),
              ],
            );
          },
        ));
    nameController.dispose();
    passwordController.dispose();
    passwordFocus.dispose();
    return opened;
  }

  //  登录并打开映射表(登录取消返回 false)
  //  麦克风按钮与音乐按钮(未登录时)共用
  Future<bool> _loginAndOpenTable() async {
    if (!await _showCallerLogin(context)) return false;
    await _openCallerTable(context);
    return true;
  }

  //  打开(或新建)当前口令员的映射表,并以 SnackBar 告知结果
  Future<void> _openCallerTable(fm.BuildContext context) async {
    try {
      await flow.openCallerTable(flow.callerName);
    } catch (e) {
      //  防空表守卫拒绝(裸名且不存在):给出友好提示
      if (mounted)
        fm.ScaffoldMessenger.of(context).showSnackBar(fm.SnackBar(
            backgroundColor: Color.RED,
            duration: const Duration(seconds: 6),
            content: fm.Text(e.toString().replaceFirst('Exception: ', ''),
                style: fm.TextStyle(fontSize: 18))));
    }
  }

  //  ---- 背景音乐/节拍/语音识别流程(逻辑在 VoiceFlow 单例) ----
  //  登录确认后进入:提示播放音乐 → 监听到音乐(关提示,蓝闪)→ 节拍检测
  //  → 显示 N/分钟并接管 Dance Speed → 自动进入语音识别 →
  //  期间只监测音乐停止,停止后重新播放则重新检测节拍

  //  若动画正在播放,让当前速度立即生效
  void _applyDancerSpeed() {
    if (!mounted) return;
    try {
      pp.Provider.of<SequencerModel>(context, listen: false)
          .animation.applySpeedNow();
    } catch (_) {
      //  动画模型尚不可用时忽略,下次播放自然应用
    }
  }

  //  流程错误提示(麦克风/识别不可用)
  void _showFlowError() {
    final err = flow.lastError;
    flow.lastError = null;
    if (err == null || !mounted) return;
    later(() {
      fm.ScaffoldMessenger.of(context).showSnackBar(fm.SnackBar(
          backgroundColor: err == 'mic' ? Color.RED : Color.BLUE,
          duration: Duration(seconds: 5),
          content: fm.Text(
              err == 'mic' ? '无法访问麦克风,请检查权限后重试。'
                  : 'Sorry, speech recognition not available on this device.',
              style: GoogleFonts.roboto(fontSize: 20))));
    });
  }

  //  若 Calls 画面(或其子口令显示)开着则关闭
  void _closeCallsPageIfOpen() {
    if (!mounted) return;
    try {
      final tamState = pp.Provider.of<TamState>(context, listen: false);
      if (tamState.detailPage == DetailPage.CALLS)
        tamState.change(detailPage: DetailPage.NONE);
    } catch (_) {}
  }

  void _sendOneLine(SequencerModel model, String value) async {
    var hasError = false;
    //  纯主语(Heads/Ends/Line of 8…):不是可执行口令,Calls
    //  里也选不到——待补全记录期间键入纯主语直接存入,
    //  不走执行判定(分数用读法形式判定,8→eight)
    if (flow.pendingRecord != null) {
      final d = CallerTable.decomposeCall(
          CallerTable.spokenForm(value));
      if (d.$3.isEmpty && d.$1.isNotEmpty) {
        textFieldController.clear();
        await flow.completeRecordInit(value);
        _closeCallsPageIfOpen();
        later(() {
          later(() {
            focusNode.requestFocus();
          });
        });
        return;
      }
    }
    //  与手动键入一致:先把口令显示到输入行,再提交
    //  (等效"键入+回车",在禁止注入按键的设备上也能看到完整过程)。
    //  先清后写:输入框有残留内容时会拒绝接受新数据
    //  (等效先按框边X清除钮)
    textFieldController.clear();
    textFieldController.text = value;
    //  Process the call
    if (!(model.loadOneCall(value))) {
      hasError = true;
    }
    //  Animate from the previous position
    //if (model.animation.movingBeats > oldbeats) {
    //  model.animation.beater.beat = oldbeats;
    //  model.animation.doPlay();
    //}
    //  Erase it from the the text field, unless there's an error
    //  that the user might want to fix
    if (!hasError)
      textFieldController.clear();
    //  记录初始化:口令执行正确,把整个口令一起存入映射表记录,
    //  并恢复语音识别;执行失败(hasError)则保持待补全,
    //  口令员可继续修改输入再试
    if (!hasError && flow.pendingRecord != null) {
      await flow.completeRecordInit(value);
      //  口令输入完成:关闭 Calls 画面(及其子口令显示)回到序列器
      _closeCallsPageIfOpen();
    }
    //  语音识别的输出:向系统完成输出后再发送回车键
    //  (原生注入;系统禁止注入时静默忽略,上方"填入+提交"
    //  已实现等效的回车语义)
    if (_isVoiceCall)
      flow.sendEnterKey();
    //  And get the focus back for the next call
    //  Android needs a double postpone
    later(() {
      later((){
        focusNode.requestFocus();
      });
    });
  }

}


class SequencerUndoButton extends fm.StatelessWidget {
  @override
  fm.Widget build(fm.BuildContext context) {
    final model = pp.Provider.of<SequencerModel>(context,listen: false);
    return fm.Expanded(
        child: Button('Undo',onPressed: () {
          model.undoLastCall();
        })
    );
  }
}


class SequencerResetButton extends fm.StatelessWidget {
  @override
  fm.Widget build(fm.BuildContext context) {
    final model = pp.Provider.of<SequencerModel>(context,listen: false);
    return fm.Expanded(
        child: Button('Reset',onPressed: () {
          model.reset();
        })
    );
  }
}

class SequencerCopyButton extends fm.StatelessWidget {
  @override
  fm.Widget build(fm.BuildContext context) {
    final model = pp.Provider.of<SequencerModel>(context,listen: false);
    return fm.Expanded(
        child: Button('Copy',onPressed: () {
          model.copy();
          final count = model.calls.length;
          final countText = count == 1 ? '1 call' : '$count calls';
          fm.ScaffoldMessenger.of(context).showSnackBar(fm.SnackBar(
              backgroundColor: Color.BLUE,
              duration: Duration(seconds: 2),
              content: fm.Text('$countText copied to Clipboard.',
                  style: GoogleFonts.roboto(fontSize: 20))
          ));
        })
    );
  }
}

class SequencerPasteButton extends fm.StatelessWidget {

  Future<void> pasteDialog(fm.BuildContext context, String text) async {
    final model = pp.Provider.of<SequencerModel>(context,listen: false);
    final controller = fm.TextEditingController()..text = text;
    final here = text.isBlank ? ' Here' :  '';
    await fm.showDialog(context: context, builder: (ctx) =>
        fm.AlertDialog(
          title: fm.Text('Paste Sequence$here'),
          content: fm.TextField(
            controller: controller,
            maxLines: null,
          ),
          actions: [
            fm.TextButton(onPressed: () {
              fm.Navigator.of(context).pop();
              model.paste(controller.text);
            }, child: fm.Text('OK')),
            fm.TextButton(onPressed: () {
              fm.Navigator.of(context).pop();
            }, child: fm.Text('Cancel'))
          ],
        ));
  }

  @override
  fm.Widget build(fm.BuildContext context) {
    return fm.Expanded(
        child: Button('Paste',onPressed: () {
          //  Show the calls to paste
          //  and let the user confirm and edit
          fs.Clipboard.getData('text/plain').then((value) async {
            if (value is fs.ClipboardData) {
              await pasteDialog(context, value.text ?? '');
            }
            else  //  Sometimes Firefox goes here
              await pasteDialog(context, '');
          },
              //  Firefox does not support Clipboard, so let the user paste with ^V
              onError: (Object obj) async {
                await pasteDialog(context, '');
              }
          );
        })
    );
  }
}

class _OneLine extends fm.StatelessWidget {
  final String name;
  final String level;
  _OneLine(this.name,[this.level='']);

  @override
  fm.Widget build(fm.BuildContext context) => fm.Row(
    children: [
      fm.Flexible(
        child: fm.Container(
            alignment: fm.Alignment.centerLeft,
            padding: fm.EdgeInsets.only(left: 20.0),
            child: AutoSizeText(name, style: fm.TextStyle(fontSize: 20))
        ),
      ),
      fm.Container(
          alignment: fm.Alignment.topRight,
          padding: fm.EdgeInsets.only(top:2,right:2),
          child: fm.Text(level)
      )
    ],
  );
}
