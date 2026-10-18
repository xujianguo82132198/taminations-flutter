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
import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart' as fm;
import 'package:provider/provider.dart' as pp;

import '../animated_call.dart';
import '../call_entry.dart';
import '../call_index.dart';
import '../common_flutter.dart';
import '../pages/calls_page.dart';
import '../pages/page.dart';
import 'voice_flow.dart';
import 'caller_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SequencerCallsPage extends fm.StatelessWidget {

  @override
  fm.Widget build(fm.BuildContext context) {
    return Page(child: SequencerCallsFrame());
  }

}

class SequencerCallsFrame extends fm.StatefulWidget {
  @override
  _SequencerCallsFrameState createState() => _SequencerCallsFrameState();
}

class SequencerCallsModel extends fm.ChangeNotifier {

  var callsSelected = <CallEntry>[];
  final _levelsSelected = <LevelData,bool>{
    LevelData.MS : false,
    LevelData.PLUS : false,
    LevelData.A1 : false,
    LevelData.A2 : false,
    LevelData.C1 : false,
    LevelData.C2 : false,
    LevelData.C3A : false,
    LevelData.C3B : false
  };
  bool levelSelected(LevelData level) => _levelsSelected[level]!;

  ///  PSfix选择(用户:级别区加PSfix,展示其标准口令列,
  ///  供选择法挑前后缀口令;与级别勾选互斥)
  bool psfixSelected = false;
  List<String> psfixCalls = const [];

  void setPsfix(bool v) {
    if (psfixSelected == v) return;
    psfixSelected = v;
    if (v) {
      for (final l in _levelsSelected.keys.toList()) {
        _levelsSelected[l] = false;
      }
      callsSelected = [];
    }
    notifyListeners();
  }

  void setSelected(LevelData level, bool value) {
    if (_levelsSelected[level] != value) {
      _levelsSelected[level] = value;
      callsSelected = callIndex.where((element) =>
      _levelsSelected[LevelData.find(element.link)] ?? false).toList();
      notifyListeners();
    }
  }

}


///  基础名"非独立口令"的条目(概念页/文档页/<anything>模板/
/// 同义家族名如 Arm Turns):由 test/base_known_test.dart 用
/// 完整解析管道扫描生成——基础名报"not found"者不进子口令
/// 首行(放了也执行不了)。升级上游定义后重跑该测试刷新本表
const baseNotCall = {
  'Alamo Style',
  'All 4 Couples / All 8 concepts',
  'Any Hand Concept',
  'Any Tagging Call and Scatter',
  'Anyone Hop',
  '<anything> and Circle',
  'Anything Concept',
  '<anything> Reaction',
  '<anything> the Windmill',
  '<anything>er\'s Couple Up',
  'Arm Turns',
  'As Couples Concept',
  'Backtrack',
  'Big Block Concept',
  'Bounce the Anyone',
  'Busy <anything>',
  'Catch 1, 2, 3, 4',
  'Catch <anything>',
  'Central Concept',
  'Chase the fraction Tag',
  'Checkerboard <anything>',
  'Circle Left / Right',
  'Circle Rule',
  'Concentric Concept',
  'Crazy Concept',
  'Cross Concentric Concept',
  'Delete',
  'Diagonal Box Concept',
  'Disconnected Concept',
  'Divide the Ocean | Sea <direction> | <anything>',
  'Drop In/Out/Right/Left',
  'Echo Concept',
  'Exchange the Triangles',
  'Face Left / Right / In / Out',
  'Facing Couples Rule',
  'Fan Concept',
  'Fascinate/Fascinating',
  'Finally Concept',
  'First Couple Go Left/Right, Next Couple Go Left/Right',
  'First Half Concept',
  'Fourthly',
  'Fractional Tops',
  'Funny Concept',
  'Galaxy Formation',
  'Generous',
  'Grand Drop',
  'Initially Concept',
  'Interlocked 3 by 1 Triangle Formation',
  'Interlocked Triangle Formation',
  'Jay Concept',
  'Left Arm Turn',
  'Magic Column Formation / Concept',
  'Mirror Concept',
  'O Formation / Concept',
  'Ocean Wave',
  'Ocean Wave Rule',
  'Oddly | Evenly Concept',
  'Offset Concept',
  'Once Removed Concept',
  'Open Up',
  'Parallelogram Concept',
  'Passing Rule',
  'Patch Anyone',
  'Prefer',
  'Press In / Out / Left / Right',
  'Quadruple Formation Concept',
  'Quick',
  'Reflected Concept',
  'Release <anything>',
  'Relocate the formation',
  'Reverse Checkpoint <anything> By <anything>',
  'Reverse Crazy Concept',
  'Reverse Cut/Flip the 3 by 1 Triangle',
  'Reverse Cut/Flip the Diamond',
  'Reverse Cut/Flip the Galaxy',
  'Reverse Cut/Flip the Z',
  'Reverse Echo',
  'Reverse Order Concept',
  'Right Arm Turn',
  'Right / Left Hand Star',
  'Same Position Rule',
  'Secondly',
  'See Saw',
  'Siamese Concept',
  'Single Concept',
  'Skip',
  'Slant',
  'Solid Concept',
  'Spin the Windmill',
  'Split Phantom Boxes Concept',
  'Split Phantom Columns / Lines / Waves Concept',
  'Squared Set Convention',
  'Stable Concept',
  'n Steps At A Time',
  'Stingy',
  'Stretch Concept',
  'Stretched Concept',
  'Strip the Diamond / Hourglass',
  'Strut',
  'Swing and Circle',
  'T-Bone Formation',
  'Take {n}',
  'Tandem Concept',
  'Tandem-Based Triangle Formation',
  'Thar Family',
  'Thirdly',
  'Trapezoid Formation',
  'Triple Diamond Concept',
  'Triple Formations',
  'Two-Faced Concept',
  'Twosome Concept',
  'Unwrap',
  'Veer Left / Right',
  'Wave the anyone',
  'Wrap To a Formation',
  'Wrong Way Promenade',
  'Z Concept',
  'Zip Code',
};

