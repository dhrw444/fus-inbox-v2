// 改 pubspec.yaml 里的 version 行。
//
// 用法：dart run tool/set_release_version.dart <版本> <构建号>
//
// ## 校验就是发版门禁本身
//
// 这个脚本一旦放过畸形版本号，整条流水线就带着坏版本号出包 —— 而
// 版本号写错不会让构建失败，只会让装上去的包「看起来是新的、其实是旧的」，
// 或者让升级判定失效（`versionCode` 没涨，安卓直接不让覆盖安装）。
//
// 三条拒绝规则：
//
//   ① 版本号必须是 semver，且**不带 build metadata**（`1.2.3+4` 不收）。
//      因为 Flutter 的 version 字段里 `+` 后面那截是构建号，语义和
//      semver 的 build metadata 不是一回事 —— 混着用会在 CI 里造出
//      「同一个版本号两个不同产物」。
//
//   ② 构建号必须是**正整数**，且原样字符串能对回数字（`0042` 和 `4` 不
//      等价，而 `int.parse` 会悄悄放过前者）。安卓的 versionCode 是整数，
//      前导零没有任何意义，只会让两个「看起来不同」的输入产生同一个包。
//
//   ③ pubspec 里必须真有 version 行。缺了就直接报错，不要偷偷加上去 ——
//      悄悄补一个默认版本号比失败更糟。
//
// ## 为什么不用 pub_semver
//
// 旧项目 import 了 `package:pub_semver`，但那个包**不是这个项目直接依赖
// 的东西**（它是 pub 自己的依赖，能用到纯属传递）。为了一个 69 行的脚本
// 引入一条依赖链不划算 —— semver 的解析规则就那几行，自己写清楚更可控。
import 'dart:io';

/// 解析出的版本号：`主.次.修订[-预发布]`。
class const ReleaseVersion({
  required this.major,
  required this.minor,
  required this.patch,
  this.preRelease = '',
}) {
  final int major;
  final int minor;
  final int patch;

  /// 预发布标记（`1.0.0-rc.1` 里的 `rc.1`）。空串表示正式版。
  final String preRelease;

  bool get isPreRelease => preRelease.isNotEmpty;

  @override
  String toString() => preRelease.isEmpty
      ? '$major.$minor.$patch'
      : '$major.$minor.$patch-$preRelease';
}

/// 解析版本号。畸形就抛 [FormatException]，**不做任何修正**。
///
/// 修正畸形输入是个陷阱：`1.0` 补成 `1.0.0` 看着友好，但用户以为自己
/// 填的是 `1.0`，而实际发出去的是另一个版本号。
ReleaseVersion parseReleaseVersion(String raw) {
  // 带 `+` 的直接拒 —— 见文件头的规则 ①。
  if (raw.contains('+')) {
    throw const FormatException('版本号不要带 build metadata（`+构建号`）');
  }
  final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.\-]+))?$')
      .firstMatch(raw);
  if (m == null) {
    throw FormatException('不是合法的 semver：`$raw`（要 `主.次.修订`）');
  }
  int part(int i) {
    final s = m.group(i)!;
    // 前导零一律拒。`01` 和 `1` 是同一个数，但字符串不同 —— 发版工具
    // 里这种「看起来不同、其实是同一个」的输入只会造出混乱。
    if (s.length > 1 && s.startsWith('0')) {
      throw FormatException('版本号每一段不要有前导零：`$s`');
    }
    return int.parse(s);
  }

  return ReleaseVersion(
    major: part(1),
    minor: part(2),
    patch: part(3),
    preRelease: m.group(4) ?? '',
  );
}

/// 把 [pubspec] 里的 version 行换成 `版本+构建号`，返回新内容。
///
/// 只改 `version:` 那一行，别的一个字节都不动。
String updateReleaseVersion(
  String pubspec,
  String versionName,
  String buildNumber,
) {
  final version = parseReleaseVersion(versionName);
  final build = int.tryParse(buildNumber);
  if (build == null || build <= 0 || build.toString() != buildNumber) {
    throw const FormatException('构建号要是正整数，且不能有前导零');
  }
  final versionLine = RegExp(r'^version:.*$', multiLine: true);
  if (!versionLine.hasMatch(pubspec)) {
    throw const FormatException('pubspec.yaml 里没有 version 行');
  }
  return pubspec.replaceFirst(versionLine, 'version: $version+$build');
}

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('用法：set_release_version.dart VERSION BUILD_NUMBER');
    exitCode = 64;
    return;
  }
  final pubspec = File('pubspec.yaml');
  try {
    final version = parseReleaseVersion(args[0]);
    final updated = updateReleaseVersion(
      await pubspec.readAsString(),
      args[0],
      args[1],
    );
    await pubspec.writeAsString(updated);

    // 把「是不是预发布」交给 CI，它决定 Release 要不要标 prerelease。
    // 没有这个环境变量时（本地手动跑）就什么都不写。
    final githubOutput = Platform.environment['GITHUB_OUTPUT'];
    if (githubOutput != null) {
      await File(githubOutput).writeAsString(
        'prerelease=${version.isPreRelease}\n',
        mode: FileMode.append,
      );
    }
    stdout.writeln('版本 → $version+${args[1]}');
  } on FormatException catch (e) {
    stderr.writeln('版本号不合法：${e.message}');
    exitCode = 64;
  }
}
