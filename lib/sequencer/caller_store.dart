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

  ///  表是否已存在(不创建):流水线加载辅助表(Prefix/Sufix)
  ///  用,避免凭空落盘空表
  static Future<bool> exists(String name) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('$_keyPrefix$name');
  }

  ///  历史修复:把含 "|" 的行拆回多行(合成曾把多归一的
  ///  几行归并成一行,违反"合成不得修改记录"——无损还原:
  ///  按 | 拆开,一行一笔,原样排列)。幂等
  static Future<int> splitPipedRows(SharedPreferences prefs) async {
    var n = 0;
    for (final name in listTableNames(prefs)) {
      final t = await open(name);
      var changed = false;
      final out = <CallerRow>[];
      for (final r in t.rows) {
        if (r.recognized.contains('|')) {
          final parts = r.recognized.split('|')
              .map((p) => p.trim())
              .where((p) => p.isNotEmpty)
              .toList();
          for (final p in parts) {
            out.add(CallerRow(
                seq: 0, recognized: p, standardCall: r.standardCall));
          }
          n += parts.length - 1;
          changed = true;
        } else {
          out.add(r);
        }
      }
      if (changed) {
        t.rows
          ..clear()
          ..addAll(out);
        for (var i = 0; i < t.rows.length; i++) {
          t.rows[i].seq = i + 1;
        }
        await t.save();
        debugPrint('splitPiped: $name -> ${t.rows.length} rows');
      }
    }
    return n;
  }

  ///  旧结构迁移:表名掺口令员名平铺存储(如 XuJianguo2_ms_Only)
  ///  → 目录结构 <口令员>/<表名>(如 XuJianguo2/ms_Only)。
  ///  每个口令员一个目录,合并等操作都在目录内进行,
  ///  从根上杜绝跨口令员误合并。返回迁移数(幂等,可重复调)
  static Future<int> migrateToDirectories(
      SharedPreferences prefs) async {
    const types = 'Prefix|Sufix|ms|plus|a1|a2|c1|c2|c3a|c3b';
    final re = RegExp('^(.+)_($types)(_Only)\$');
    var n = 0;
    for (final key in prefs
        .getKeys()
        .where((k) => k.startsWith(_keyPrefix))
        .toList()) {
      final name = key.substring(_keyPrefix.length);
      //  叠层名压平:X/Words/Words_Only -> X/Words_Only
      //  (建表对话框曾产生,后缀判定按最后一段也能容忍)
      final dup = RegExp(
              r'^(.*/)?(Prefix|Sufix|Words)/(Prefix|Sufix|Words)_Only\$')
          .firstMatch(name);
      if (dup != null) {
        final raw0 = prefs.getString(key);
        if (raw0 != null) {
          final flat = '${dup.group(1) ?? ''}${dup.group(3)}_Only';
          await prefs.setString('$_keyPrefix$flat', raw0);
          await prefs.remove(key);
          debugPrint('flattened: $name -> $flat');
        }
        continue;
      }
      if (name.contains('/')) continue;   //  已是目录结构
      final m = re.firstMatch(name);
      if (m == null) continue;            //  非标准命名,保留原样
      final caller = m.group(1)!;
      final table = '${m.group(2)}${m.group(3)}';
      final raw = prefs.getString(key);
      if (raw == null) continue;
      await prefs.setString('$_keyPrefix$caller/$table', raw);
      await prefs.remove(key);
      n++;
      debugPrint('migrated: $name -> $caller/$table');
    }
    return n;
  }

  // ------------------------------------------------ 建表向导

  ///  级别核心口令标题:与 Calls 页面同一取法——
  ///  callIndex 的 CallEntry 一条一个口令家族(Calls->
  ///  Mainstream 页面显示的总数即此数,MS 为 82),
  ///  不含子口令。用于 *_ms_Only 等采录表建表
  static List<String> coreCallTitles(String level) {
    final titles = <String>[];
    for (final entry in callIndex) {
      if (!entry.level.startsWith(level)) continue;
      if (entry.title.isBlank) continue;
      //  Left 开头的口令不引入(用户:Left 已入前缀库,
      //  Left 口令 = Left前缀 + 基础口令,由前缀表+流水线处理)
      if (entry.title.toLowerCase().startsWith('left')) continue;
      //  数量词开头的口令不引入(用户:3/4 等量词已入前缀库,
      //  如 Three Quarter Tag = 3/4前缀 + Tag,走流水线)
      final spoken = spokenForm(entry.title);
      const quantifierSpokens = [
        'three quarter', 'three quarters',
        'one half', 'half',
        'one and a half', 'two and a half', 'three and a half',
        'one and three', 'two and four',
        'one and two', 'three and four',
      ];
      var isQuantifierCall = false;
      for (final q in quantifierSpokens) {
        if (spoken == q || spoken.startsWith('$q ')) {
          isQuantifierCall = true;
          break;
        }
      }
      //  专用口令白名单(用户:Half Tag 是专用口令,整个识别,
      //  前面的 half 保持原样;Half Sashay Family 同理——
      //  没有裸 "Sashay" 核心可拆)
      const keepWhole = {'half tag', 'half sashay family'};
      if (keepWhole.contains(spoken)) isQuantifierCall = false;
      if (isQuantifierCall) continue;
      titles.add(entry.title);
    }
    return titles;
  }

  ///  级别采录表(*_ms_Only 等)建表:空表时插入该级别
  ///  **核心口令**(不含子口令,MS 约84条)每条3行(3归1)
  Future<int> seedLevelRows(String level) async {
    if (rows.isNotEmpty) return 0;
    final titles = coreCallTitles(level);
    for (final t in titles) {
      for (var i = 0; i < 3; i++) {
        await addRow(recognized: '', standardCall: t);
      }
    }
    return titles.length * 3;
  }

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
  ///  在指定行**上方**插入一个全空行(不排序,位置就地在
  ///  高亮行之上一眼可见),返回新行。增行功能专用
  Future<CallerRow> insertRowAbove(int seq,
      {String recognized = '',
      String standardCall = ''}) async {
    final index = rows.indexWhere((r) => r.seq == seq);
    final row = CallerRow(
        seq: 0, recognized: recognized, standardCall: standardCall);
    if (index < 0) {
      rows.add(row);
    } else {
      rows.insert(index, row);
    }
    for (var i = 0; i < rows.length; i++) rows[i].seq = i + 1;
    await save();
    notifyListeners();
    return row;
  }

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

  ///  清空全部记号(第2列),保留标准口令——用于换识别
  ///  体系后整体重录。返回清空的行数
  Future<int> clearAllTokens() async {
    var cleared = 0;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].recognized.isNotBlank) {
        rows[i] = CallerRow(
            seq: rows[i].seq,
            recognized: '',
            standardCall: rows[i].standardCall);
        cleared++;
      }
    }
    if (cleared > 0) await save();
    debugPrint('clearAllTokens: cleared $cleared rows');
    return cleared;
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
    //  标准口令为主,识别为辅:同一口令的3行(3归1)永远
    //  挨着——引入后不用滚动查找,录完一笔也不断散。
    //  合并表有自己的排序(以第一列为准),不受此影响
    rows.sort((a, b) {
      final c = a.standardCall.trim().toLowerCase()
          .compareTo(b.standardCall.trim().toLowerCase());
      if (c != 0) return c;
      return a.recognized.toLowerCase()
          .compareTo(b.recognized.toLowerCase());
    });
    for (var i = 0; i < rows.length; i++)
      rows[i].seq = i + 1;
    await save();
  }

  ///  清洗子口令标题:去掉括号中的 formation/位置描述、
  ///  "from xxx" 等非口令文字,保留纯口令名
  static String _cleanCallTitle(String title) {
    var t = title.trim();
    //  去掉以 "from " 开头的描述(如 "from Waves")
    t = t.replaceFirst(RegExp(r'\s+from\s+.*$'), '');
    //  去掉圆括号注释(如 "(Boys Lead)" "(As Couples)" 等)
    t = t.replaceAll(RegExp(r'\([^)]*\)'), '');
    //  去掉方括号注释
    t = t.replaceAll(RegExp(r'\[[^\]]*\]'), '');
    //  尖括号注释
    t = t.replaceAll(RegExp(r'<[^>]*>'), '');
    //  多余空格压缩
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
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
    //  级别累积:高级别表包含所有低级别口令(plus 含 ms,
    //  a1 含 plus/ms ……)——跳舞时高低口令混用,表必须全
    const levelOrder = [
      'ms', 'plus', 'a1', 'a2', 'c1', 'c2', 'c3a', 'c3b'
    ];
    final lv = levelOrder.indexOf(levelDir);
    for (final entry in callIndex) {
      if (lv >= 0 && levelOrder.indexOf(entry.level) > lv) continue;
      if (lv < 0 && entry.level != levelDir) continue;
      for (final call in flattenAnimatedCallList(entry.calls)) {
        final t = _cleanCallTitle(call.title);
        if (t.isNotBlank && !titles.contains(t))
          titles.add(t);
      }
    }
    //  一次性写入(逐条写入 333 次太慢)
    t.rows.clear();
    for (var i = 0; i < titles.length; i++)
      t.rows.add(CallerRow(seq: i + 1,
          recognized: '', standardCall: titles[i]));
    await t.save();
    debugPrint('createOnlyTable($levelDir): ${t.rows.length} rows');
    return t;
  }

  ///  清理:删除口令库中级别高于 levelDir 的行
  ///  (如 MS 的 Only 表里测试时误加的 Plus 口令)。
  ///  口令库查不到的自定义口令(如 boys circulate)保留。
  ///  返回删除的行数
  Future<int> purgeAboveLevel(String levelDir) async {
    const order = ['ms', 'plus', 'a1', 'a2', 'c1', 'c2', 'c3a', 'c3b'];
    final targetLv = order.indexOf(levelDir);
    if (targetLv < 0) return 0;
    final callLevels = <String, int>{};
    for (final entry in callIndex) {
      final li = order.indexOf(entry.level);
      for (final call in flattenAnimatedCallList(entry.calls)) {
        final key = _cleanCallTitle(call.title)
            .toLowerCase().replaceAll(RegExp(r'[^a-z ]'), '')
            .replaceAll(RegExp(r' +'), ' ').trim();
        if (key.isNotEmpty &&
            (!callLevels.containsKey(key) || li < callLevels[key]!))
          callLevels[key] = li;
      }
    }
    final before = rows.length;
    rows.removeWhere((r) {
      final key = r.standardCall.toLowerCase()
          .replaceAll(RegExp(r'[^a-z ]'), '')
          .replaceAll(RegExp(r' +'), ' ').trim();
      final li = callLevels[key];
      return li != null && li > targetLv;
    });
    final removed = before - rows.length;
    if (removed > 0) {
      await _sortAndRenumber();
      debugPrint('purgeAboveLevel($levelDir): removed $removed rows');
    }
    return removed;
  }

  ///  合并另存:本表各行(第2列非空) + 源表全部行,
  ///  按第2列总体排序,存为目标表名
  static Future<int> mergeAndSaveAs(SharedPreferences prefs,
      CallerTable only, String sourceName, String targetName,
      {bool sourceRequired = true}) async {
    //  级别过滤:从目标表名解析级别(ms/plus/a1...),
    //  合并结果只保留该级别及更低级别的口令——高级别口令
    //  (如测试时误加进 MS 表的 Acey Deucey)自动剔除;
    //  口令库中查不到的自定义口令(如 boys circulate)保留
    const lvOrder = ['ms', 'plus', 'a1', 'a2', 'c1', 'c2', 'c3a', 'c3b'];
    final lvMatch = RegExp(
            r'_(ms|plus|a1|a2|c1|c2|c3a|c3b)$')
        .firstMatch(targetName);
    final targetLv = lvMatch == null
        ? -1 : lvOrder.indexOf(lvMatch.group(1)!);
    Map<String, int>? callLevels;
    if (targetLv >= 0) {
      callLevels = {};
      for (final entry in callIndex) {
        final li = lvOrder.indexOf(entry.level);
        for (final call
            in flattenAnimatedCallList(entry.calls)) {
          final key = _cleanCallTitle(call.title)
              .toLowerCase().replaceAll(RegExp(r'[^a-z ]'), '')
              .replaceAll(RegExp(r' +'), ' ').trim();
          if (key.isNotEmpty &&
              (!callLevels.containsKey(key) || li < callLevels[key]!))
            callLevels[key] = li;
        }
      }
    }
    bool keepRow(String standardCall) {
      if (callLevels == null) return true;
      final key = standardCall.toLowerCase()
          .replaceAll(RegExp(r'[^a-z ]'), '')
          .replaceAll(RegExp(r' +'), ' ').trim();
      final li = callLevels[key];
      return li == null || li <= targetLv;   //  未知口令保留
    }
    //  源表名解析:允许下划线数量差异(如 XuJianguo__ms vs
    //  XuJianguo_ms)——取存在的那个;都没有则源表为空
    var src = prefs.getString(_keyPrefix + sourceName);
    if (src == null) {
      final names = listTableNames(prefs);
      final stem = sourceName.replaceAll('_', '');
      for (final n in names) {
        if (n.endsWith('_Only')) continue;
        if (n.replaceAll('_', '') == stem) {
          src = prefs.getString(_keyPrefix + n);
          debugPrint('merge source resolved: "$n"');
          break;
        }
      }
    }
    //  源表不存在:高级别(需下一级合并表)时中止并抛错,
    //  绝不生成缺记录的错误表;ms 级的基础源表是可选的
    //  (可能从未建过基础表,直接用 Only 表也能合并)
    if (src == null && sourceRequired)
      throw Exception('源表 "$sourceName" 不存在,合并已中止'
          '(请先完成下一级别的合并)');
    final merged = <CallerRow>[];
    if (src != null) {
      try {
        final d = jsonDecode(src);
        if (d is Map && d['rows'] is List) {
          for (final r in d['rows']) {
            if (r is Map) {
              final row = CallerRow.fromJson(r);
              if (keepRow(row.standardCall)) merged.add(row);
            }
          }
        }
      } on FormatException {}
    }
    //  级别累积合并:源表=下一级合并表(ms源=基础源表)。
    //  源表行全部保留;Only 表已录行替换源表同口令行。
    //  **合成不得修改记录**(用户原则):Only 表同口令的
    //  多行(多归一,每行一笔读法)原样进入合并表,一行对
    //  一行,不归并、不改写(曾以|拼接成一行,已废除);
    //  未录行不补默认记号(记号只能来自口令员采样)
    final onlyCalls = <String>{};
    for (final r in only.rows) {
      final callKey = r.standardCall.trim().toLowerCase();
      if (callKey.isEmpty || !keepRow(r.standardCall)) continue;
      if (r.recognized.isNotBlank) onlyCalls.add(callKey);
    }
    //  源表同口令行整体让位(Only 的最新读法优先)
    merged.removeWhere((m) =>
        onlyCalls.contains(m.standardCall.trim().toLowerCase()));
    for (final r in only.rows) {
      final callKey = r.standardCall.trim().toLowerCase();
      if (callKey.isEmpty || !keepRow(r.standardCall)) continue;
      if (r.recognized.isNotBlank) {
        merged.add(CallerRow(seq: 0,
            recognized: r.recognized, standardCall: r.standardCall));
      }
    }
    merged.sort((a, b) =>
        a.recognized.toLowerCase().compareTo(b.recognized.toLowerCase()));
    final out = CallerRow.emptyList(merged);
    await prefs.setString(_keyPrefix + targetName,
        jsonEncode({'rows': out}));
    //  合并诊断:总数+是否含关键子口令
    debugPrint('mergeAndSaveAs: only=${only.rows.length} '
        '-> merged=${merged.length} ($targetName)');
    for (final probe in ['boys turn back', 'girls turn back',
        'u turn back', 'girls backtrack']) {
      final hit = merged.any((r) =>
          r.standardCall.toLowerCase().contains(probe));
      debugPrint('merge probe "$probe": $hit');
    }
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
        final clean = _cleanCallTitle(title);
        if (clean.isNotBlank)
          rows.add(CallerRow(seq: 0, recognized: clean, standardCall: clean));
        added++;
      }
    }
    if (added > 0)
      await _sortAndRenumber();
    return added;
  }

  // ------------------------------------------------ 识别结果查询

  ///  归一化两句话(小写、去标点、压缩空白)
  ///  口令名 -> 口头读法:分数/数字转英文单词,
  ///  供语法词表与合并表默认记号使用(与实际念法一致)
  static String spokenForm(String s) {
    var t = s.toLowerCase();
    t = t
        .replaceAll('1-1/2', ' one and a half ')
        .replaceAll('2-1/2', ' two and a half ')
        .replaceAll('3-1/2', ' three and a half ')
        .replaceAll('3/4', ' three quarter ')
        .replaceAll('2/3', ' two third ')
        .replaceAll('1/4', ' one quarter ')
        .replaceAll('1/2', ' one half ');
    const digits = {
      '1': 'one', '2': 'two', '3': 'three', '4': 'four',
      '5': 'five', '6': 'six', '8': 'eight', '0': 'zero'
    };
    for (final e in digits.entries) {
      t = t.replaceAll(RegExp('\\b${e.key}\\b'), ' ${e.value} ');
    }
    return t
        .replaceAll(RegExp(r'[^a-z ]'), ' ')
        .replaceAll(RegExp(r' +'), ' ')
        .trim();
  }

  static String _normalize(String s) =>
      s.toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fa5]+'), ' ')
          //  同音写法统一,降低记号的表面差异
          .replaceAll(RegExp(r'\bu\b'), 'you')
          .replaceAll(RegExp(r'\baways?\b'), 'a')
          .replaceAll(RegExp(r' +'), ' ')
          .trim();

  //  ---- 结构化识别:前缀(主语) + 口令(±Left) + 后缀 ----
  ///  前缀库(用户定义):主语(谁做)+ 分数。
  ///  单复数等价由 _normPrefix 归一;
  ///  分数读法:1/4=one quarter、1/2=one half、3/4=
  ///  three quarter、1-1/2=one and (a) half(同一意思)
  static const _prefixWords = {
    //  主语
    'heads', 'head', 'sides', 'side', 'boys', 'girls',
    'leaders', 'leader', 'leads', 'trailers', 'trailer',
    'centers', 'center', 'ends', 'end', 'everyone', 'men',
    'women', 'couples',
    //  facing out / facing in
    'facing', 'out', 'in', 'home', 'full', 'an', 'around', 'on',
    'all', 'four', 'outer', 'six', 'outside', 'line', 'of', 'eight',
    'ladies',
    //  分数(读法词)
    'one', 'quarter', 'half', 'three', 'and', 'a',
  };
  ///  后缀库(用户定义):数字1-6、分数(1/4、1/2、3/4)、
  ///  后缀口令(Sweep a quarter,"More"忽略)、
  ///  Roll/Spread(不能单独存在,只能跟在口令后)
  static const _suffixWords = {
    //  数字
    'one', 'two', 'three', 'four', 'five', 'six',
    //  分数(含读法填充词)
    'quarter', 'half', 'and', 'a', 'an', 'the', 'of',
    //  后缀口令
    'roll', 'spread', 'sweep',
  };

  ///  可作后缀段的口令词(Roll/Spread/Sweep):
  ///  独立成段跟在口令后执行,分段取样时归入后缀段
  static const suffixCallWords = {'roll', 'spread', 'sweep'};

  ///  前缀主语种子行(用户设计:主语映射归口令员的表管理,
  ///  多归一——同一主语的多种读法各记一笔记号,都指向它)。
  ///  采录库表(*_Prefix_Only)空表建库时逐条种入;
  ///  记号一律由口令员采样,代码不含任何定制映射
  static const _seedSubjects = <String, String>{
    'Heads': 'heads',
    'Sides': 'sides',
    'Centers': 'centers',
    'Ends': 'ends',
    'Boys': 'boys',
    'Girls': 'girls',
    'Leaders': 'leaders',
    'Trailers': 'trailers',
    'Facing Out': 'facing out',
    'Facing In': 'facing in',
    'Line of 8': 'line of eight',
    'Line of 6': 'line of six',
    'End Ladies': 'end ladies',
    'Center Ladies': 'center ladies',
    'All Four Couples': 'all four couples',
    'Outer Six': 'outer six',
    'Outside Couples': 'outside couples',
    //  Left 作前缀(用户加入前缀库):Left 口令=Left前缀+基础口令
    'Left': 'left',
    //  量词前缀(用户加入):分数与对子编号。
    //  分数前缀与核心组合可超出选法库(如 2/3 Linear Cycle
    //  在 Calls 里找不到,但可执行;1/2 Boys Run 同理)
    '3/4': 'three quarter',
    '2/3': 'two third',
    '1/2': 'one half',
    '1-1/2': 'one and a half',
    '2-1/2': 'two and a half',
    '3-1/2': 'three and a half',
    '1 and 3': 'one and three',
    '2 and 4': 'two and four',
    '1 and 2': 'one and two',
    '3 and 4': 'three and four',
  };


  ///  关键词库(系统给出,口令员读音校准用):单音节/短词
  ///  为主——它们在整句识别中最易被联想吞掉。采录 Words
  ///  表时,当前行是单词则用**隔离语法**(词表只有该词),
  ///  解码器无联想可选,单音节结果必然可采集(教口令员
  ///  念到能被听清为止;[unk]=尚未到位,继续纠正)
  static const _seedWords = <String>[
    'turn', 'left', 'right', 'pass', 'thru', 'trade', 'run',
    'tag', 'box', 'fold', 'swing', 'spin', 'wheel', 'deal',
    'line', 'bend', 'split', 'cross', 'dive', 'roll',
    'spread', 'sweep', 'touch', 'walk', 'half', 'quarter',
    'full', 'back', 'chain', 'star',
  ];

  ///  后缀库(软件内置,任何口令员都需要的公共库):
  ///  数字1-6、分数、后缀口令(Sweep/Roll/Spread)
  static const _seedSuffixes = <String, String>{
    '1': 'one', '2': 'two', '3': 'three',
    '4': 'four', '5': 'five', '6': 'six',
    '1/4': 'one quarter', '1/2': 'one half',
    '3/4': 'three quarter', '1-1/2': 'one and a half',
    'Sweep 1/4': 'sweep a quarter',
    'Roll': 'roll', 'Spread': 'spread',
  };

  ///  采录库表(*_Prefix_Only / *_Sufix_Only)建库:
  ///  空表时插入全部库记录,每条拷贝3行(3归1:同一主语/
  ///  后缀可录3种读法;不足的空着,录完清理时删空行;
  ///  需要更多用"增行"按钮扩为4归1)
  ///  libKind: 'prefix' / 'suffix' / 'words'
  Future<int> seedLibraryRows({required String libKind}) async {
    //  按条目查缺补漏:库中没有该条目任何行才补3行
    //  (库后来新增的条目也能补进已建的表;
    //   已录/已清理过的条目不受影响,不重复插入)
    final lib = libKind == 'suffix'
        ? [for (final k in _seedSuffixes.keys) k]
        : (libKind == 'words'
            ? _seedWords
            : [for (final k in _seedSubjects.keys) k]);
    var n = 0;
    for (final display in lib) {
      final dl = display.toLowerCase();
      final exists = rows.any((r) =>
          r.standardCall.trim().toLowerCase() == dl);
      if (exists) continue;
      for (var i = 0; i < 3; i++) {
        await addRow(recognized: '', standardCall: display);
        n++;
      }
    }
    return n;
  }

  ///  清理全表(采录完成后统一做):
  ///  1) 删除空识别行(未录的拷贝行)
  ///  2) 第2,3列完全相同的行只保留1行
  ///  3) Words 关键词表:记号≠本行单词的**错位行**清零
  ///     (隔离语法下有效记号只能是本行单词本身,其余都是
  ///      旧会话错存,会持续制造冲突)
  ///  返回(删除空行数,去重行数)
  Future<(int, int)> cleanupTable({bool wordTable = false}) async {
    var empty = 0, dup = 0;
    if (wordTable) {
      for (var i = 0; i < rows.length; i++) {
        final r = rows[i];
        final w = r.standardCall.trim().toLowerCase();
        if (r.recognized.trim().isNotEmpty &&
            w.isNotEmpty &&
            !w.contains(' ') &&
            r.recognized.trim().toLowerCase() != w) {
          rows[i] = CallerRow(
              seq: r.seq, recognized: '', standardCall: r.standardCall);
          empty++;
          debugPrint('Words清理: 第${r.seq}行错位记号'
              '"${r.recognized}"清零(本行词=$w)');
        }
      }
    }
    final seen = <String>{};
    final keep = <CallerRow>[];
    for (final r in rows) {
      if (r.recognized.trim().isEmpty) {
        empty++;
        continue;
      }
      final key = '${r.recognized.trim().toLowerCase()}|'
          '${r.standardCall.trim().toLowerCase()}';
      if (seen.contains(key)) {
        dup++;
        continue;
      }
      seen.add(key);
      keep.add(r);
    }
    rows
      ..clear()
      ..addAll(keep);
    for (var i = 0; i < rows.length; i++) rows[i].seq = i + 1;
    await save();
    notifyListeners();
    return (empty, dup);
  }

  ///  分解口令字符串:(前缀, 是否Left, 口令核心, 后缀)。
  ///  前缀输出已归一(home/an/full/end → ends 等),
  ///  供选择与显示统一
  static (List<String>, bool, List<String>, List<String>)
      decomposeCall(String s) {
    final d = _decompose(_normalize(s)
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList());
    return (
      [for (final w in d.$1) _normPrefix(w)],
      d.$2,
      d.$3,
      d.$4,
    );
  }

  ///  分解:(前缀词列, 是否Left, 口令核心词列, 后缀词列)
  static (List<String>, bool, List<String>, List<String>)
      _decompose(List<String> w) {
    //  (个人近音折叠已删——主语映射归口令员的表,
    //  代码不再内置任何为特定口令员定制的多归一)
    //  前缀提取:循环摘词后必须归一命中唯一规范前缀
    //  (主语或分数);匹配不上则全部退回核心——保证流水
    //  下一级(口令核心)总能拿到干净的词列
    final startI = i0(w);
    final rawPrefix = <String>[];
    var i = startI;
    while (i < w.length && _prefixWords.contains(w[i])) {
      rawPrefix.add(w[i]);
      i++;
    }
    final prefix = <String>[];
    if (rawPrefix.isNotEmpty) {
      final canon = canonicalPrefix(rawPrefix);
      if (canon != null) {
        prefix.add(canon);   //  命中唯一规范前缀
      } else {
        i = startI;          //  匹配不上:退回核心,不当前缀
      }
    }
    //  左右标记:Left=左手侧;无 Left 前缀默认 Right(右手)。
    //  "left"常被识别成"lead"(音近);Lead Right/Lead Left
    //  本身是独立口令——按人类判别法:lead 后面跟的不是
    //  left/right 时,把 lead 理解为 Left(如 "lead square
    //  thru"→Left Square Thru);lead 后跟 left/right 时
    //  它就是 Lead 口令本身("lead right" 核心保留)
    var left = false;
    if (i < w.length &&
        (w[i] == 'left' ||
         (w[i] == 'lead' &&
          i + 1 < w.length &&
          w[i + 1] != 'left' &&
          w[i + 1] != 'right'))) {
      left = true;
      i++;
    }
    final suffix = <String>[];
    var j = w.length;
    while (j > i && _suffixWords.contains(w[j - 1])) {
      suffix.insert(0, w[j - 1]);
      j--;
    }
    return (prefix, left, w.sublist(i, j), suffix);
  }

  ///  前缀单复数归一:head≡heads, side≡sides, boy≡boys...
  static String _normPrefix(String w) => switch (w) {
        'head' => 'heads',
        'side' => 'sides',
        'boy' => 'boys',
        'girl' => 'girls',
        'leader' => 'leaders',
        'trailer' => 'trailers',
        'center' => 'centers',
        'end' => 'ends',
        'man' => 'men',
        'woman' => 'women',
        'couple' => 'couples',
        _ => w,
      };

  ///  主语比对(公开,head≡heads 单复数等价)
  static bool samePrefix(List<String> a, List<String> b) =>
      _samePrefix(a, b);

  ///  两句话的主语结构是否一致(有无主语、是哪个主语):
  ///  "heads pass thru" 与 "pass thru" 主语不同 = 不同口令,
  ///  匹配时作硬界限(用户原则:两者识别应完全不同),
  ///  整句相似度不得越过主语差异
  static bool sameCommandPrefix(String a, String b) =>
      samePrefix(decomposeCall(a).$1, decomposeCall(b).$1);

  ///  词数比例防线:识别句核心词数不足记号核心的一半
  ///  (或反之) = 没有关联的短杂音(如 "dough"↔"touch a half",
  ///  "it"↔"promenade home"),不匹配
  static bool wordCountsPlausible(String a, String b) {
    final da = decomposeCall(a).$3;
    final db = decomposeCall(b).$3;
    if (da.isEmpty || db.isEmpty) return true;
    final r = da.length / db.length;
    return r >= 0.5 && r <= 2.0;
  }

  static bool _samePrefix(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++)
      if (_normPrefix(a[i]) != _normPrefix(b[i])) return false;
    return true;
  }

  static int i0(List<String> w) => 0;

  ///  前缀归一命中:词列必须匹配唯一规范前缀,返回规范形;
  ///  匹配不上返回 null(调用方将词退回核心)。
  ///  规范前缀:主语(heads/sides/boys/girls/centers/ends/
  ///  leaders/trailers/everyone…)、facing in/out、
  ///  分数(quarter/half/three quarter/one and half)
  static String? canonicalPrefix(List<String> words) {
    final n = [for (final w in words) _normPrefix(w)];
    final joined = n.join(' ');
    //  分数规范形
    const fractions = {
      'quarter': 'quarter', 'one quarter': 'quarter',
      'half': 'half', 'one half': 'half', 'a half': 'half',
      'three quarter': 'three quarter',
      'three quarters': 'three quarter',
      'one and half': 'one and half',
      'one and a half': 'one and half',
      'one ends half': 'one and half',   //  and听成ends归一后
    };
    if (fractions.containsKey(joined)) return fractions[joined];
    //  facing
    if (joined == 'facing out' || joined == 'facing in')
      return joined;
    //  主语:全部归一后相同且是规范主语
    if (joined == 'all four couples') return joined;
    if (joined == 'outer six') return joined;
    if (joined == 'outside couples') return joined;
    if (joined == 'line of eight') return joined;
    if (joined == 'line of six') return joined;
    if (joined == 'end ladies') return joined;
    if (joined == 'center ladies') return joined;
    const subjects = {
      'heads', 'sides', 'boys', 'girls', 'centers', 'ends',
      'leaders', 'trailers', 'everyone', 'men', 'women',
      'couples', 'all four couples',
    };
    if (n.isNotEmpty && subjects.contains(n.first)) {
      //  多个主语词时取第一个(如 ends ends 只算一个)
      var count = 0;
      for (final x in n)
        if (_normPrefix(x) == n.first) count++;
      if (count == n.length) return n.first;
    }
    return null;   //  没有命中任何规范前缀
  }

  static bool _sameWords(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++)
      if (a[i] != b[i]) return false;
    return true;
  }

  ///  结构化误差:先比对前缀/后缀/左右(应精确一致),
  ///  口令核心用编辑距离模糊比对——比整句模糊又快又准
  static double structuredError(String a, String b) {
    var wa = _normalize(a).split(' ')
        .where((s) => s.isNotEmpty).toList();
    final wb = _normalize(b).split(' ')
        .where((s) => s.isNotEmpty).toList();
    //  高频听错定向纠偏(声学高度混淆对):
    //  "single fold"常为"single circle"的误听;
    //  "lead"常为"left"的误听(在非Lead口令位置)
    wa = [for (var i = 0; i < wa.length; i++)
      i >= 1 && wa[i] == 'fold' && wa[i - 1] == 'single' &&
              !wa.contains('circle')
          ? 'circle'
          : wa[i]];
    var (pa, la, ca, sa) = _decompose(wa);
    final (pb, lb, cb, sb) = _decompose(wb);
    var err = sentenceError(ca.join(' '), cb.join(' '));
    //  lead≈left 加强:听到 lead 开头而比对行不是 Lead 口令
    //  (核心不含 lead)时,再按 left 试算一次取低者
    if (!la && ca.isNotEmpty && ca.first == 'lead' &&
        !cb.contains('lead')) {
      final altErr = sentenceError(
          'left ${ca.sublist(1).join(' ')}'.trim(),
          cb.join(' '));
      if (altErr < err) {
        err = altErr;
        la = true;
        ca = ca.sublist(1);
      }
    }
    if (la != lb) err += 0.10;   //  左右不一致(无Left=Right)
    if (!_sameWords(sa, sb)) {
      err += 0.10;   //  后缀不一致
      //  "Sweep a Quarter"与"Three Quarters"声学相近,人也
      //  常混淆。识别层常把 Sweep 听成 Three(词频更高)——
      //  比对层双向纠偏:一侧 sweep 一侧 three quarter 时,
      //  按 sweep quarter 重算误差取低者,让 Sweep 行能
      //  吃到被听成 three quarter 的发音;同时非 Sweep 行
      //  不会被 Sweep 行误吃(惩罚保留)
      final aSweep = sa.contains('sweep');
      final bSweep = sb.contains('sweep');
      final aThree = sa.join(' ') == 'three quarter';
      final bThree = sb.join(' ') == 'three quarter';
      if (aSweep && bThree || aThree && bSweep) {
        final alt = sentenceError(ca.join(' '), cb.join(' '));
        if (alt < err) err = alt;   //  纠偏重算取低
      } else if (aSweep != bSweep && (aThree || bThree)) {
        err += 0.15;   //  互串加重惩罚(非sweep/3-4互串对)
      }
    }
    if (pb.isNotEmpty && !_samePrefix(pa, pb))
      err += 0.05;    //  主语不一致(head≡heads)
    return err > 1 ? 1 : err;
  }

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
    //  分解诊断:前缀(主语)→口令核心→后缀,三级流水
    final d = decomposeCall(sentence);
    debugPrint('decompose "$sentence": '
        'prefix=[${d.$1.join(' ')}] left=${d.$2} '
        'core=[${d.$3.join(' ')}] suffix=[${d.$4.join(' ')}]');
    CallerRow? best;
    var bestErr = double.infinity;
    for (final row in rows) {
      //  行内可存多笔记号(以 | 分隔):同一口令的多种听法
      //  都留在行里,与任意一笔比对,取最小误差
      var err = double.infinity;
      for (final token in row.recognized.split('|')) {
        //  结构化(前缀/口令/后缀分解)与整句模糊取小:
        //  前缀后缀精确一致时结构化误差显著更低
        final e1 = structuredError(token, sentence);
        final e2 = sentenceError(token, sentence);
        var e = e1 < e2 ? e1 : e2;
        //  主语硬界限:主语不同(有无/不同主语)=不同口令,
        //  整句相似不得越过(heads pass thru ≠ pass thru)
        if (!sameCommandPrefix(token, sentence)) e = 1.0;
        //  词数比例防线:核心词数差一倍以上=无关短杂音
        if (!wordCountsPlausible(token, sentence)) e = 1.0;
        if (e < err) err = e;
      }
      //  全表扫描取全局最小(不早停):噪声记号下误差沿
      //  排序并非单谷形,早停会漏掉真正的最低误差行。
      //  平手裁决:记号误差相同(如裸记号被误录到带主语的行),
      //  取标准口令结构与识别句更一致的行——喊 "pass thru"
      //  时选「Pass Thru」而不是「Heads Pass Thru」
      final stdErr =
          structuredError(spokenForm(row.standardCall), sentence);
      if (err < bestErr - 1e-9 ||
          (err < bestErr + 1e-9 && best != null &&
              stdErr < structuredError(
                  spokenForm(best!.standardCall), sentence))) {
        bestErr = err;
        best = row;
      }
    }
    return (hit: best, candidate: best, error: bestErr);
  }

  ///  记号碰撞体检:口令不同而记号相同/雷同的行对——
  ///  喊口令时查表无法区分,需重新识别。
  ///  返回(行A序号,行A口令,行B序号,行B口令,雷同记号)
  List<(int, String, int, String, String)> findTokenCollisions() {
    final result =
        <(int, String, int, String, String)>[];
    for (var i = 0; i < rows.length; i++) {
      for (var j = i + 1; j < rows.length; j++) {
        final a = rows[i], b = rows[j];
        if (a.standardCall.trim().toLowerCase() ==
            b.standardCall.trim().toLowerCase()) continue;
        outer:
        for (final ta in a.recognized.split('|')) {
          final t1 = ta.trim();
          if (t1.isEmpty) continue;
          for (final tb in b.recognized.split('|')) {
            final t2 = tb.trim();
            if (t2.isEmpty) continue;
            if (sentenceError(t1, t2) < 0.12) {
              result.add(
                  (a.seq, a.standardCall, b.seq, b.standardCall, t1));
              break outer;
            }
          }
        }
      }
    }
    return result;
  }

  ///  分段取样检索(用户定义的取样过程,段界查表专用):
  ///  与每行的**记号**和**标准口令读法**双轨比对——采表时
  ///  记号可能尚未录上,标准口令读法保证新表也能检索。
  ///  返回最佳行与最小误差,门槛由调用方判定(先设0.5)
  ({CallerRow? hit, double error}) lookupForSample(String sentence) {
    if (rows.isEmpty) return (hit: null, error: 1.0);
    CallerRow? best;
    var bestErr = double.infinity;
    for (final row in rows) {
      //  双轨目标:已录记号(多笔以|分隔) + 标准口令读法
      final targets = row.recognized
          .split('|')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      final spoken = spokenForm(row.standardCall);
      if (!targets.contains(spoken)) targets.add(spoken);
      var err = double.infinity;
      for (final token in targets) {
        final e1 = structuredError(token, sentence);
        final e2 = sentenceError(token, sentence);
        var e = e1 < e2 ? e1 : e2;
        //  主语硬界限(同 lookupSequential)
        if (!sameCommandPrefix(token, sentence)) e = 1.0;
        //  词数比例防线(同 lookupSequential)
        if (!wordCountsPlausible(token, sentence)) e = 1.0;
        if (e < err) err = e;
      }
      //  平手裁决:记号误差相同时,取标准口令结构与识别句
      //  更一致的行(同 lookupSequential)
      final stdErr =
          structuredError(spokenForm(row.standardCall), sentence);
      if (err < bestErr - 1e-9 ||
          (err < bestErr + 1e-9 && best != null &&
              stdErr < structuredError(
                  spokenForm(best!.standardCall), sentence))) {
        bestErr = err;
        best = row;
      }
    }
    return (hit: best, error: bestErr);
  }

}
