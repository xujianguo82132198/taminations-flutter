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

import 'package:flutter/material.dart' as fm;
import 'package:shared_preferences/shared_preferences.dart';

import '../common_flutter.dart';
import 'caller_store.dart';
import 'dual_speech_to_text.dart';

///  建表向导:逐行朗读建立映射表的第2列(语音识别结果)。
///
///  步骤 A(进入前已由数据层完成):建立 "<级别>Only" 空表,
///        第3列已预写该级别全部口令(含子口令)。
///  步骤 B(本页):光标停在第2列待识别行;按住
///        "按下此钮朗读右侧口令"朗读该行口令,抬起后识别结果
///        进入输入框(可反复识别),按"识别确认"写入表内第2列并
///        移到下一行;可随时中断,以后继续(已确认行持久保存)。
///  步骤 C/D(最后一行确认后自动):与低一级别表合并、总体排序、
///        另存为级别表名(去掉 Only),Only 表删除。
class TableBuilderPage extends StatefulWidget {

  ///  级别目录名,如 ms / plus / a1 ...
  final String level;

  const TableBuilderPage({super.key, required this.level});

  @override
  _TableBuilderPageState createState() => _TableBuilderPageState();

}

class _TableBuilderPageState extends fm.State<TableBuilderPage> {

  static const _lowerLevel = {
    'plus': 'ms', 'a1': 'plus', 'a2': 'a1',
    'c1': 'a2', 'c2': 'c1', 'c3a': 'c2', 'c3b': 'c3a',
  };

  CallerTable? table;
  int cursor = 0;          //  当前待识别行(rows 下标)
  final input = fm.TextEditingController();
  final speech = DualSpeechProvider();
  var confirmVisible = false;
  var pttActive = false;
  var finishing = false;

  @override
  void initState() {
    super.initState();
    _open();
    speech.addListener(_onSpeech);
  }

  Future<void> _open() async {
    final prefs = await SharedPreferences.getInstance();
    table = await CallerTable.createLevelOnlyTable(prefs, widget.level);
    _skipToPending();
    setState(() {});
  }

  ///  光标移到第2列为空的下一行(续建时跳过已完成的行)
  void _skipToPending() {
    final t = table;
    if (t == null) return;
    while (cursor < t.rows.length &&
        t.rows[cursor].recognized.isNotBlank)
      cursor++;
  }

  void _onSpeech() {
    if (!mounted || !speech.hasResults) return;
    input.text = speech.lastResult!.recognizedWords;
    speech.clearResults();
    setState(() => confirmVisible = true);
  }

  void _pttDown() {
    if (finishing || table == null) return;
    setState(() {
      pttActive = true;
      confirmVisible = false;
      input.clear();
    });
    speech.initialize().whenComplete(() =>
        speech.sample(localeId: 'en_US'));
  }

  void _pttUp() {
    if (!pttActive) return;
    setState(() => pttActive = false);
    speech.stop();
  }

  ///  识别确认:输入框内容写入当前行第2列,移到下一待识别行;
  ///  最后一行完成后自动执行合并/排序/另存
  Future<void> _confirm() async {
    final t = table;
    if (t == null || finishing) return;
    final text = input.text.trim();
    if (text.isBlank) return;
    await t.updateRow(t.rows[cursor].seq, recognized: text);
    input.clear();
    setState(() => confirmVisible = false);
    _skipToPending();
    if (cursor >= t.rows.length) {
      await _finish();
    }
    setState(() {});
  }

  ///  步骤 C/D:与低一级别表合并 -> 总体排序 -> 另存为级别表
  Future<void> _finish() async {
    finishing = true;
    final prefs = await SharedPreferences.getInstance();
    final lower = _lowerLevel[widget.level];
    final count = await CallerTable.mergeOnlyAndSaveAs(
        prefs, widget.level);
    if (!mounted) return;
    fm.ShowDialog? _ = null;   //  ignore
    await fm.showDialog<void>(
        context: context,
        builder: (ctx) => fm.AlertDialog(
          title: fm.Text('建表完成'),
          content: fm.Text(
              '"${widget.level}"映射表已生成'
              '${lower != null ? '(已与低一级别 $lower 表合并)' : ''},'
              '\n共 $count 条,总体已排序。',
              style: fm.TextStyle(fontSize: 20)),
          actions: [
            fm.TextButton(
                onPressed: () => fm.Navigator.of(ctx).pop(),
                child: fm.Text('关闭')),
          ],
        ));
    if (mounted) fm.Navigator.of(context).pop();
  }

