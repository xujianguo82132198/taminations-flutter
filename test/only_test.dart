import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taminations/sequencer/caller_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('建Only表:第3列应包含口令', () async {
    SharedPreferences.setMockInitialValues({});
    final t = await CallerTable.createOnlyTable(
        (await SharedPreferences.getInstance()), '测试_plus_Only', 'plus');
    print('rows=${t.rows.length}');
    for (var i = 0; i < t.rows.length && i < 5; i++) {
      print('row $i: seq=${t.rows[i].seq} '
          'recognized="${t.rows[i].recognized}" '
          'standardCall="${t.rows[i].standardCall}"');
    }
    expect(t.rows.length, greaterThan(0));
    expect(t.rows.first.standardCall, isNotEmpty);
  });
}
