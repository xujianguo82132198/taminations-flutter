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
import 'package:flutter/material.dart' as fm;
import 'package:provider/provider.dart' as pp;

import '../animated_call.dart';
import '../call_entry.dart';
import '../call_index.dart';
import '../common_flutter.dart';
import '../pages/calls_page.dart';
import '../pages/page.dart';
import 'voice_flow.dart';

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

  void setSelected(LevelData level, bool value) {
    if (_levelsSelected[level] != value) {
      _levelsSelected[level] = value;
      callsSelected = callIndex.where((element) =>
      _levelsSelected[LevelData.find(element.link)] ?? false).toList();
      notifyListeners();
    }
  }

}


class _SequencerCallsFrameState extends fm.State<SequencerCallsFrame> {

  final callsModel = SequencerCallsModel();
  final flow = VoiceFlow.instance;

  //  口令包含的子口令(变体)标题。
  //  注意不过滤 notForSequencer:该标记只影响序列器索引,
  //  像 Run 的变体(Boys Run / Girls Run / Centers Run / Ends Run)
  //  全部带此标记但口令员可以喊、也需可选;选中的标题进入
  //  输入行后由序列器解析执行
  List<String> subCallTitles(CallEntry entry) {
    final titles = <String>[];
    for (var call in flattenAnimatedCallList(entry.calls)) {
      if (!titles.contains(call.title))
        titles.add(call.title);
    }
    return titles;
  }

  //  选定某个(子)口令:填入序列器输入行并关闭本画面
  void _chooseCall(String title) {
    flow.selectCallForInit(title);
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
                itemCount: callsModel.callsSelected.length,
                itemBuilder: (_,index) {
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
            //  当前勾选等级的口令总数
            fm.Container(
              width: double.infinity,
              color: Color.WHITE,
              padding: fm.EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              child: fm.Text('总数: ${callsModel.callsSelected.length}',
                  style: fm.TextStyle(fontSize: 22, fontWeight: fm.FontWeight.bold)),
            ),
          ]);
        } ),
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
