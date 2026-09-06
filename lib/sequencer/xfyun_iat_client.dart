/*

  Taminations Square Dance Animations
  Copyright (C) 2026 Brad Christie

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  科大讯飞「语音听写(流式版)」WebAPI 客户端。
  协议文档: https://www.xfyun.cn/doc/asr/voicedictation/API.html

  一个实例对应一次识别会话(单次会话音频上限 60 秒),不可复用。

*/

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

///  一轮识别的结果。isFinal 为 true 时 bestText/alternates 为完整结果。
class XfyunIatResult {

  final String bestText;

  ///  词级候选拼出的整句候选,最多 wbest 个,bestText 永远是第一个。
  final List<String> alternates;

  final bool isFinal;

  XfyunIatResult(this.bestText, this.alternates, this.isFinal);

}

class XfyunIatClient {

  XfyunIatClient({
    required this.appId,
    required this.apiKey,
    required this.apiSecret,
    required this.onResult,
    required this.onError,
    this.language = 'en_us',
    this.endSilenceMs = 5000,
    this.debugLogging = false,
  });

  final String appId;
  final String apiKey;
  final String apiSecret;
  final String language;

  ///  后端点静默时长(毫秒),对应 speech_to_text 的 pauseFor。
  final int endSilenceMs;
  final bool debugLogging;
  final void Function(XfyunIatResult result) onResult;
  final void Function(int code, String message) onError;

  static const String _host = 'iat-api.xfyun.cn';
  static const String _path = '/v2/iat';
  static const int _frameBytes = 1280; //  16k 采样 16bit 单声道 40 毫秒
  static const int _sampleRate = 16000;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final List<int> _pending = [];
  final List<String> _bestParts = [];
  final List<String> _altParts = [];
  bool _headerSent = false;
  bool _finishSent = false;
  bool _closed = false;

  bool get isClosed => _closed;

  void _log(String message) => debugPrint('STT-iat $message');

  ///  建立 WebSocket 连接。失败时抛出异常。
  Future<void> connect() async {
    final date = _rfc1123(DateTime.now().toUtc());
    _log('connect: wss://$_host$_path date=$date app_id=${appId.length}chars');
    final channel = WebSocketChannel.connect(Uri.parse(_authUrl()));
    _channel = channel;
    await channel.ready;
    _subscription = channel.stream.listen(
        (data) => _onMessage(data),
        onError: (Object error) => _fail(-1, 'connection error: $error'),
        onDone: _onDone,
    );
    _log('connect: websocket ready');
  }

  ///  送入一段 16k 16bit 单声道 PCM 音频,内部按 1280 字节分帧发送。
  void sendAudio(Uint8List chunk) {
    if (_closed || _finishSent) return;
    _log('audio: ${chunk.length} bytes in');
    _pending.addAll(chunk);
    while (_pending.length >= _frameBytes) {
      final frame = _pending.sublist(0, _frameBytes);
      _pending.removeRange(0, _frameBytes);
      _send(frame, _headerSent ? 1 : 0);
    }
  }

  ///  音频结束:发送尾帧(status=2),之后等待服务端返回最终结果。
  void finishAudio() {
    _log('finishAudio: pending=${_pending.length}B '
        'headerSent=$_headerSent finishSent=$_finishSent closed=$_closed');
    if (_closed || _finishSent) return;
    if (!_headerSent) {
      //  整个会话还没发过任何帧:剩余音频作为首帧(status=0)发出
      final rest = _pending.toList();
      _pending.clear();
      _send(rest, 0);
    } else if (_pending.isNotEmpty) {
      final rest = _pending.toList();
      _pending.clear();
      _send(rest, 1);
    }
    _send(const <int>[], 2);
    _finishSent = true;
    _log('finishAudio: last frame sent, waiting for final result');
  }

  ///  立即废弃会话,之后的回调全部忽略。
  void abort() {
    _log('abort: closed=$_closed bestParts=${_bestParts.length}');
    _closed = true;
    _subscription?.cancel();
    _channel?.sink.close();
  }

  void _send(List<int> audio, int status) {
    //  data.status: 0 首帧(须带 common+business) / 1 中间帧 / 2 尾帧
    final message = <String, dynamic>{
      if (!_headerSent)
        'common': {'app_id': appId},
      if (!_headerSent)
        'business': {
          'language': language,
          'domain': 'iat',
          'accent': 'mandarin',
          'ptt': 0,      //  不加标点
          'nunum': 0,    //  数字用单词而不是阿拉伯数字
          'ltc': 3,      //  只输出英文(本应用只输入英文口令)
          'wbest': 3,    //  词级多候选,用于拼 alternates
          'eos': endSilenceMs,  //  静音自动断句(服务端 VAD)
        },
      'data': {
        'status': status,
        'format': 'audio/L16;rate=$_sampleRate',
        'encoding': 'raw',
        'audio': base64Encode(audio),
      },
    };
    if (!_headerSent) _headerSent = true;
    final json = jsonEncode(message);
    _log('send: frame status=$status audio=${audio.length}B '
        'header=${status == 0}');
    if (debugLogging) debugPrint('STT-iat send raw: $json');
    _channel?.sink.add(json);
  }

