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

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../animated_call.dart';
import '../call_index.dart';
import '../extensions.dart';

///  口令员映射表的一行,共 3 列:
///  1. 序号(行在表中的位置,1 起,增删/排序后自动重排)
///  2. 语音识别结果(麦克风识别出的原始文字)
///  3. 标准口令(匹配到的标准指令名)
///  (原第 4 列"级别"已按需求删除,不再存储;
///   读入旧数据时其中的级别信息会被忽略)
class CallerRow {

  ///  序号可变:排序/重排时原地更新,行对象身份保持稳定,
  ///  便于记录初始化期间按对象跟踪待补全的行
  int seq;
  final String recognized;
  final String standardCall;

  CallerRow({required this.seq, required this.recognized,
    required this.standardCall});

  Map<String, dynamic> toJson() =>
      {'seq': seq, 'recognized': recognized, 'standardCall': standardCall};

  ///  序号重排后的行列表(供合并输出)
  static List<CallerRow> emptyList(List<CallerRow> list) {
    for (var i = 0; i < list.length; i++)
      list[i].seq = i + 1;
    return list;
  }

  static CallerRow fromJson(Map<dynamic, dynamic> json) => CallerRow(
      seq: (json['seq'] as num).toInt(),
      recognized: json['recognized']?.toString() ?? '',
      standardCall: json['standardCall']?.toString() ?? '');

}

///  口令员数据表
///  存储区为每个口令员建立一张独立的映射表,表名即口令员姓名。
///  表由不限行数的 CallerRow 组成,整体以 JSON 序列化保存在
///  SharedPreferences 的 "口令员表 <姓名>" 键下。
///  open() 会检查表是否已存在:存在则读入,不存在则新建空表。
///  记录增删会通知监听者,供"全程显示全部记录"的面板实时刷新。
class CallerTable extends ChangeNotifier {

  ///  存储键前缀,后接口令员姓名
  static const _keyPrefix = '口令员表 ';

  ///  存储区中全部映射表的表名(即口令员姓名),按字典序
  static List<String> listTableNames(SharedPreferences prefs) {
    final names = prefs.getKeys()
        .where((k) => k.startsWith(_keyPrefix))
        .map((k) => k.substring(_keyPrefix.length))
        .where((name) => name.isNotBlank)
        .toList();
    names.sort();
    return names;
  }

  // ------------------------------------------------ 建表向导

  ///  建表步骤 A:建立 "<级别>Only" 空表(第3列预写该级别全部口令,
  ///  含子口令;第2列留空待逐行朗读识别)。已存在则直接返回(续建)
  static Future<CallerTable> createLevelOnlyTable(
      SharedPreferences prefs, String level) async {
    final name = '${level}Only';
    final existing = prefs.getString(_storageKey(name));
    if (existing != null)
      return await CallerTable.open(name);
    final table = await CallerTable.open(name);
    for (final entry in callIndex) {
      if (entry.level != level) continue;
      for (var call in flattenAnimatedCallList(entry.calls)) {
        final title = call.title;
        final dup = table.rows.any((r) => r.standardCall == title);
        if (!dup)
          await table.addRow(recognized: '', standardCall: title);
      }
    }
    return table;
  }

