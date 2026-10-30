/// 持久化：把「跨会话必须活下来」的东西存到磁盘。
///
/// ## 存什么、为什么
///
/// 只有两样：
///
///   1. **上次用的 UA** —— 站点把「访客」绑在一对存在 IndexedDB 里的
///      密钥上。重启回到内核真值 = 拿旧密钥配一个全新身份，比不换更
///      可疑（对方会认为这台设备的指纹变了）。
///   2. **上次选的出口** —— 只存 [ProxyConfig.id]（不含密码），
///      重新从清单里找那条。存整条（含密码）等于把凭据明文写在
///      SharedPreferences 里，而安卓上那个文件对 root 是可见的。
///
/// ## 为什么单独一个文件
///
/// `core/user_agent.dart` 和 `data/egress.dart` 都是**零 Flutter 依赖**
/// 的纯逻辑，能脱离框架跑测试。往它们里塞 `SharedPreferences` 会把
/// 这条性质毁掉 —— 而那条性质是这个项目唯一能在沙箱里验的东西。
/// 所以 IO 全收在这里，上层只调「读 / 写」。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 底层句柄的可变盒子。
///
/// 存在的唯一理由：[Store] 的字段不能是「每次构造都新建一个盒子」——
/// 那样缓存就失效了（每次 `_prefs()` 都是新的空盒子，永远命中不了）。
/// 所以盒子是 `final` 的、内容是 `var` 的。
class _Cache() {
  SharedPreferences? p;
}

/// 存储键。
///
/// **带版本后缀**。不加的话，改了值的含义（比如从「完整 UA」改成
/// 「只存机型」）之后，旧值会被当成新含义读出来 —— 而那不会报错，
/// 只会让身份莫名其妙地不自洽。
///
/// 写成顶层常量而不是 `class Keys { static const ... }`：那个类只装
/// 常量、不该被实例化，于是要为它专门加一个私有构造器来堵实例化，
/// 而 `use_primary_constructors` 又会来要求把那个私有构造器改成主
/// 构造器写法 —— 一层套一层全是废话。顶层常量没有这个问题，
/// 也和本项目的既有写法一致（见 `platform/web_view.dart` 的
/// `messageChannel`）。

/// 上次用的完整 UA。
const kUserAgentKey = 'ua_v1';

/// 整份身份画像。JSON。
///
/// 和 [kUserAgentKey] 并存：老键只存 UA，读它恢复出来的身份**屏幕和
/// 时区还是本机的** —— 那是个自相矛盾的半身份。新键存全，老键留着
/// 只为了兼容已升级的用户（读到老键就当成「只有 UA」）。
const kProfileKey = 'profile_v1';

/// 待清标记。换了身份但还没清站点数据时置 1。
///
/// 为什么需要这个：出口页没有 WebView，跑不了删 IndexedDB 的脚本。
/// 那里点「换一个身份」只能清原生层（cookie/缓存），密钥还在盘上。
/// 收件箱下次打开页面时看到这个标记，会先把密钥清掉再加载 ——
/// 不清的话站点看到的是「新 UA + 旧密钥」，身份对不上。
const kWipePendingKey = 'wipe_pending_v1';

/// 上次选的出口 id（`scheme://host:port`，不含密码）。
const kEgressIdKey = 'egress_v1';

/// 上次选的出口在清单里的下标。id 找不到时的兜底。
const kEgressIndexKey = 'egress_index_v1';

/// 收藏的号码。逗号分隔。
///
/// 不用 `setStringList`：`Store` 只有 `getString`/`getInt` 两个原语，
/// 为一个字段加第三个原语会让那个类多一条要维护的路径。号码是纯数字，
/// 逗号分隔不会有歧义。
const kStarsKey = 'stars_v1';

/// 号码 ↔ 访客记忆 + 出口↔身份绑定 + 拒绝记录。JSON。
const kVisitorsKey = 'visitors_v1';

/// 身份 id ↔ UA 还原表。JSON。
///
/// 单独一份而不是塞进 `visitors_v1`：两者生命周期不同 —— 名册要
/// 「记得所有用过的身份」，记忆只需要最近那几个。
const kRosterKey = 'roster_v1';

/// 一个够用的持久化门面。
///
/// 所有读写都**不抛**：磁盘满、权限错、值被外部改坏 —— 这些都不该
/// 让应用打不开。读失败返回 null，调用方走默认路径。
class Store() {
  /// 底层句柄的缓存。
  ///
  /// 装在一个可变的小盒子里，而不是直接写 `SharedPreferences? _p`：
  /// 直接写的话 `_p` 得是 `var`，而 `var` 字段又要求构造器不能是 `const`
  /// —— 两者互相牵制。用 `final` 的盒子 + 可变的 `p` 就绕开了。
  final _Cache _cache = _Cache();

  /// 拿到底层。首次调用时初始化，失败就返回 null 并一直返回 null
  /// （重试没有意义：初始化失败通常是环境问题）。
  Future<SharedPreferences?> _prefs() async {
    final cached = _cache.p;
    if (cached != null) return cached;
    try {
      final p = await SharedPreferences.getInstance();
      _cache.p = p;
      return p;
    } catch (_) {
      return null;
    }
  }

  Future<String?> read(String key) async {
    try {
      return (await _prefs())?.getString(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, String value) async {
    try {
      await (await _prefs())?.setString(key, value);
    } catch (_) {
      // 存不上就存不上。下次启动回到内核真值，那是可接受的降级。
    }
  }

  Future<int?> readInt(String key) async {
    try {
      return (await _prefs())?.getInt(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeInt(String key, int value) async {
    try {
      await (await _prefs())?.setInt(key, value);
    } catch (_) {
      // 同上。
    }
  }

  /// 清掉一个键。
  ///
  /// 换身份时要清 UA —— 否则「换了个新身份」重启之后又变回旧的。
  Future<void> remove(String key) async {
    try {
      await (await _prefs())?.remove(key);
    } catch (_) {
      // 同上。
    }
  }
}