  @override
  void dispose() {
    speech.removeListener(_onSpeech);
    speech.dispose();
    input.dispose();
    super.dispose();
  }

  @override
  fm.Widget build(fm.BuildContext context) {
    final t = table;
    final total = t?.rows.length ?? 0;
    final done = t == null ? 0 :
        t.rows.where((r) => r.recognized.isNotBlank).length;
    final row = (t != null && cursor < t.rows.length)
        ? t.rows[cursor] : null;
    return fm.Scaffold(
      appBar: fm.AppBar(
        title: fm.Text('建表:${widget.level}Only '
            '($done/$total)'),
        backgroundColor: Color.MS,
      ),
      body: fm.Column(children: [
        //  当前待识别行:第3列口令大字显示(供朗读)
        fm.Container(
          width: double.infinity,
          color: Color.FLOOR,
          padding: fm.EdgeInsets.all(12),
          child: fm.Column(children: [
            fm.Text('第 ${row?.seq ?? '-' } 行 / 共 $total 行'
                '${row == null ? '(全部完成)' : ''}',
                style: fm.TextStyle(fontSize: 18)),
            fm.SizedBox(height: 6),
            fm.Text(row?.standardCall ?? '本级别口令已全部识别完成',
                style: fm.TextStyle(
                    fontSize: 28, fontWeight: fm.FontWeight.bold)),
          ]),
        ),
        //  输入框:识别结果先落此处(可改可重识),确认后才入表
        fm.Padding(
          padding: fm.EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: fm.TextField(
            controller: input,
            style: fm.TextStyle(fontSize: 24),
            decoration: fm.InputDecoration(
                labelText: '识别结果(先到此处,确认后入表)',
                labelStyle: fm.TextStyle(fontSize: 18)),
          ),
        ),
        //  按住朗读按钮
        fm.Padding(
          padding: fm.EdgeInsets.symmetric(horizontal: 12),
          child: fm.Listener(
            onPointerDown: (_) => _pttDown(),
            onPointerUp: (_) => _pttUp(),
            onPointerCancel: (_) => _pttUp(),
            child: fm.Container(
              width: double.infinity,
              padding: fm.EdgeInsets.symmetric(vertical: 14),
              alignment: fm.Alignment.center,
              decoration: fm.ShapeDecoration(
                  shape: fm.RoundedRectangleBorder(
                      borderRadius: fm.BorderRadius.circular(10)),
                  color: pttActive ? fm.Colors.blue : Color.WHITE,
                  side: fm.BorderSide(color: Color.BLUE, width: 2)),
              child: fm.Text('按下此钮朗读右侧口令',
                  style: fm.TextStyle(
                      fontSize: 24,
                      fontWeight: fm.FontWeight.bold,
                      color: pttActive ? Color.WHITE : Color.BLACK)),
            ),
          ),
        ),
        //  识别确认按钮(识别出结果后出现)
        if (confirmVisible)
          fm.Padding(
            padding: fm.EdgeInsets.all(12),
            child: fm.FilledButton(
              onPressed: _confirm,
              style: fm.FilledButton.styleFrom(
                  padding: fm.EdgeInsets.symmetric(
                      vertical: 12, horizontal: 32)),
              child: fm.Text('识别确认',
                  style: fm.TextStyle(fontSize: 24)),
            ),
          ),
        fm.Spacer(),
        //  中断退出(进度已保存,以后可继续)
        fm.Padding(
          padding: fm.EdgeInsets.all(12),
          child: fm.OutlinedButton(
            onPressed: () => fm.Navigator.of(context).pop(),
            child: fm.Text('中断退出(进度已保存,可继续)',
                style: fm.TextStyle(fontSize: 18)),
          ),
        ),
      ]),
    );
  }

}
