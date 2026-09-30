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

import '../common_flutter.dart';
import 'voice_flow.dart';

///  音乐节拍按钮(单行紧凑,置于播放控制条上方一行,左端):
///  - 平时:"按下"(大)+"测音乐节拍"(小),白底
///  - 取样/检测中:"请播放音乐"/"节拍检测中"+"再击退出"(小),
///    蓝底深浅交替闪烁(实心,不透明)
///  - 节拍生效中:"音乐停止或"(小)+"按下退出"(大),蓝底
class MusicDanceButton extends fm.StatefulWidget {
  @override
  _MusicDanceButtonState createState() => _MusicDanceButtonState();
}

class _MusicDanceButtonState extends fm.State<MusicDanceButton>
    with fm.SingleTickerProviderStateMixin {

  final flow = VoiceFlow.instance;
  fm.AnimationController? _blink;

  bool get _detecting =>
      flow.phase == 'awaiting' || flow.phase == 'detecting';

  @override
  void initState() {
    super.initState();
    _blink = fm.AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));
    flow.addListener(_onChanged);
  }

  @override
  void dispose() {
    flow.removeListener(_onChanged);
    _blink?.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    //  检测中以颜色深浅交替闪烁(保持实心);其余状态常亮
    if (_detecting) {
      if (!(_blink!.isAnimating)) _blink!.repeat(reverse: true);
    } else {
      _blink!.stop();
      _blink!.value = 1;
    }
    setState(() {});
  }

  @override
  fm.Widget build(fm.BuildContext context) {
    final detecting = _detecting;
    final dancing = flow.musicDancing;
    //  单行文字(小字+大字混排),与本行右侧 bpm 显示同高
    final fm.Widget content;
    if (dancing) {
      content = fm.Text.rich(fm.TextSpan(children: [
        fm.TextSpan(
            text: '音乐停止或',
            style: fm.TextStyle(fontSize: 11, color: Color.WHITE)),
        fm.TextSpan(
            text: '按下退出',
            style: fm.TextStyle(
                fontSize: 15,
                fontWeight: fm.FontWeight.bold,
                color: Color.WHITE)),
      ]));
    } else if (detecting) {
      content = fm.Text.rich(fm.TextSpan(children: [
        fm.TextSpan(
            text: flow.phase == 'awaiting' ? '请播放音乐' : '节拍检测中',
            style: fm.TextStyle(
                fontSize: 14,
                fontWeight: fm.FontWeight.bold,
                color: Color.WHITE)),
        fm.TextSpan(
            text: '再击退出',
            style: fm.TextStyle(fontSize: 11, color: Color.WHITE)),
      ]));
    } else {
      content = fm.Text.rich(fm.TextSpan(children: [
        fm.TextSpan(
            text: '按下',
            style: fm.TextStyle(
                fontSize: 16,
                fontWeight: fm.FontWeight.bold,
                color: Color.BLACK)),
        fm.TextSpan(
            text: '测音乐节拍',
            style: fm.TextStyle(fontSize: 11, color: Color.BLACK)),
      ]));
    }
    return fm.AnimatedBuilder(
        animation: _blink!,
        builder: (context, _) {
          //  检测中:蓝底以深浅交替闪烁(始终实心不透明)
          final fm.Decoration decoration;
          if (detecting) {
            final bright = _blink!.value > 0.5;
            decoration = fm.ShapeDecoration(
                shape: fm.RoundedRectangleBorder(
                    side: fm.BorderSide(color: Color.BLUE),
                    borderRadius: fm.BorderRadius.circular(8)),
                color: bright
                    ? fm.Colors.blue
                    : const fm.Color(0xff0d47a1));
          } else if (dancing) {
            decoration = fm.ShapeDecoration(
                shape: fm.RoundedRectangleBorder(
                    side: fm.BorderSide(color: Color.BLUE),
                    borderRadius: fm.BorderRadius.circular(8)),
                gradient: fm.LinearGradient(
                    begin: fm.Alignment.topCenter,
                    end: fm.Alignment.bottomCenter,
                    colors: [fm.Colors.blue, fm.Colors.blue.shade800]));
          } else {
            decoration = fm.ShapeDecoration(
                shape: fm.RoundedRectangleBorder(
                    side: fm.BorderSide(color: Color.GRAY.darker()),
                    borderRadius: fm.BorderRadius.circular(8)),
                gradient: fm.LinearGradient(
                    begin: fm.Alignment.topCenter,
                    end: fm.Alignment.bottomCenter,
                    colors: [Color.WHITE, const fm.Color(0xffc0c0c0)]));
          }
          return fm.Material(
            elevation: 3.0,
            color: Color(0),
            shape: fm.RoundedRectangleBorder(
                borderRadius: fm.BorderRadius.circular(8)),
            child: fm.InkWell(
              onTap: () => flow.toggleMusic(),
              child: fm.Container(
                padding: fm.EdgeInsets.fromLTRB(8, 1, 8, 1),
                decoration: decoration,
                child: content,
              ),
            ),
          );
        });
  }

}