class _SequencerCallsFrameState extends fm.State<SequencerCallsFrame> {

  final callsModel = SequencerCallsModel();
  final flow = VoiceFlow.instance;

  @override
  void initState() {
    super.initState();
    _loadPsfixFresh();
  }

  ///  每次进Calls画面现读PSfix表(用户:改表立刻生效不重启;
  ///  退出即弃——表对象随页面销毁,不缓存)
  Future<void> _loadPsfixFresh() async {
    try {
      //  未开表兜底(用户实测:重启后直接进Calls勾PSfix曾
      //  装填跳过→总数0)——扫全部目录的PSfix_Only合并装填
      final prefs = await SharedPreferences.getInstance();
      final all = CallerTable.listTableNames(prefs);
      final names = <String>[];
      final dir = flow.callerTable?.callerName.split('/').first;
      if (dir != null) {
        //  开表:本目录优先(PSfix_Only→PSfix,用户:Only
        //  按标准口令排序好找)
        names.addAll(['$dir/PSfix_Only', '$dir/PSfix']);
      }
      //  兜底:所有目录的PSfix_Only
      names.addAll(all
          .where((n) => n.endsWith('/PSfix_Only'))
          .where((n) => !names.contains(n)));
      final calls = <String>{};
      for (final name in names) {
        if (!prefs.containsKey('口令员表 $name')) continue;
        final t = await CallerTable.open(name);
        for (final r in t.rows) {
          //  标准口令列同过清洗:表里存过 "…Gears from" 这类
          //  带系统 "from" 尾巴的行,不洗则选上无法执行
          final c = CallerTable.cleanCallTitle(r.standardCall);
          if (c.isNotEmpty) calls.add(c);
        }
        debugPrint('PSfix选择表装填: +$name');
        break;   //  命中一张即用(本目录优先,否则首张)
      }
      callsModel.psfixCalls = calls.toList()..sort();
      debugPrint('PSfix选择表合计: ${callsModel.psfixCalls.length}条');
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('PSfix选择表装填失败: $e');
    }
  }

  //  口令包含的子口令(变体)标题。
  //  标题一律过 cleanCallTitle 清洗(去 "from"/括号注)——
  //  系统动画列表的展开组头带 "from"(如 "…Gears from"),
  //  不清洗就会选上一个无法执行的口令(用户:丢了口令)。
  //  基础口令名先入第一行(用户:Square Thru 的子口令第一行
  //  应是 Square Thru 本身——裸喊缺省 4 手,选择后还可键盘
  //  补数字如 6;若变体已含它,去重不会重复)。
  //  注意不过滤 notForSequencer:该标记只影响序列器索引,
  //  像 Run 的变体(Boys Run / Girls Run / Centers Run / Ends Run)
  //  全部带此标记但口令员可以喊、也需可选;选中的标题进入
  //  输入行后由序列器解析执行
  List<String> subCallTitles(CallEntry entry) {
    final titles = <String>[];
    //  基础名先入第一行,但概念/模板条目除外(黑名单)
    if (!baseNotCall.contains(entry.title)) {
      final base = CallerTable.cleanCallTitle(entry.title);
      if (base.isNotBlank)
        titles.add(base);
    }
    for (var call in flattenAnimatedCallList(entry.calls)) {
      final t = CallerTable.cleanCallTitle(call.title);
      if (t.isNotBlank && !titles.contains(t))
        titles.add(t);
    }
    return titles;
  }

