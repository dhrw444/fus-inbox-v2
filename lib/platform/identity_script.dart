/// 把身份画像注入页面，让站点看到的**不只是**一串 UA。
///
/// ## 为什么光设 UA 没用
///
/// WebView 的 `settings.userAgent` 只改 `navigator.userAgent` 这一个字符串。
/// 站点同时读：
///
///   - `navigator.hardwareConcurrency` —— CPU 核数，真实值来自本机
///   - `navigator.deviceMemory` —— 内存，同上
///   - `screen.width` / `height` —— 屏幕，同上
///   - `window.devicePixelRatio` —— 像素比，同上
///   - `Intl.DateTimeFormat().resolvedOptions().timeZone` —— 时区
///   - `navigator.languages` —— 语言列表
///   - `navigator.userAgentData` —— Client Hints（Chrome 90+）
///
/// 这些和 UA 对不上就是矛盾的：UA 说「Pixel 8 Pro」而 `screen.width` 是
/// 412、时区是 `Asia/Shanghai`，那串 UA 一眼就是手改的。
///
/// ## 注入时机
///
/// 必须 `AT_DOCUMENT_START`，在任何站点脚本之前。站点自己的
/// `reader.js` 一进来就读这些值 —— 晚一步就来不及。
///
/// ## 为什么用 `Object.defineProperty` 而不是直接赋值
///
/// 直接赋值只改当前值，`navigator` 上那些是 getter，站点再读一次还是原值；
/// 而且直接赋值会留下一个「可写的自有属性」，比原生的更好检测。
/// `defineProperty` 装的是 getter，形状和原生一致。
///
/// ## 这个脚本不做什么
///
/// 它**不伪造 canvas/WebGL 指纹**。那些要真正扰动渲染结果，做不好会让
/// 页面变慢或渲染出错，而收益不确定 —— 站点目前没有读它们（实测抓的
/// `reader.js` / `live.js` 里零命中）。以后真需要了再加，不是现在。
library;

import 'dart:convert';

import '../data/identity_profile.dart';

/// 生成注入脚本。
///
/// [profile] 为 null 时返回空串 —— 那表示「还没换过身份，就用本机真实值」。
/// 返回空串而不是「一套默认值」，因为给本机套一组假值反而更容易露。
String identityScript(IdentityProfile? profile) {
  if (profile == null) return '';

  // 值全部由 Dart 侧算好再塞进去，JS 里不做判断 ——
  // 少一层逻辑就少一处能出岔子的地方。
  final v = jsonEncode({
    'hardwareConcurrency': profile.hardwareConcurrency,
    'deviceMemory': profile.deviceMemory,
    'lang': profile.language,
    'tz': profile.timeZone,
    'sw': profile.screen.width,
    'sh': profile.screen.height,
    'dpr': profile.screen.devicePixelRatio,
    'os': profile.androidVersion,
    'chrome': profile.chromeMajor,
  });

  return '''
(function(){
  var V = $v;
  if (!V) return;

  // 装 getter，形状和原生一致。
  function def(obj, key, val) {
    try {
      Object.defineProperty(obj, key, {
        get: function(){ return val; },
        configurable: true,
        enumerable: true,
      });
    } catch (e) { /* 冻结了的对象，跳过 */ }
  }

  // 方法型：返回固定值。
  // 方法型：直接把函数装上去。
  //
  // **不能写成 `value: function(){ return val; }`** —— 那样调
  // `getHighEntropyValues()` 返回的是 `val` 本身（一个函数），
  // 而不是它调用的结果。实测踩过：返回 `[object Function]`，
  // 而站点 `await` 它得到的是函数，不是对象。
  function defFn(obj, key, fn) {
    try {
      Object.defineProperty(obj, key, {
        value: fn,
        configurable: true,
        writable: true,
      });
    } catch (e) {}
  }

  def(navigator, 'hardwareConcurrency', V.hardwareConcurrency);
  def(navigator, 'deviceMemory', V.deviceMemory);

  // 语言：主语言 + 列表。列表必须包含主语言，否则自相矛盾。
  def(navigator, 'language', V.lang);
  def(navigator, 'languages', Object.freeze([V.lang]));

  // 时区。`Intl.DateTimeFormat().resolvedOptions().timeZone` 是站点最常
  // 读的一个 —— 它比 `getTimezoneOffset()` 更精确（能区分夏令时）。
  try {
    var ro = Intl.DateTimeFormat().resolvedOptions;
    Object.defineProperty(Intl.DateTimeFormat.prototype, 'resolvedOptions', {
      value: function(){
        var r = ro.call(this);
        r.timeZone = V.tz;
        return r;
      },
      configurable: true,
      writable: true,
    });
  } catch (e) {}

  // 屏幕。四个值要一起改：只改 width 而 availWidth 还是原来的，
  // 一对比就露。
  def(screen, 'width', V.sw);
  def(screen, 'height', V.sh);
  def(screen, 'availWidth', V.sw);
  def(screen, 'availHeight', V.sh);
  def(window, 'devicePixelRatio', V.dpr);

  // 视口。innerWidth/innerHeight 反映的是当前可视区，站点有时也读。
  def(window, 'outerWidth', V.sw);
  def(window, 'outerHeight', V.sh);

  // Client Hints。Chrome 90+ 才有 `navigator.userAgentData`，
  // 有才改 —— 本机没有而硬塞一个，反而多出一个原生不存在的东西。
  if (navigator.userAgentData) {
    var ua = navigator.userAgent;
    var major = String(V.chrome);
    var brands = [
      {brand: 'Chromium', version: major},
      {brand: 'Google Chrome', version: major},
    ];
    def(navigator.userAgentData, 'brands', Object.freeze(brands));
    def(navigator.userAgentData, 'mobile', true);
    defFn(navigator.userAgentData, 'getHighEntropyValues', function(){
      return Promise.resolve({
        brands: brands,
        mobile: true,
        platform: 'Android',
        platformVersion: V.os || '14',
        architecture: 'arm',
        bitness: '64',
        model: '',
        uaFullVersion: (ua.match(/Chrome\\/([\\d.]+)/) || [0, V.chrome + '.0.0.0'])[1],
      });
    });
  }
})();
''';
}
