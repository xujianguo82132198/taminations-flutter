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

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taminations/sequencer/caller_store.dart';

void main() {

  TestWidgetsFlutterBinding.ensureInitialized();

  test('新口令员新建空表,同名再打开为已有表', () async {
    SharedPreferences.setMockInitialValues({});
    final t1 = await CallerTable.open('张三');
    expect(t1.wasCreated, true);
    expect(t1.rows, isEmpty);

    final t2 = await CallerTable.open('张三');
    expect(t2.wasCreated, false);
    expect(t2.rows, isEmpty);

    //  另一个姓名是另一张独立的表
    final other = await CallerTable.open('李四');
    expect(other.wasCreated, true);
  });

  test('追加行:序号自动递增,四列内容正确', () async {
    SharedPreferences.setMockInitialValues({});
    final t = await CallerTable.open('张三');
    await t.addRow(recognized: 'swing thrue', standardCall: 'Swing Thru');
    await t.addRow(recognized: 'zoom', standardCall: 'Zoom');
    await t.addRow(recognized: 'peel off', standardCall: 'Peel Off');
    expect(t.rows.length, 3);
    //  增加后整表按字典序排序:peel off < swing thrue < zoom
    expect(t.rows.map((r) => r.recognized).toList(),
        ['peel off', 'swing thrue', 'zoom']);
    expect(t.rows.map((r) => r.seq).toList(), [1, 2, 3]);
    expect(t.rows[1].recognized, 'swing thrue');
    expect(t.rows[1].standardCall, 'Swing Thru');
    expect(t.lastSeq, 3);
  });

  test('删除行后序号自动重排,后续追加序号接续', () async {
    SharedPreferences.setMockInitialValues({});
    final t = await CallerTable.open('张三');
    for (final c in ['a', 'b', 'c', 'd']) {
      await t.addRow(recognized: c, standardCall: c.toUpperCase());
    }
    //  删除 2 号行
    expect(await t.removeRow(2), true);
    expect(t.rows.map((r) => r.seq).toList(), [1, 2, 3]);
    expect(t.rows.map((r) => r.recognized).toList(), ['a', 'c', 'd']);
    //  删除不存在的序号
    expect(await t.removeRow(9), false);
    //  再追加,序号接续为 4
    await t.addRow(recognized: 'e', standardCall: 'E');
    expect(t.rows.map((r) => r.seq).toList(), [1, 2, 3, 4]);
    expect(t.rows.last.recognized, 'e');
  });

  test('重新打开表能恢复全部行(持久化)', () async {
    SharedPreferences.setMockInitialValues({});
    final t = await CallerTable.open('王五');
    await t.addRow(recognized: 'veer left', standardCall: 'Veer Left');
    await t.addRow(recognized: 'track too', standardCall: 'Track 2');

    final reopened = await CallerTable.open('王五');
    expect(reopened.wasCreated, false);
    expect(reopened.rows.length, 2);
    //  字典序:track too < veer left
    expect(reopened.rows[0].recognized, 'track too');
    expect(reopened.rows[1].standardCall, 'Veer Left');
    expect(reopened.rows[1].seq, 2);
  });

  test('清空表', () async {
    SharedPreferences.setMockInitialValues({});
    final t = await CallerTable.open('赵六');
    await t.addRow(recognized: 'x', standardCall: 'X');
    await t.clear();
    expect(t.rows, isEmpty);
    expect(t.lastSeq, 0);
    final reopened = await CallerTable.open('赵六');
    expect(reopened.rows, isEmpty);
  });

  test('旧版空表数据({})自动按新表处理', () async {
    SharedPreferences.setMockInitialValues({'口令员表 旧人': '{}'});
    final t = await CallerTable.open('旧人');
    expect(t.wasCreated, true);
    expect(t.rows, isEmpty);
  });

  test('误差计算:相同为0,近似小,完全不同大', () {
    expect(CallerTable.sentenceError('swing thru', 'swing thru'), 0);
    expect(CallerTable.sentenceError('Swing Thru!', 'swing  thru'), 0);  //  归一化后相同
    //  swing thru vs swing threw:编辑距离2 / 长度11 ≈ 0.18
    expect(CallerTable.sentenceError('swing thru', 'swing threw'),
        closeTo(0.18, 0.02));
    expect(CallerTable.sentenceError('zoom', 'allemande left'), greaterThan(0.4));
    expect(CallerTable.sentenceError('', 'anything'), 1.0);
    expect(CallerTable.sentenceError('', ''), 0);
  });

  test('轮询查询:近似命中取误差最小行,阈值外返回null', () async {
    SharedPreferences.setMockInitialValues({});
    final t = await CallerTable.open('测试');
    await t.addRow(recognized: 'swing thru', standardCall: 'Swing Thru');
    await t.addRow(recognized: 'zoom', standardCall: 'Zoom');
    await t.addRow(recognized: 'track too', standardCall: 'Track 2');

    //  精确命中
    var r = t.lookupSequential('zoom');
    expect(r.hit?.standardCall, 'Zoom');
    //  近似命中(全表取最低误差者)
    r = t.lookupSequential('swing threw');
    expect(r.hit?.standardCall, 'Swing Thru');
    //  近似命中(track two)
    r = t.lookupSequential('track two');
    expect(r.hit?.standardCall, 'Track 2');
    //  无门槛:误差较大时也返回最低误差记录(由口令员保证表覆盖)
    r = t.lookupSequential('completely different sentence here');
    expect(r.hit, isNotNull);
    expect(r.candidate, same(r.hit));
    //  早停:误差变大即停止寻访,取之前最低者
    //  (表序 swing thrue < track too < zoom;'zooming' 首条误差后
    //   即变大,返回谷底前的最低者——依赖字典序聚集特性)
    r = t.lookupSequential('swing threw more');
    expect(r.hit, isNotNull);
    expect(r.error, lessThan(0.6));
  });

  test('顺序查找:空表返回空', () async {
    SharedPreferences.setMockInitialValues({});
    final t = await CallerTable.open('空表测试');
    final r = t.lookupSequential('anything');
    expect(r.hit, isNull);
    expect(r.candidate, isNull);
    expect(r.error, 1.0);
  });

  test('增加记录后整表按 A,B,C 排序并重排序号', () async {
    SharedPreferences.setMockInitialValues({});
    final t = await CallerTable.open('排序');
    await t.addRow(recognized: 'zoom');
    await t.addRow(recognized: 'allemande');
    await t.addRow(recognized: 'pass thru');
    await t.addRow(recognized: 'box the gnat');
    expect(t.rows.map((r) => r.recognized).toList(),
        ['allemande', 'box the gnat', 'pass thru', 'zoom']);
    expect(t.rows.map((r) => r.seq).toList(), [1, 2, 3, 4]);
    //  重开表顺序持久化
    final reopened = await CallerTable.open('排序');
    expect(reopened.rows.map((r) => r.recognized).toList(),
        ['allemande', 'box the gnat', 'pass thru', 'zoom']);
  });

  test('记录初始化:插入新记录后可更新第三列并持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final t = await CallerTable.open('初始化');
    //  第一步:识别句写入新记录第二列(第三列为空)
    var row = await t.addRow(recognized: 'swing thrue');
    expect(row.seq, 1);
    expect(row.recognized, 'swing thrue');
    expect(row.standardCall, '');
    //  第二步:口令员执行正确后,整个口令存入第三列
    await t.updateRow(row.seq,
        standardCall: 'Swing Thru');
    expect(t.rows.first.standardCall, 'Swing Thru');
    //  未指定的列保持原值
    await t.updateRow(row.seq);
    expect(t.rows.first.standardCall, 'Swing Thru');
    //  持久化:重开表内容完整
    final reopened = await CallerTable.open('初始化');
    expect(reopened.rows.length, 1);
    expect(reopened.rows.first.recognized, 'swing thrue');
    expect(reopened.rows.first.standardCall, 'Swing Thru');
  });

  test('旧数据中的级别列被忽略(读入兼容)', () async {
    SharedPreferences.setMockInitialValues({
      '口令员表 老表': '{"rows":[{"seq":1,"recognized":"swing thru",'
          '"standardCall":"Swing Thru","level":"Mainstream"}]}'
    });
    final t = await CallerTable.open('老表');
    expect(t.rows.length, 1);
    expect(t.rows.first.standardCall, 'Swing Thru');
    //  保存后不再包含级别数据
    await t.save();
    final raw = (await SharedPreferences.getInstance())
        .getString('口令员表 老表')!;
    expect(raw.contains('level'), isFalse);
  });

}