  //  选定某个(子)口令:填入序列器输入行并关闭本画面。
  //  再洗一次:表里/列表来的串可能仍带 "from" 尾巴
  void _chooseCall(String title) {
    flow.selectCallForInit(CallerTable.cleanCallTitle(title));
    pp.Provider.of<TamState>(context, listen: false)
        .change(detailPage: DetailPage.NONE);
  }

  //  点选口令(任何时候可点):
  //  含多个子口令的以底部弹层(下拉表)列出,由口令员选择;
  //  无子口令的指令本身就是口令,直接选定。
  //  选定的口令填入序列器输入行;若有待补全的记录
  //  (记录初始化),执行正确后整个口令存入该记录
  Future<void> _onCallSelected(CallEntry entry) async {
    final subs = subCallTitles(entry);
    if (subs.length <= 1) {
      _chooseCall(entry.title);
      return;
    }
    final chosen = await fm.showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => fm.SafeArea(
          child: fm.Column(
            mainAxisSize: fm.MainAxisSize.min,
            crossAxisAlignment: fm.CrossAxisAlignment.start,
            children: [
              fm.Container(
                width: double.infinity,
                color: Color.BLUE,
                padding: fm.EdgeInsets.only(left: 12, top: 6, bottom: 6),
                child: fm.Text('『${entry.title}』的子口令:',
                    style: fm.TextStyle(fontSize: 20, color: Color.WHITE)),
              ),
              fm.Flexible(
                child: fm.ListView(
                  shrinkWrap: true,
                  children: [
                    for (final sub in subs)
                      fm.InkWell(
                        onTap: () => fm.Navigator.of(ctx).pop(sub),
                        child: fm.Container(
                          width: double.infinity,
                          padding: fm.EdgeInsets.only(
                              left: 20, top: 8, bottom: 8, right: 12),
                          decoration: fm.BoxDecoration(
                              border: fm.Border(
                                  bottom: fm.BorderSide(
                                      width: 1, color: Color.LIGHTGREY))),
                          child: fm.Text(sub,
                              style: fm.TextStyle(
                                  fontSize: 20,
                                  fontWeight: fm.FontWeight.bold)),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ));
    if (chosen != null)
      _chooseCall(chosen);
  }

  @override
  fm.Widget build(fm.BuildContext context) {
    //  Cell height = 1.3 x font height, growing with the user's font scale
    //  so enlarged (accessibility) text is never clipped vertically
    final textScale = fm.MediaQuery.textScalerOf(context).scale(16) / 16;
    return pp.ChangeNotifierProvider.value(
      value: callsModel,
      child: pp.Consumer<SequencerCallsModel>(
        builder: (context,_,__) {
          return fm.Column(children: [
              fm.Expanded(child: fm.GridView.builder(
                gridDelegate: fm.SliverGridDelegateWithMaxCrossAxisExtent(
                    //  单列整行显示,保证口令标题完整不截断
                    maxCrossAxisExtent: 420,
                    mainAxisSpacing: 1,
                    mainAxisExtent: 16 * 1.3 * textScale
                ),
                itemCount: callsModel.psfixSelected
                    ? callsModel.psfixCalls.length
                    : callsModel.callsSelected.length,
                itemBuilder: (_,index) {
                  //  PSfix态(用户:级别区选PSfix=列其标准口令,
                  //  点击直选,供选择法挑前后缀口令)
                  if (callsModel.psfixSelected) {
                    final title = callsModel.psfixCalls[index];
                    return fm.Container(
                      child: fm.Material(
                      color: const fm.Color(0xfffff8e1),
                      child: fm.InkWell(
                        onTap: () => _chooseCall(title),
                        child: fm.Container(
                          alignment: fm.Alignment.centerLeft,
                          padding: fm.EdgeInsets.only(left: 6, right: 6),
                          child: AutoSizeText(title,
                              maxLines: 1,
                              minFontSize: 11,
                              overflow: fm.TextOverflow.ellipsis,
                              style: fm.TextStyle(fontSize: 16)),
                        ),
                      ),
                      ),
                    );
                  }
                  final entry = callsModel.callsSelected[index];
                  return fm.Container(
                    child: fm.Material(
                    //  Color the item according the the level
                    color: LevelData.find(entry.link)!.color,
                    child: fm.InkWell(
                      onTap: () => _onCallSelected(entry),
                      child: fm.Container(
                        alignment: fm.Alignment.centerLeft,
                        padding: fm.EdgeInsets.only(left: 6, right: 6),
                        child: AutoSizeText(entry.title,
                            maxLines: 1,
                            minFontSize: 11,
                            overflow: fm.TextOverflow.ellipsis,
                            style: fm.TextStyle(fontSize: 16)),
                      ),
                    ),
                    )
                  );
                }

              )),
            fm.Row(children: [
              _LevelCheckbox(LevelData.MS),
              _LevelCheckbox(LevelData.C1)
            ]),
            fm.Row(children: [
              _LevelCheckbox(LevelData.PLUS),
              _LevelCheckbox(LevelData.C2)
            ]),
            fm.Row(children: [
              _LevelCheckbox(LevelData.A1),
              _LevelCheckbox(LevelData.C3A)
            ]),
            fm.Row(children: [
              _LevelCheckbox(LevelData.A2),
              _LevelCheckbox(LevelData.C3B)
            ]),
            //  PSfix选择+总数同排(用户:总数放PSfix右边,
            //  不另起行浪费空间)
            fm.Row(children: [
              fm.Expanded(
                child: _PsfixCheckbox(onEnable: _loadPsfixFresh),
              ),
              fm.Container(
                color: Color.WHITE,
                padding: fm.EdgeInsets.symmetric(
                    vertical: 8, horizontal: 16),
                child: fm.Text(
                    '总数: ${callsModel.psfixSelected
                        ? callsModel.psfixCalls.length
                        : callsModel.callsSelected.length}',
                    style: fm.TextStyle(
                        fontSize: 22,
                        fontWeight: fm.FontWeight.bold)),
              ),
            ]),
          ]);
        } ),
    );
  }

}


///  PSfix选择钮(用户:级别区的PSfix入口——与级别互斥;
/// 开启前现读表:页面常驻,initState只在启动跑一次,
/// 曾致装填永不发生/总数0)
class _PsfixCheckbox extends fm.StatefulWidget {
  final Future<void> Function() onEnable;
  _PsfixCheckbox({required this.onEnable});

  @override
  _PsfixCheckboxState createState() => _PsfixCheckboxState();
}

class _PsfixCheckboxState extends fm.State<_PsfixCheckbox> {
  Future<void> _toggle(bool value) async {
    if (value) {
      await widget.onEnable();
    }
    if (!mounted) return;
    setState(() {
      pp.Provider.of<SequencerCallsModel>(context, listen: false)
          .setPsfix(value);
    });
  }

  @override
  fm.Widget build(fm.BuildContext context) {
    return pp.Consumer<SequencerCallsModel>(
      builder: (context, callsModel, _) => fm.Expanded(
        child: fm.Container(
          color: Color.WHITE,   //  与选择区一致,不做特殊色
          child: fm.InkWell(
            onTap: () => _toggle(!callsModel.psfixSelected),
            child: fm.Row(children: [
              fm.Checkbox(
                  value: callsModel.psfixSelected,
                  onChanged: (value) => _toggle(value!)),
              const fm.Expanded(
                  child: AutoSizeText('PSfix',
                      maxLines: 1,
                      minFontSize: 8,
                      style: fm.TextStyle(fontSize: 20))),
            ]),
          ),
        ),
      ),
    );
  }
}

class _LevelCheckbox extends fm.StatefulWidget {
  final LevelData level;
  _LevelCheckbox(this.level);

  @override
  _LevelCheckboxState createState() => _LevelCheckboxState();
}

class _LevelCheckboxState extends fm.State<_LevelCheckbox> {
  @override
  fm.Widget build(fm.BuildContext context) {
    return pp.Consumer<SequencerCallsModel>(
      builder: (context,callsModel,_) => fm.Expanded(
        child: fm.Container(
          color: widget.level.color,
            child: fm.InkWell(
              onTap: () {
                setState(() {
                  callsModel.setSelected(widget.level,
                      !callsModel.levelSelected(widget.level));
                });
              },
              child: fm.Row (
                  children: [fm.Checkbox(
                      value: callsModel.levelSelected(widget.level),
                      onChanged: (value) {
                        setState(() {
                          callsModel.setSelected(widget.level,value!);
                        });
                      }
                  ),
                    fm.Expanded(child: AutoSizeText(widget.level.name,
                        maxLines: 1,
                        minFontSize: 8,
                        style: fm.TextStyle(fontSize: 20)))
                  ]),
            )),
      ),
    );
  }
}
