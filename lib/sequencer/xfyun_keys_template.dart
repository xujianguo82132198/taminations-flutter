/*

  xfyun_keys.dart 的模板。

  使用方法:
  1. cp lib/sequencer/xfyun_keys_template.dart lib/sequencer/xfyun_keys.dart
  2. 在 https://www.xfyun.cn 控制台创建应用,开通「语音听写(流式版)」服务
     (每天 500 次免费额度)
  3. 把 AppID / APIKey / APISecret 填入下方 defaultValue

  xfyun_keys.dart 已加入 .gitignore,真实凭据不会入库;
  也可以不改文件,用 --dart-define=XF_APP_ID=... 等参数在构建时传入。

*/

class XfyunKeys {

  static const String appId =
      String.fromEnvironment('XF_APP_ID', defaultValue: 'your-app-id');

  static const String apiKey =
      String.fromEnvironment('XF_API_KEY', defaultValue: 'your-api-key');

  static const String apiSecret =
      String.fromEnvironment('XF_API_SECRET', defaultValue: 'your-api-secret');

  static bool get configured =>
      appId.isNotEmpty && apiKey.isNotEmpty && apiSecret.isNotEmpty;

}