  String _authUrl() {
    final date = _rfc1123(DateTime.now().toUtc());
    final signatureOrigin = 'host: $_host\ndate: $date\nGET $_path HTTP/1.1';
    final signature = base64Encode(Hmac(sha256, utf8.encode(apiSecret))
        .convert(utf8.encode(signatureOrigin)).bytes);
    final authorizationOrigin = 'api_key="$apiKey", algorithm="hmac-sha256", '
        'headers="host date request-line", signature="$signature"';
    final authorization = base64Encode(utf8.encode(authorizationOrigin));
    return 'wss://$_host$_path'
        '?authorization=${Uri.encodeComponent(authorization)}'
        '&date=${Uri.encodeComponent(date)}'
        '&host=$_host';
  }

  //  dart:io 的 HttpDate 不跨平台,这里手写 RFC1123 格式
  String _rfc1123(DateTime utc) {
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    const months = ['Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec'];
    String two(int value) => value.toString().padLeft(2, '0');
    return '${days[utc.weekday - 1]}, ${two(utc.day)} '
        '${months[utc.month - 1]} ${utc.year} '
        '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} GMT';
  }

  void _onMessage(dynamic raw) {
    if (_closed) return;
    if (debugLogging) debugPrint('STT-iat recv raw: $raw');
    final Map<String, dynamic> message;
    try {
      message = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      _log('recv: not json, ignored');
      return;
    }
    final code = (message['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      _log('recv: ERROR code=$code message=${message['message']} '
          'sid=${message['sid']}');
      _fail(code, (message['message'] ?? 'unknown error').toString());
      return;
    }
    final data = message['data'];
    if (data is! Map<String, dynamic>) {
      _log('recv: no data field, sid=${message['sid']}');
      return;
    }
    final result = data['result'];
    if (result is Map<String, dynamic>) {
      _mergeResult(result);
    }
    //  data.status: 2 表示识别结束
    final isFinal = (data['status'] as num?)?.toInt() == 2;
    _log('recv: ok data.status=${data['status']} '
        'hasResult=${result != null} best="${_bestParts.join().trim()}"');
    if (isFinal) {
      _closed = true;
      onResult(_buildResult(true));
      _closeSocket();
    } else {
      onResult(_buildResult(false));
    }
  }

  //  每条消息的 ws 是该片段的词,完整文本按到达顺序拼接
  void _mergeResult(Map<String, dynamic> result) {
    final words = result['ws'];
    if (words is! List) return;
    final best = StringBuffer();
    final alternate = StringBuffer();
    for (final word in words) {
      if (word is! Map<String, dynamic>) continue;
      final candidates = word['cw'];
      if (candidates is! List || candidates.isEmpty) continue;
      best.write(_w(candidates[0]));
      //  wbest>1 时第二个候选用于拼整句备选
      alternate.write(_w(candidates.length > 1 ? candidates[1] : candidates[0]));
    }
    if (best.isNotEmpty) {
      _bestParts.add(best.toString());
      _altParts.add(alternate.toString());
    }
  }

  String _w(dynamic candidate) =>
      candidate is Map<String, dynamic> ? (candidate['w'] ?? '').toString() : '';

  XfyunIatResult _buildResult(bool isFinal) {
    final best = _bestParts.join().trim();
    final alternate = _altParts.join().trim();
    final alternates = <String>[
      if (best.isNotEmpty) best,
      if (alternate.isNotEmpty && alternate != best) alternate,
    ];
    return XfyunIatResult(best, alternates, isFinal);
  }

  void _fail(int code, String message) {
    if (_closed) return;
    _log('fail: code=$code message=$message');
    _closed = true;
    onError(code, message);
    _closeSocket();
  }

  //  服务端主动断开(超过 10 秒未发数据 / 会话超时等)
  void _onDone() {
    if (_closed) return;
    _log('onDone: server closed connection, '
        'bestParts=${_bestParts.length} finishSent=$_finishSent');
    _closed = true;
    if (_bestParts.isNotEmpty) {
      onResult(_buildResult(true));
    } else {
      onError(-1, 'connection closed by server');
    }
  }

  void _closeSocket() {
    _log('closeSocket');
    _subscription?.cancel();
    _channel?.sink.close();
  }

}