  ///  建表步骤 C/D:Only 表(第2列已填)与低一级别表合并,
  ///  总体排序后另存为级别名(去掉 Only),Only 表随即删除。
  ///  返回最终表的记录数;lowerName 为空则不合并
  static Future<int> mergeOnlyAndSaveAs(SharedPreferences prefs,
      String level) async {
    final onlyRaw = prefs.getString(_storageKey('${level}Only'));
    if (onlyRaw == null) return 0;
    final rows = <Map<String, dynamic>>[];
    for (final src in ['${level}Only', level]) {
      final raw = prefs.getString(_storageKey(src));
      if (raw == null) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['rows'] is List) {
          for (final r in decoded['rows']) {
            if (r is Map)
              rows.add({
                'recognized': r['recognized']?.toString() ?? '',
                'standardCall': r['standardCall']?.toString() ?? '',
              });
          }
        }
      } on FormatException {}
    }
    //  去重(识别结果+口令完全相同)并按识别结果字典序排序
    final seen = <String>{};
    final unique = <Map<String, dynamic>>[];
    for (final r in rows) {
      final k = '${r['recognized']}|${r['standardCall']}';
      if (seen.add(k)) unique.add(r);
    }
    unique.sort((a, b) =>
        a['recognized'].toString().toLowerCase()
            .compareTo(b['recognized'].toString().toLowerCase()));
    final numbered = [
      for (var i = 0; i < unique.length; i++)
        {...unique[i], 'seq': i + 1}
    ];
    await prefs.setString(_storageKey(level),
        jsonEncode({'rows': numbered}));
    await prefs.remove(_storageKey('${level}Only'));
    return numbered.length;
  }

  // ------------------------------------------------ 表管理

  static String _storageKey(String name) => '$_keyPrefix$name';

  ///  删除指定表(不可恢复)
  static Future<void> deleteTable(SharedPreferences prefs, String name) async {
    await prefs.remove(_storageKey(name));
  }

  ///  重命名表(原表数据移动到新表名下)。
  ///  返回 false 表示原名不存在或新名已被占用
  static Future<bool> renameTable(SharedPreferences prefs,
      String oldName, String newName) async {
    final oldKey = _storageKey(oldName);
    final newKey = _storageKey(newName);
    if (prefs.getString(oldKey) == null || prefs.containsKey(newKey))
      return false;
    await prefs.setString(newKey, prefs.getString(oldKey)!);
    await prefs.remove(oldKey);
    return true;
  }

  ///  另存为:把源表内容复制到新表名(源表保留)。
  ///  返回 false 表示源不存在或目标已占用
  static Future<bool> saveTableAs(SharedPreferences prefs,
      String sourceName, String targetName) async {
    final src = prefs.getString(_storageKey(sourceName));
    if (src == null || prefs.containsKey(_storageKey(targetName)))
      return false;
    await prefs.setString(_storageKey(targetName), src);
    return true;
  }

  ///  导出:返回表的 ysb 文件内容(JSON 文本)
  static String? exportYsb(SharedPreferences prefs, String name) =>
      prefs.getString(_storageKey(name));

  ///  导入:把 ysb 文件内容存为指定表名的表(已存在则覆盖)。
  ///  返回 false 表示内容格式无效
  static Future<bool> importYsb(SharedPreferences prefs,
      String name, String content) async {
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map || decoded['rows'] is! List)
        return false;
      for (final r in decoded['rows']) {
        if (r is! Map || r['recognized'] == null)
          return false;
      }
    } on FormatException {
      return false;
    }
    await prefs.setString(_storageKey(name), content);
    return true;
  }

  final SharedPreferences prefs;
  final String callerName;

  ///  最近一次 open 是否为新建的表
  final bool wasCreated;

  ///  表内容,后续功能从这里读写
  final List<CallerRow> rows;

  CallerTable._(this.prefs, this.callerName, this.rows, this.wasCreated);

  String get _key => '$_keyPrefix$callerName';

  ///  当前最大序号,空表为 0
  int get lastSeq => rows.isEmpty ? 0 : rows.last.seq;

  //  打开指定口令员的映射表,没有则以姓名为表名新建一张
  static Future<CallerTable> open(String callerName) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_keyPrefix$callerName';
    final raw = prefs.getString(key);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['rows'] is List) {
          final rows = (decoded['rows'] as List)
              .whereType<Map>()
              .map(CallerRow.fromJson)
              .toList();
          return CallerTable._(prefs, callerName, rows, false);
        }
      } on FormatException {
        //  内容损坏,按不存在处理,下面重建
      }
    }
    final table = CallerTable._(prefs, callerName, [], true);
    await table.save();
    return table;
  }

  Future<void> save() async {
    await prefs.setString(_key, jsonEncode({'rows': rows}));
    notifyListeners();
  }

  ///  追加一行,序号自动在上行基础上加 1;
  ///  增加后整表按"语音识别结果"的 A,B,C... 字典序排序,
  ///  序号原地重排(行对象身份不变)
  Future<CallerRow> addRow(
      {required String recognized,
       String standardCall = ''}) async {
    final row = CallerRow(seq: lastSeq + 1, recognized: recognized,
        standardCall: standardCall);
    rows.add(row);
    await _sortAndRenumber();
    return row;
  }

  ///  更新指定序号记录的内容(未提供的列保持原值),更新后重新排序。
  ///  返回更新后的行对象(排序后序号可能变化)
  Future<CallerRow?> updateRow(int seq, {String? recognized,
      String? standardCall, bool sort = true}) async {
    final index = rows.indexWhere((r) => r.seq == seq);
    if (index < 0) return null;
    final old = rows[index];
    final updated = CallerRow(seq: old.seq,
        recognized: recognized ?? old.recognized,
        standardCall: standardCall ?? old.standardCall);
    rows[index] = updated;
    if (sort)
      await _sortAndRenumber();
    else
      await save();
    return updated;
  }

  ///  删除指定序号的行(序号从 1 开始),其余行序号自动重排
  Future<bool> removeRow(int seq) async {
    final index = rows.indexWhere((r) => r.seq == seq);
    if (index < 0) return false;
    rows.removeAt(index);
    await _renumber();
    return true;
  }

  ///  清空全部行
  Future<void> clear() async {
    rows.clear();
    await save();
  }

  Future<void> _renumber() async {
    for (var i = 0; i < rows.length; i++)
      rows[i].seq = i + 1;   //  原地更新,行对象身份不变
    await save();
  }

  ///  整表按"语音识别结果"字典序(A,B,C...)排序并重排序号
  Future<void> _sortAndRenumber() async {
    rows.sort((a, b) =>
        a.recognized.toLowerCase().compareTo(b.recognized.toLowerCase()));
    for (var i = 0; i < rows.length; i++)
      rows[i].seq = i + 1;
    await save();
  }

  ///  不排序追加(建Only工作表用:保持口令库顺序)
  Future<void> appendRowNoSort(
      {required String recognized, required String standardCall}) async {
    rows.add(CallerRow(seq: lastSeq + 1,
        recognized: recognized, standardCall: standardCall));
    await save();
  }

  ///  建Only工作表:第3列=指定级别全部口令(含子口令,去重),第2列空
  static Future<CallerTable> createOnlyTable(SharedPreferences prefs,
      String tableName, String levelDir) async {
    await prefs.setString(_keyPrefix + tableName, '{"rows":[]}');
    final t = await CallerTable.open(tableName);
    final titles = <String>[];
    for (final entry in callIndex) {
      if (entry.level != levelDir) continue;
      for (final call in flattenAnimatedCallList(entry.calls)) {
        if (!titles.contains(call.title))
          titles.add(call.title);
      }
    }
    for (final title in titles)
      await t.appendRowNoSort(recognized: '', standardCall: title);
    return t;
  }

  ///  合并另存:本表各行(第2列非空) + 源表全部行,
  ///  按第2列总体排序,存为目标表名
  static Future<int> mergeAndSaveAs(SharedPreferences prefs,
      CallerTable only, String sourceName, String targetName) async {
    final src = prefs.getString(_keyPrefix + sourceName);
    final merged = <CallerRow>[];
    if (src != null) {
      try {
        final d = jsonDecode(src);
        if (d is Map && d['rows'] is List) {
          for (final r in d['rows']) {
            if (r is Map)
              merged.add(CallerRow.fromJson(r));
          }
        }
      } on FormatException {}
    }
    for (final r in only.rows) {
      if (r.recognized.isNotBlank)
        merged.add(CallerRow(seq: 0,
            recognized: r.recognized, standardCall: r.standardCall));
    }
    merged.sort((a, b) =>
        a.recognized.toLowerCase().compareTo(b.recognized.toLowerCase()));
    final out = CallerRow.emptyList(merged);
    await prefs.setString(_keyPrefix + targetName,
        jsonEncode({'rows': out}));
    return merged.length;
  }

  ///  表补全:把口令库中全部口令写入映射表(第二列=口令名,
  ///  第三列=同一口令名),使喊口令时标准说法即可命中。
  ///  已存在的识别句(归一化后相同)不重复添加。
  ///  返回新增条数。
  Future<int> populateAllCalls() async {
    var added = 0;
    for (final entry in callIndex) {
      final title = entry.title;
      final norm = _normalize(title);
      final exists = rows.any((r) => _normalize(r.recognized) == norm);
      if (!exists) {
        rows.add(CallerRow(seq: 0, recognized: title, standardCall: title));
        added++;
      }
    }
    if (added > 0)
      await _sortAndRenumber();
    return added;
  }

  // ------------------------------------------------ 识别结果查询

  ///  归一化两句话(小写、去标点、压缩空白)
  static String _normalize(String s) =>
      s.toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fa5]+'), ' ')
          .trim();

  ///  计算两句话的误差(归一化编辑距离 / 较长者长度,0~1,越小越相似)
  static double sentenceError(String a, String b) {
    final s1 = _normalize(a);
    final s2 = _normalize(b);
    if (s1.isEmpty && s2.isEmpty) return 0;
    if (s1.isEmpty || s2.isEmpty) return 1;
    final m = s1.length, n = s2.length;
    final d = List.generate(m + 1, (i) => List.filled(n + 1, 0));
    for (var i = 0; i <= m; i++) d[i][0] = i;
    for (var j = 0; j <= n; j++) d[0][j] = j;
    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        final cost = s1[i - 1] == s2[j - 1] ? 0 : 1;
        d[i][j] = _min3(d[i - 1][j] + 1, d[i][j - 1] + 1,
            d[i - 1][j - 1] + cost);
      }
    }
    return d[m][n] / (m > n ? m : n);
  }

  static int _min3(int a, int b, int c) {
    var v = a;
    if (b < v) v = b;
    if (c < v) v = c;
    return v;
  }

  ///  语音识别后的查表(沿序号早停,无门槛):
  ///  表已按 A,B,C... 字典序排序,相似记录聚集,误差沿序号
  ///  呈"先降后升"的谷形。当误差越来越低时继续沿序号寻访,
  ///  当误差变大时停止寻访,取刚才那个为误差最低者。
  ///  不设误差门槛,选中的记录即执行(表覆盖完整由"补全"保证)。
  ///  返回:hit=选中的记录(空表为 null),
  ///  candidate=同一记录(供界面居中突出显示),error=其误差
  ({CallerRow? hit, CallerRow? candidate, double error})
      lookupSequential(String sentence) {
    if (rows.isEmpty)
      return (hit: null, candidate: null, error: 1.0);
    CallerRow? best;
    var bestErr = double.infinity;
    for (final row in rows) {
      final err = sentenceError(row.recognized, sentence);
      if (err < bestErr) {
        bestErr = err;
        best = row;
      } else
        break;  //  误差变大,停止寻访,刚才那个即误差最低者
    }
    return (hit: best, candidate: best, error: bestErr);
  }

}
