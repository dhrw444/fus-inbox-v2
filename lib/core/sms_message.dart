/// 一条短信。
///
/// ## 为什么先写这个
///
/// 它是整个应用里**唯一**同时被三个层用到的东西：抓取层产它、状态层存它、
/// 界面层画它。所以它必须是纯数据、零依赖 —— 不碰 Flutter、不碰网络、
/// 不碰存储。这样它能在 `tool/` 下单测，而不用起一个 Flutter 环境。
///
/// ## 字段全部用不可变 `final`
///
/// 一条短信抓到之后内容就不会再变（站点的短信也不会编辑）。同 id 的新帧
/// 只可能**补齐**缺失字段（正文分批抵达），那是用 [mergeWith] 生成一个新
/// 对象，而不是就地改。就地改是这类代码最容易长出来的隐性 bug：两个引用
/// 指向同一个对象，一处改了另一处莫名其妙地变。
library;

/// 一条短信。
class const SmsMessage({
  required this.id,
  required this.text,
  this.code = '',
  this.sender = '',
  this.time = '',
  this.phone = '',
  this.isProtected = false,
}) {
  /// 站点的事件 id。**去重靠它**，所以不能为空 —— 空 id 的消息直接丢掉。
  final String id;

  /// 正文。
  final String text;

  /// 验证码。站点给了就用站点的，否则从正文里提取。
  final String code;

  /// 发送方。
  final String sender;

  /// 站点给的时间文本（原样，不做解析）。
  ///
  /// 不解析成 `DateTime` 是刻意的：站点的格式不固定（有时相对、有时绝对、
  /// 有时干脆没有）。解析失败的代价是「排序错乱」，而保留原文本至少能显示。
  /// 排序另走一条：见 `messageSortKey`。
  final String time;

  /// 接收号码。
  final String phone;

  /// 站点标记「暂时不可读」。
  final bool isProtected;

  /// 有没有可复制的验证码。
  bool get hasCode => code.isNotEmpty;

  /// 同 id 的新帧补齐缺失字段。
  ///
  /// 规则：**新帧非空就用新帧，否则沿用旧值**。这条规则必须一处定义 ——
  /// 分散在多个调用点的话，两处迟早会漂移（一处「新帧优先」、一处
  /// 「旧帧优先」），而症状只是「偶尔某条正文缺一半」，极难查。
  ///
  /// ## `isProtected` 用「真值粘住」而不是「新帧说了算」
  ///
  /// 两条产出路径对这个标记的判据不同，强度也不同：
  ///   - 接口路径：站点 JSON 里明确给了 `protected: true` —— **强证据**
  ///   - DOM 路径：靠「页面上有没有那句固定说明」反推 —— **弱证据**
  ///     （说明文字还没渲染出来时会给出 false）
  ///
  /// 如果按「新帧说了算」，DOM 帧的 `false` 会把接口帧的 `true` 抹掉，
  /// 而界面上这个标记只在正文为空时才读（`message_card.dart` 的 `_body`），
  /// 正好是它最该起作用的场景 —— 用户看到「（没有正文）」而不是
  /// 「这条消息站点不公开」。
  ///
  /// 反过来「false 覆盖 true」永远不会是我们想要的：站点说受保护就是受保护，
  /// 只有站点自己改成 false 才该解封。所以规则是 `旧值 || 新值`。
  ///
  /// 副作用：一条消息一旦被标成受保护，本轮会话里不会再解封。这是可接受的 ——
  /// 站点对受保护消息本来就会在解锁后重新推送完整正文，那时 `text` 非空，
  /// 界面上走的是正文分支，标记是真是假都不影响显示。
  SmsMessage mergeWith(SmsMessage newer) => SmsMessage(
    id: id,
    text: newer.text.isNotEmpty ? newer.text : text,
    code: newer.hasCode ? newer.code : code,
    sender: newer.sender.isNotEmpty ? newer.sender : sender,
    time: newer.time.isNotEmpty ? newer.time : time,
    phone: newer.phone.isNotEmpty ? newer.phone : phone,
    isProtected: isProtected || newer.isProtected,
  );

  @override
  bool operator ==(Object other) => other is SmsMessage && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'SmsMessage($id)';
}
