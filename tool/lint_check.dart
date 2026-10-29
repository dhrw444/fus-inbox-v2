/// 本地 lint 检查。
///
/// ## 为什么要这个
///
/// 沙箱里 `flutter analyze` 是瞎的（它的 `package_config.json` 里
/// `sky_engine` 指向一个没有 `lib/ui/ui.dart` 的目录，analyzer 解析失败后
/// **静默吞掉整个文件**）。而 CFE 只做类型检查、不做 lint。
///
/// 结果是：**每个 lint 问题都要等 CI 跑一遍才发现**。而 CI 一轮要几分钟，
/// 一轮只报几条 —— 反复迭代的代价很高。
///
/// 这个脚本覆盖我实际踩过的那几条规则，能在本地先挡一遍。
/// 它不是 analyzer 的替代品，只是「推之前把明显的问题挑出来」。
///
/// 跑法：
///
/// ```
/// dart run tool/lint_check.dart
/// ```
library;

import 'dart:io';

int problems = 0;

void main() {
  final files = <String>[];
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      files.add(entity.path);
    }
  }
  files.sort();

  // 全部源码拼一起，用于判「这个符号有没有别处引用」。
  final all = files.map((f) => File(f).readAsStringSync()).join('\n');

  for (final path in files) {
    final src = File(path).readAsStringSync();
    _checkUnusedImport(path, src);
    _checkPrivateConstructorKey(path, src);
    _checkPublicWidgetKey(path, src);
    _checkPrimaryConstructors(path, src);
  }

  print('');
  if (problems == 0) {
    print('  本地 lint 检查通过');
  } else {
    print('  $problems 个问题');
    exitCode = 1;
  }
}

void _fail(String path, int line, String rule, String detail) {
  print('  $path:$line  $rule  $detail');
  problems++;
}

/// 未使用的 import。
///
/// 判据：`dart:xxx` 看它对应的符号有没有出现；相对 import 看文件 basename
/// 转成的驼峰类名有没有被引用。比 analyzer 松，但能抓住绝大多数。
void _checkUnusedImport(String path, String src) {
  final lines = src.split('\n');
  final body = lines
      .where((l) => !l.trimLeft().startsWith('import '))
      .join('\n');
  for (var i = 0; i < lines.length; i++) {
    final m = RegExp(r"^import '([^']+)'").firstMatch(lines[i]);
    if (m == null) continue;
    final imp = m.group(1)!;
    // `package:` 开头的（flutter / flutter_inappwebview 等）**跳过** ——
    // 它们在源码里用的是里面的类名，而「哪个类来自哪个包」需要知道包的
    // 全部导出，这个脚本做不到。硬判只会全是假阳性。
    if (imp.startsWith('package:')) continue;
    if (imp.contains('/')) {
      // 相对 import
      final base = imp.split('/').last.replaceAll('.dart', '');
      final camel = base
          .split('_')
          .map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1))
          .join();
      if (!body.contains(camel) && !body.contains(base)) {
        _fail(path, i + 1, 'unused_import', imp);
      }
      continue;
    }
    if (!imp.startsWith('dart:')) continue;
    final lib = imp.substring(5);
    final needed = <String, List<String>>{
      'convert': ['json', 'utf8', 'base64', 'JsonEncoder'],
      'io': [
        'File',
        'Directory',
        'HttpClient',
        'Socket',
        'Platform',
        'Process',
      ],
      'math': ['Random', 'max(', 'min(', 'pi', 'sqrt'],
      'async': [
        'Timer',
        'Stream',
        'Completer',
        'unawaited',
        'scheduleMicrotask',
      ],
      'collection': ['UnmodifiableListView', 'LinkedHashMap', 'ListQueue'],
    }[lib];
    if (needed == null) continue;
    if (!needed.any(body.contains)) {
      _fail(path, i + 1, 'unused_import', imp);
    }
  }
}

/// 私有 widget 带 `super.key`。
///
/// 私有 widget 在外面只被 new 一次、从不传 key，于是
/// `unused_element_parameter` 会说「这个参数从没被给过值」。
void _checkPrivateConstructorKey(String path, String src) {
  final lines = src.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final m = RegExp(r'^class (const )?(_\w+)\(\{').firstMatch(lines[i]);
    if (m == null) continue;
    // 看这个构造器（往后几行）有没有 super.key
    var end = i;
    while (end < lines.length && !lines[end].contains('})')) {
      end++;
    }
    final block = lines.sublist(i, (end + 1).clamp(0, lines.length)).join('\n');
    if (block.contains('super.key')) {
      _fail(
        path,
        i + 1,
        'unused_element_parameter',
        '${m.group(2)} 是私有的，不该带 super.key',
      );
    }
  }
}

/// 公开 widget 缺 `super.key`。
void _checkPublicWidgetKey(String path, String src) {
  final lines = src.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final m = RegExp(r'^class (const )?([A-Z]\w*)[\(\{]').firstMatch(lines[i]);
    if (m == null) continue;
    final name = m.group(2)!;
    var end = i;
    while (end < lines.length && !lines[end].contains('extends')) {
      end++;
    }
    if (end >= lines.length) continue;
    final head = lines[end];
    if (!head.contains('StatelessWidget') && !head.contains('StatefulWidget')) {
      continue;
    }
    final block = lines.sublist(i, (end + 1).clamp(0, lines.length)).join('\n');
    if (!block.contains('super.key')) {
      _fail(path, i + 1, 'use_key_in_widget_constructors', '$name 缺 super.key');
    }
  }
}

/// 类 / 枚举没用主构造器语法。
///
/// 本仓库的方言是 `class const Foo({...}) extends X {` 与 `enum Foo() {`。
void _checkPrimaryConstructors(String path, String src) {
  final lines = src.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    // 传统写法：class X extends ... 后面跟着 `X(...)` 构造器
    final m = RegExp(r'^class ([A-Z]\w*)( extends| \{)').firstMatch(l);
    if (m != null) {
      _fail(path, i + 1, 'use_primary_constructors', m.group(1)!);
      continue;
    }
    // enum 要带 ()
    final e = RegExp(r'^enum ([A-Z]\w*) \{').firstMatch(l);
    if (e != null) {
      _fail(path, i + 1, 'use_primary_constructors', 'enum ${e.group(1)} 缺 ()');
    }
  }
}
