import 'package:flutter_test/flutter_test.dart';
import 'package:taminations/sequencer/caller_store.dart';

void main() {
  test('cleanCallTitle strips trailing from variants', () {
    expect(CallerTable.cleanCallTitle(
        'Spin Chain and Exchange the Gears from'),
        'Spin Chain and Exchange the Gears');
    expect(CallerTable.cleanCallTitle(
        'Spin Chain and Exchange the Gears from Right-Hand Waves'),
        'Spin Chain and Exchange the Gears');
    expect(CallerTable.cleanCallTitle(
        'Spin Chain and Exchange the Gears'),
        'Spin Chain and Exchange the Gears');
    expect(CallerTable.cleanCallTitle(
        'Trade (Boys Run) from Waves'),
        'Trade');
    expect(CallerTable.cleanCallTitle('Run'), 'Run');
  });
}
