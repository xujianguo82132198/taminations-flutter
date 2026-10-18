import 'package:flutter_test/flutter_test.dart';
import 'package:taminations/sequencer/caller_store.dart';

void main() {
  test('boys power/gate sanity', () {
    //  各种听法 vs 记号'boys'的Power得分(门槛0.60)
    final heard = ['boys', 'the boys', 'boy', 'buys', 'bois',
                   'voice', 'noise'];
    for (final h in heard) {
      final pw = CallerTable.powerScoreSentence(h, 'boys');
      print('heard="$h" vs token="boys" -> '
          'power=${pw.toStringAsFixed(2)} '
          '${pw >= CallerTable.powerGate ? "过闸" : "拒"}');
    }
    //  4字母词的行权重复核(文档值)
    final row = CallerTable.power[4];
    print('Power[4]=${row.map((v) => v.toStringAsFixed(5)).join(" ")}');
  });
}
