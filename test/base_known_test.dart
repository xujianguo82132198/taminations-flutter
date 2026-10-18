import 'package:flutter_test/flutter_test.dart';
import 'package:taminations/call_index.dart';
import 'package:taminations/sequencer/caller_store.dart';
import 'package:taminations/sequencer/sequencer_model.dart';
import 'package:taminations/sequencer/sequencer_calls_page.dart'
    show baseNotCall;
import 'package:taminations/settings.dart';

void main() {
  testWidgets('scan base known via model', (tester) async {
    await tester.runAsync(() async {
      Settings.mockInit();
      final model = SequencerModel();
      model.setStartingFormation('Static Square');
      final notFound = <String>[];
      var real = 0;
      for (final entry in callIndex) {
        final base = CallerTable.cleanCallTitle(entry.title);
        if (base.isEmpty) continue;
        model.reset();
        try {
          model.loadOneCall(base);
          if (model.errorString.contains('not found')) {
            notFound.add(entry.title);
          } else {
            real++;
          }
        } catch (_) {
          real++;   //  崩溃=解析器已认识该名(如 But 需上文)
        }
      }
      //  停掉最后一口令启动的节拍动画,否则
      //  testWidgets 报"animation still running"
      model.animation.doPause();
      print('REAL=$real NOTFOUND=${notFound.length}');
      //  自动比对:扫描结果必须与源码嵌入的黑名单一致
      //  (升级上游口令定义后重跑本测试,名单变了就同步)
      final embedded = baseNotCall.toSet();
      final scanned = notFound.toSet();
      final missing = scanned.difference(embedded);
      final extra = embedded.difference(scanned);
      print('名单比对: 漏嵌=${missing.length} 多嵌=${extra.length}');
      if (missing.isNotEmpty) {
        print('需补入 baseNotCall: ${missing.join(' | ')}');
      }
      if (extra.isNotEmpty) {
        print('需从 baseNotCall 删除: ${extra.join(' | ')}');
      }
      expect(missing.isEmpty && extra.isEmpty, isTrue,
          reason: '扫描名单与嵌入名单不一致,见上方输出');
    });
  });
}
