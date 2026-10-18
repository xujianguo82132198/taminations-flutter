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
import 'dart:io' as io;

import 'package:flutter/material.dart' as fm;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel;

import '../common_flutter.dart';

///  自建手机文件浏览器(导入/导出用)。
///  缘由:系统 SAF 选择页起停"下载内容",MIUI 上又没有
///  明显的"返回上层"钮,口令员找不到自己的目录,可能把
///  文件存进他人目录(用户反馈:会引起手机出问题)。
///  本画面从存储根目录开始,全宽大字"返回上级"钮,
///  目录在前文件在后,大字分行。需"所有文件访问"权限
///  (Android 11+,侧载 APK 可授予;未授权时调用方退回
///  系统选择页)。
class PhoneFileBrowser {
  static const _channel = MethodChannel('taminations/music');

  ///  是否已具备直读存储的权限(非安卓平台返回 false)
  static Future<bool> storageCheck() async {
    try {
      return await _channel.invokeMethod<bool>('storageCheck') ?? false;
    } catch (_) {
      return false;
    }
  }

  ///  跳系统"所有文件访问"授权页
  static Future<void> storageAsk() async {
    try {
      await _channel.invokeMethod<void>('storageAsk');
    } catch (_) {}
  }

  ///  存储根目录(所有口令员目录都挂在它下面)
  static const String root = '/storage/emulated/0';

  ///  选一个 .ysb 文件:返回其绝对路径;取消返回 null
  static Future<String?> pickYsb(fm.BuildContext context) async {
    debugPrint('DIAG pickYsb: push 浏览画面');
    final r = await fm.Navigator.of(context).push<String>(
        fm.MaterialPageRoute(
            builder: (_) => const _BrowserPage(mode: 'pick')));
    debugPrint('DIAG pickYsb: 返回=$r');
    return r;
  }

  ///  选保存位置:返回(目录, 文件名);取消返回 null
  static Future<(String, String)?> saveYsb(fm.BuildContext context,
      String defaultFileName) async {
    return await fm.Navigator.of(context).push<(String, String)>(
        fm.MaterialPageRoute(builder: (_) =>
            _BrowserPage(mode: 'save', defaultFileName: defaultFileName)));
  }
}

///  条目名:目录的 uri 带尾斜杠,pathSegments.last 会取到
///  空串(用户实测:所有目录无名字),故统一按路径取最后一段
String _baseName(io.FileSystemEntity e) {
  var p = e.path;
  while (p.endsWith('/') && p.length > 1) {
    p = p.substring(0, p.length - 1);
  }
  return p.split('/').last;
}

class _BrowserPage extends fm.StatefulWidget {
  final String mode;   //  'pick'=选文件  'save'=选保存位置
  final String defaultFileName;
  const _BrowserPage({required this.mode, this.defaultFileName = ''});

  @override
  fm.State createState() => _BrowserPageState();
}

