/// 从短信正文里提取验证码。
///
/// ## 为什么单独一个文件
///
/// 它是最容易写错、又最值得单测的一块：正则稍有偏差就会把电话号码、
/// 金额、日期当成验证码。而这三种东西在验证短信里**到处都是**。
///
/// ## 判据的取舍
///
/// 短信里的数字有四种：
///   1. 验证码 —— 4~8 位，通常独立出现
///   2. 电话号码 —— 10~11 位，常带 `+` 或连字符
///   3. 金额 / 日期 / 订单号 —— 长度不定，常带货币符号或日期分隔符
///   4. 品牌号（如 `Google`、`WhatsApp`）—— 根本不是数字
///
/// 策略：**先排除明确不是的，再取最像的**。宁可提取不出来（返回空串，
/// 界面显示原文让用户自己看），也不要把电话号码当验证码给用户复制 ——
/// 后者会让用户把验证码填到别处，比提取失败糟得多。
library;

/// 提取结果。空串表示没找到可信的验证码。
///
/// [fromSite] 为真表示这个值不是我们猜的，而是站点明确给了（`copy_code`
/// 属性之类）。两者的区别很重要：站点给的可以直接用，我们猜的要更保守。
class const ExtractedCode({
  required this.value,
  required this.fromSite,
}) {
  final String value;
  final bool fromSite;

  static const none = ExtractedCode(value: '', fromSite: false);
}

/// 从 [text] 里找验证码。
///
/// 只返回**一处**：第一条可信的。不返回全部 —— 界面只显示一个、用户只
/// 复制一个，列出一堆候选反而让人不知道该点哪个。
ExtractedCode extractCode(String text) {
  if (text.isEmpty) return ExtractedCode.none;

  // 先按「候选」扫一遍：独立的 4~8 位数字串。
  //
  // 「独立」的判据是前后不是数字，且不紧贴这些符号：
  //   `+`（电话前缀）、`-`（电话/日期分隔）、`.`（小数/日期）、
  //   `$`（金额）、`/`（日期）、`:`（时间）
  //
  // 用 `(?<!…)` 和 `(?!…)` 而不是 split —— split 会把 `123-456-7890`
  // 切成三段，每段都可能是 3~4 位，反而制造假候选。
  final candidates = <String>[];
  for (final m in _codePattern.allMatches(text)) {
    final v = m.group(0)!;
    // 纯 0 串不是验证码（`0000` 是占位，`000000` 是填充）。
    if (v.replaceAll('0', '').isEmpty) continue;
    // 落在电话号码里的不算。
    //
    // `+1 415 555 0100` 这种：`0100` 前面是空格、后面是结尾，正则本身
    // 挡不住。判据是「这一处往前看 12 个字符里有 `+` 或至少两个 `-`/空格
    // 分隔的数字段」—— 那是电话的形状，不是验证码的形状。
    if (_looksLikePhoneContext(text, m.start)) continue;
    candidates.add(v);
  }
  if (candidates.isEmpty) return ExtractedCode.none;

  // 多个候选时取**最长的**：验证码通常比同句里的其他数字长
  // （订单号尾号 4 位 vs 验证码 6 位）。等长时取第一个 —— 英文短信
  // 的语序是「Your code is 123456」，验证码在前。
  var best = candidates.first;
  for (final c in candidates) {
    if (c.length > best.length) best = c;
  }
  return ExtractedCode(value: best, fromSite: false);
}

/// 候选模式。
///
/// 前面不能是这些字符（`(?<!…)` 是「前面不是」，`(?!…)` 是「后面不是」）：
/// 数字、字母（避免从 `ABC123456` 里切出 `123456`）、
/// `+ - . $ / :`（电话、日期、金额、时间）
///
/// 三处细节：
///   1. **后面允许句号/逗号** —— `Code: 482913.` 很常见，句号是句子结尾，
///      不是数字的一部分。原来把 `.` 放在后瞻里，那条就提不出来。
///   2. **前面挡 `+` 和 `-`** —— `+1 415 555 0100` 里的 `0100` 前面是
///      空格，单靠前一位挡不住。所以另加一条「整段像电话就不算」的规则，
///      见 [_looksLikePhoneContext]。
///   3. 长度 4~8：3 位太少（验证码几乎不会是 3 位，而日期/金额片段常是 3 位），
///      9 位以上是订单号/电话。
final _codePattern = RegExp(
  r'(?<![\dA-Za-z+\-.$/:])(\d{4,8})(?![\d\-/:])',
);

/// 判断这条短信值不值得当成「带验证码的」。
///
/// 只有真提取到才算 —— 光看正文里有没有「code」这个词不够，
/// 很多短信写「no verification code needed」。
bool looksLikeVerification(String text) {
  if (text.isEmpty) return false;
  if (extractCode(text).value.isEmpty) return false;
  // 再加一层语义确认：正文里要有验证类词汇，或者极短（纯验证码短信）。
  //
  // 纯短信号码：`123456 is your code`、`验证码 123456`。
  // 这两类都不含长句，所以用长度兜底是安全的。
  if (text.length <= 40) return true;
  return _verificationWords.hasMatch(text);
}

/// 验证类词汇。大小写不敏感。
///
/// 只列**确实表示验证码**的词。刻意不收 `number`（「your order number」
/// 太常见）和 `pin`（既可能是验证码也可能是别的）。
final _verificationWords = RegExp(
  r'verification|verify|code|otp|passcode|验证码|校验码|确认码',
  caseSensitive: false,
);

/// [pos] 处的数字是不是落在电话号码里。
///
/// 判据：往前 14 个字符的窗口里出现 `+` 紧跟数字，或者出现两个以上的
/// `-`（`123-456-7890` 的形状）。验证码句子里不会有这些。
bool _looksLikePhoneContext(String text, int pos) {
  final from = pos - 16 < 0 ? 0 : pos - 16;
  final window = text.substring(from, pos);
  // 窗口里出现 `+` —— 电话前缀。验证码句子里不会有 `+`。
  if (window.contains('+')) return true;
  // 窗口里已有两个以上连字符 —— `123-456-7890` 的形状。
  if ('-'.allMatches(window).length >= 2) return true;
  return false;
}
