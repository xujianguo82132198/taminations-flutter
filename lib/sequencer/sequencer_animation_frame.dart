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

import '../common_flutter.dart';
import '../pages/animation_page.dart';
import 'sequence_frame.dart';
import 'sequencer_model.dart';

class SequencerAnimationFrame extends fm.StatelessWidget {

  @override
  fm.Widget build(fm.BuildContext context) {
    return fm.Stack(fit: fm.StackFit.expand, children: [
      fm.Column(
        children: [
          BasicSequencerAnimation(),
          fm.Container(
              color: Color.FLOOR,
              child: fm.Row(
                  children: [
                    _SequencerHelpButton(),
                    _SequencerSettingsButton(),
                    _SequencerAbbrevButton(),
                    _SequencerCallsButton(),
                    CopyImageButton()  // from animation_page
                  ]))
        ]
      ),
      //  音乐节拍按钮:跳舞区左下角叠加

    ]);
  }

}

class PortraitSequencerAnimationFrame extends fm.StatelessWidget {

  @override
  fm.Widget build(fm.BuildContext context) {
    return fm.Stack(fit: fm.StackFit.expand, children: [
      fm.Row(
      children: [
        BasicSequencerAnimation(),
        fm.Expanded(
          flex: 1,
          child: fm.Container(
            color: Color.FLOOR,
            child: fm.LayoutBuilder(
              builder:(context,constraints) {
                return fm.Column(
                children: [
                  SequencerUndoButton(),
                  SequencerResetButton(),
                  SequencerCopyButton(),
                  SequencerPasteButton(),
                  if (constraints.maxHeight > 50)
                    ...[fm.Divider(color: Color.GRAY, height: 8),
                  _SequencerHelpButton(),
                  _SequencerSettingsButton(),
                  _SequencerAbbrevButton(),
                  _SequencerCallsButton()]
                ]
              ); }
            ),
          ),
        )
      ],
      ),
      //  音乐节拍按钮:跳舞区左下角叠加

    ]);
  }

}

class BasicSequencerAnimation extends fm.StatelessWidget {
  @override
  fm.Widget build(fm.BuildContext context) {
    return fm.Expanded(
        flex: 4,
        child: fm.Stack(
            children: [
              AnimationFrame(),
              //  上部两行:当前所跳口令(小一号 24),
              //  其下为下一条将要跳的口令(比上一行大一号 28);
              //  没有下一条口令时显示为空,不报错
              fm.Positioned(
                  top: 4, left:12, right:12,
                  child: pp.Consumer<SequencerModel>(
                      builder: (context,model,_) {
                        //  未开始跳舞时不显示任何口令(含第一条),
                        //  播放按钮按下、舞蹈开始后才显示
                        final dancing = model.currentCall >= 0 &&
                            model.currentCall < model.calls.length;
                        final current = dancing
                            ? model.calls[model.currentCall].name : '';
                        final nextIndex = model.currentCall + 1;
                        final next = (dancing &&
                                nextIndex < model.calls.length)
                            ? model.calls[nextIndex].name : '';
                        return fm.Column(crossAxisAlignment:
                            fm.CrossAxisAlignment.start, children: [
                          AutoSizeText(current, maxLines: 1,
                              style: fm.TextStyle(fontSize: 16, height: 1.0)),
                          AutoSizeText(next, maxLines: 1,
                              style: fm.TextStyle(
                                  fontSize: 20,
                                  height: 1.0,
                                  fontWeight: fm.FontWeight.bold)),
                        ]);
                      }
                  )
              )
            ]
        )
    );
  }
}


class _SequencerHelpButton extends fm.StatelessWidget {
  @override
  fm.Widget build(fm.BuildContext context) {
    final appState = pp.Provider.of<TamState>(context,listen: false);
    return fm.Expanded(
        child: fm.Center(child: Button('Help', child: fm.Text('Help', maxLines: 1, style: fm.TextStyle(fontWeight: fm.FontWeight.bold, fontSize: 18)), onPressed: () {
          appState.change(detailPage:DetailPage.HELP,helplink: 'info/sequencer');
        }))
    );
  }
}

class _SequencerSettingsButton extends fm.StatelessWidget {
  @override
  fm.Widget build(fm.BuildContext context) {
    final appState = pp.Provider.of<TamState>(context,listen: false);
    return fm.Expanded(
        child: fm.Center(child: Button('Settings', child: fm.Text('Settings', maxLines: 1, style: fm.TextStyle(fontWeight: fm.FontWeight.bold, fontSize: 18)), onPressed: () {
          appState.change(detailPage:DetailPage.SETTINGS);
        }))
    );
  }
}

class _SequencerAbbrevButton extends fm.StatelessWidget {
  @override
  fm.Widget build(fm.BuildContext context) {
    final appState = pp.Provider.of<TamState>(context,listen: false);
    return fm.Expanded(
        child: fm.Center(child: Button('Abbrev', child: fm.Text('Abbrev', maxLines: 1, style: fm.TextStyle(fontWeight: fm.FontWeight.bold, fontSize: 18)), onPressed: () {
          appState.change(detailPage:DetailPage.ABBREVIATIONS);
        }))
    );
  }
}

class _SequencerCallsButton extends fm.StatelessWidget {
  @override
  fm.Widget build(fm.BuildContext context) {
    final appState = pp.Provider.of<TamState>(context,listen: false);
    return fm.Expanded(
        child: fm.Center(child: Button('Calls', child: fm.Text('Calls', maxLines: 1, style: fm.TextStyle(fontWeight: fm.FontWeight.bold, fontSize: 18)), onPressed: () {
          appState.change(detailPage:DetailPage.CALLS);
        }))
    );
  }
}

