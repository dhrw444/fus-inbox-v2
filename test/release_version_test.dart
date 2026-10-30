
import '../tool/set_release_version.dart';

import 'package:test/test.dart';

void _ok(String name, bool cond, [String? detail]) {
  expect(cond, isTrue, reason: detail == null ? name : '$name ($detail)');
}

void _eq(String name, Object? got, Object? want) {
  expect(got, want, reason: name);
}

/// 断言抛了 FormatException。
void _rejects(String name, void Function() fn) {
  expect(fn, throwsFormatException, reason: name);
}

void main() {
  test('release_version', () async {

  // ── 正常解析 ──
  {
    final v = parseReleaseVersion('1.2.3');
    _eq('主版本', v.major, 1);
    _eq('次版本', v.minor, 2);
    _eq('修订', v.patch, 3);
    _eq('不是预发布', v.isPreRelease, false);
    _eq('回写成原样', v.toString(), '1.2.3');
  }
  {
    final v = parseReleaseVersion('0.1.0-rc.1');
    _eq('预发布标记', v.preRelease, 'rc.1');
    _eq('是预发布', v.isPreRelease, true);
    _eq('回写带标记', v.toString(), '0.1.0-rc.1');
  }
  {
    // 大版本号不该溢出。
    final v = parseReleaseVersion('2026.10.30');
    _eq('大数字', v.major, 2026);
  }

  // ── 拒绝：build metadata ──
  _rejects('拒 `1.2.3+4`', () => parseReleaseVersion('1.2.3+4'));
  _rejects('拒 `1.2.3+0`', () => parseReleaseVersion('1.2.3+0'));

  // ── 拒绝：畸形 ──
  _rejects('拒 `1.0`（缺一段）', () => parseReleaseVersion('1.0'));
  _rejects('拒 `1`', () => parseReleaseVersion('1'));
  _rejects('拒 `1.2.3.4`（多一段）', () => parseReleaseVersion('1.2.3.4'));
  _rejects('拒空串', () => parseReleaseVersion(''));
  _rejects('拒 `v1.2.3`（带前缀）', () => parseReleaseVersion('v1.2.3'));
  _rejects('拒 `1.2.x`', () => parseReleaseVersion('1.2.x'));
  _rejects('拒空格', () => parseReleaseVersion(' 1.2.3'));

  // ── 拒绝：前导零（`01` 和 `1` 是同一个数，但字符串不同）──
  _rejects('拒 `01.2.3`', () => parseReleaseVersion('01.2.3'));
  _rejects('拒 `1.02.3`', () => parseReleaseVersion('1.02.3'));
  _rejects('拒 `1.2.03`', () => parseReleaseVersion('1.2.03'));
  // `0` 本身是允许的（不是前导零）。
  _ok('允许 `0.1.0`', parseReleaseVersion('0.1.0').minor == 1);

  // ── updateReleaseVersion ──
  {
    const pubspec = '''
name: fus_inbox
version: 0.0.0+1
environment:
  sdk: ^3.13.0
''';
    final out = updateReleaseVersion(pubspec, '1.2.3', '42');
    _ok('写入了新版本', out.contains('version: 1.2.3+42'));
    _ok('别的东西没动', out.contains('name: fus_inbox'));
    _ok('sdk 约束没动', out.contains('sdk: ^3.13.0'));
    _eq('只多一行内容', out.split('\n').length, pubspec.split('\n').length);
  }
  {
    // 预发布也能写。
    final out = updateReleaseVersion('version: 0.0.0+1\n', '1.0.0-beta', '7');
    _ok('预发布写进去了', out.contains('version: 1.0.0-beta+7'));
  }

  // ── updateReleaseVersion 拒绝 ──
  _rejects('没有 version 行就报错', () {
    updateReleaseVersion('name: x\n', '1.2.3', '1');
  });
  _rejects('构建号为 0 拒', () {
    updateReleaseVersion('version: 0.0.0+1\n', '1.2.3', '0');
  });
  _rejects('构建号为负拒', () {
    updateReleaseVersion('version: 0.0.0+1\n', '1.2.3', '-5');
  });
  _rejects('构建号带前导零拒', () {
    updateReleaseVersion('version: 0.0.0+1\n', '1.2.3', '042');
  });
  _rejects('构建号不是数字拒', () {
    updateReleaseVersion('version: 0.0.0+1\n', '1.2.3', 'abc');
  });
  _rejects('版本号畸形也拒', () {
    updateReleaseVersion('version: 0.0.0+1\n', '1.2', '1');
  });

  // ── 幂等：同样输入两次，结果一样 ──
  {
    const base = 'version: 0.0.0+1\n';
    final a = updateReleaseVersion(base, '1.0.0', '9');
    final b = updateReleaseVersion(base, '1.0.0', '9');
    _ok('幂等', a == b);
    // 二次调用（已经改过的内容再改一次）也稳定。
    final c = updateReleaseVersion(a, '1.0.0', '9');
    _ok('二次调用稳定', c == a);
  }

  });
}