class _BrowserPageState extends fm.State<_BrowserPage> {
  var dir = PhoneFileBrowser.root;
  var dirs = <io.Directory>[];
  var files = <io.File>[];
  var error = '';
  final nameCtl = fm.TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.mode == 'save')
      nameCtl.text = widget.defaultFileName;
    _load();
  }

  void _load() {
    try {
      final list = io.Directory(dir).listSync(followLinks: false);
      //  隐藏:点开头的隐藏项。
      //  系统目录(如 Android)不隐藏——有名字,口令员
      //  自己知道哪个不能进(用户规则)
      list.removeWhere((e) => _baseName(e).startsWith('.'));
      //  只在选文件模式列出 .ysb;保存模式列目录即可
      final d = <io.Directory>[];
      final f = <io.File>[];
      for (final e in list) {
        if (e is io.Directory)
          d.add(e);
        else if (e is io.File &&
            (widget.mode != 'pick' ||
                e.path.toLowerCase().endsWith('.ysb')))
          f.add(e);
      }
      int cmp(a, b) => _baseName(a).toLowerCase()
          .compareTo(_baseName(b).toLowerCase());
      d.sort(cmp);
      f.sort(cmp);
      setState(() {
        dirs = d;
        files = f;
        error = '';
      });
    } catch (e) {
      setState(() { error = '读取目录失败:$e'; });
    }
  }

  void _up() {
    if (dir == PhoneFileBrowser.root) return;
    dir = dir.substring(0, dir.lastIndexOf('/'));
    if (dir.isEmpty) dir = PhoneFileBrowser.root;
    _load();
  }

  ///  根目录显示"/",子目录显示相对路径(去掉长前缀)
  String get shownPath => dir == PhoneFileBrowser.root
      ? '/ (存储根目录)'
      : dir.replaceFirst(PhoneFileBrowser.root, '');

  @override
  fm.Widget build(fm.BuildContext context) {
    return fm.Scaffold(
      appBar: fm.AppBar(
          title: fm.Text(widget.mode == 'pick' ? '选口令表文件' : '选保存位置',
              style: fm.TextStyle(fontSize: 22))),
      body: fm.Column(children: [
        //  当前位置(蓝底白字,一眼可见)
        fm.Container(
            width: double.infinity,
            color: Color.BLUE,
            padding: fm.EdgeInsets.symmetric(
                horizontal: 12, vertical: 8),
            child: fm.Text(shownPath.isEmpty ? '/' : shownPath,
                style: fm.TextStyle(fontSize: 18, color: Color.WHITE))),
        //  全宽大字"返回上级"钮(根目录时灰)
        fm.SizedBox(
            width: double.infinity,
            child: fm.ElevatedButton(
                style: fm.ElevatedButton.styleFrom(
                    padding: fm.EdgeInsets.symmetric(vertical: 14)),
                onPressed: dir == PhoneFileBrowser.root ? null : _up,
                child: fm.Row(
                    mainAxisAlignment: fm.MainAxisAlignment.center,
                    children: [
                      fm.Icon(fm.Icons.arrow_upward),
                      fm.Text(' 返回上级',
                          style: fm.TextStyle(fontSize: 22)),
                    ]))),
        //  在当前位置新建目录(仅保存模式:导出时整理存放处;
        //  选文件模式不需要——用户先后明确)
        if (widget.mode == 'save')
          fm.Padding(
              padding: fm.EdgeInsets.only(left: 8, right: 8),
              child: fm.SizedBox(
                  width: double.infinity,
                  child: fm.OutlinedButton(
                      style: fm.OutlinedButton.styleFrom(
                          padding: fm.EdgeInsets.symmetric(vertical: 8)),
                      onPressed: _mkdir,
                      child: fm.Row(
                          mainAxisAlignment: fm.MainAxisAlignment.center,
                          children: [
                            fm.Icon(fm.Icons.create_new_folder),
                            fm.Text(' 在此新建目录',
                                style: fm.TextStyle(fontSize: 18)),
                          ])))),
        fm.Expanded(
            child: error.isNotEmpty
                ? fm.Center(
                    child: fm.Text(error,
                        style: fm.TextStyle(fontSize: 18)))
                : fm.ListView(
                    children: [
                      for (final d in dirs)
                        fm.ListTile(
                            leading: fm.Icon(fm.Icons.folder,
                                color: Color.ORANGE, size: 30),
                            title: fm.Text(_baseName(d),
                                style: fm.TextStyle(fontSize: 22)),
                            onTap: () {
                              dir = d.path;
                              _load();
                            }),
                      for (final f in files)
                        fm.ListTile(
                            leading: fm.Icon(fm.Icons.description,
                                size: 30),
                            title: fm.Text(_baseName(f),
                                style: fm.TextStyle(fontSize: 22)),
                            onTap: () =>
                                fm.Navigator.of(context).pop(f.path)),
                    ])),
        //  保存模式:文件名 + 存入此目录
        if (widget.mode == 'save')
          fm.SafeArea(
              child: fm.Container(
                  color: Color.LIGHTGRAY,
                  padding: fm.EdgeInsets.all(8),
                  child: fm.Row(children: [
                    fm.Expanded(
                        child: fm.TextField(
                            controller: nameCtl,
                            style: fm.TextStyle(fontSize: 20),
                            //  回车=存入(同输入行回车即执行的惯例)
                            onSubmitted: (_) => _save(),
                            decoration: fm.InputDecoration(
                                filled: true,
                                fillColor: Color.WHITE,
                                isDense: true))),
                    fm.SizedBox(width: 8),
                    fm.ElevatedButton(
                        style: fm.ElevatedButton.styleFrom(
                            padding: fm.EdgeInsets.symmetric(
                                vertical: 14)),
                        onPressed: _save,
                        child: fm.Text('存入此目录',
                            style: fm.TextStyle(fontSize: 20))),
                  ]))),
      ]),
    );
  }


  ///  浏览器内的简短提示(居中,点确定消失)
  Future<void> _notice(String msg) async {
    await fm.showDialog<void>(
        context: context,
        builder: (ctx) => fm.AlertDialog(
            content: fm.Text(msg, style: fm.TextStyle(fontSize: 20)),
            actions: [
              fm.TextButton(
                  onPressed: () => fm.Navigator.of(ctx).pop(),
                  child: fm.Text('确定',
                      style: fm.TextStyle(fontSize: 20)))
            ]));
  }

  ///  在当前目录下新建子目录(保存模式用):问名→建→刷新
  Future<void> _mkdir() async {
    final ctl = fm.TextEditingController();
    final name = await fm.showDialog<String>(
        context: context,
        builder: (ctx) => fm.AlertDialog(
            title: fm.Text('新建目录',
                style: fm.TextStyle(fontSize: 22)),
            content: fm.Column(
                mainAxisSize: fm.MainAxisSize.min,
                children: [
                  fm.Text('位置:${shownPath.isEmpty ? '/' : shownPath}',
                      style: fm.TextStyle(fontSize: 18)),
                  fm.SizedBox(height: 8),
                  fm.TextField(
                      controller: ctl,
                      autofocus: true,
                      style: fm.TextStyle(fontSize: 22),
                      //  回车=创建(用户习惯:输入行回车即执行)
                      onSubmitted: (v) =>
                          fm.Navigator.of(ctx).pop(v.trim()),
                      decoration: fm.InputDecoration(
                          labelText: '新目录名',
                          labelStyle: fm.TextStyle(fontSize: 18))),
                ]),
            actions: [
              fm.TextButton(
                  onPressed: () => fm.Navigator.of(ctx).pop(null),
                  child: fm.Text('取消',
                      style: fm.TextStyle(fontSize: 20))),
              fm.TextButton(
                  onPressed: () =>
                      fm.Navigator.of(ctx).pop(ctl.text.trim()),
                  child: fm.Text('创建',
                      style: fm.TextStyle(fontSize: 20))),
            ]));
    if (name == null || name.isEmpty) return;
    if (name.contains('/')) {
      await _notice('目录名不能含 /');
      return;
    }
    try {
      final d = io.Directory('$dir/$name');
      if (await d.exists()) {
        await _notice('「$name」已存在');
        return;
      }
      await d.create();
      //  建成即进入(用户流程:回车建成→点它进入;
      //  中文目录名排在列表末尾,不进入根本看不见)
      dir = d.path;
      _load();
    } catch (e) {
      await _notice('创建失败:$e');
    }
  }

  Future<void> _save() async {
    final fname = nameCtl.text.trim();
    if (fname.isEmpty) {
      await _notice('请先写文件名');
      return;
    }
    final target = io.File('$dir/$fname');
    if (await target.exists()) {
      final ok = await fm.showDialog<bool>(
          context: context,
          builder: (ctx) => fm.AlertDialog(
              content: fm.Text('「$fname」已存在,覆盖它吗?',
                  style: fm.TextStyle(fontSize: 20)),
              actions: [
                fm.TextButton(
                    onPressed: () => fm.Navigator.of(ctx).pop(false),
                    child: fm.Text('取消',
                        style: fm.TextStyle(fontSize: 20))),
                fm.TextButton(
                    onPressed: () => fm.Navigator.of(ctx).pop(true),
                    child: fm.Text('覆盖',
                        style: fm.TextStyle(fontSize: 20))),
              ]));
      if (ok != true) return;
    }
    fm.Navigator.of(context).pop((dir, fname));
  }
}
