#!/usr/bin/env bash
# 出 Android release 包。
#
# 用法：tool/build_release_apks.sh [VERSION [BUILD_NUMBER]]
#
# 版本号会写进 pubspec.yaml。签名信息从 `android/key.properties` 读，
# 那份文件不进仓库。**没有它就只能出 unsigned 包** —— 脚本会明确说是在
# 出 unsigned，而不是静默出一个装不上的包。
set -euo pipefail

if [[ "$#" -gt 2 ]]; then
  echo "用法：build_release_apks.sh [VERSION [BUILD_NUMBER]]" >&2
  exit 64
fi

version_line=$(sed -n 's/^version: //p' pubspec.yaml)
if [[ -z "$version_line" ]]; then
  echo "pubspec.yaml 里没有 version 行" >&2
  exit 1
fi

app_version="${1:-${version_line%%+*}}"
build_number="${2:-}"
if [[ -z "$app_version" ]]; then
  echo "版本号不能为空" >&2
  exit 64
fi

# 签名信息在不在，决定出的是 signed 还是 unsigned。**必须说出来** ——
# 一个 unsigned 的 apk 装不上，而「构建成功」这几个字会让人以为没事。
if [[ -f android/key.properties ]]; then
  echo "签名：android/key.properties 在，出 signed 包"
else
  echo "签名：**没有 android/key.properties，这个包是 unsigned 的，装不上**" >&2
fi

flutter_args=(
  build apk
  --release
  --split-per-abi
  # 只编 arm64（arm64-v8a）。
  #
  # `--split-per-abi` 会为每个 ABI 各做一次完整的 release AOT 编译 ——
  # 两份 AOT 就是双倍构建时间。而 android-arm（armeabi-v7a）是 32 位老架构，
  # 只服务 2016 年前的老机和少数 Android Go 机型。目标机全是 arm64-v8a。
  #
  # 保留 `--split-per-abi` 是为了沿用 `app-arm64-v8a-release.apk` 这个产物名。
  --target-platform=android-arm64
  # 混淆 + 保留符号表。没有符号表的话线上崩溃栈全是 `a.b()`，
  # 等于没法排查。`build/debug-info` 会被 CI 一起上传。
  --obfuscate
  --split-debug-info=build/debug-info
  -t lib/main.dart
  "--dart-define=APP_VERSION=$app_version"
)
if [[ -n "$build_number" ]]; then
  flutter_args+=("--build-number=$build_number")
fi

exec flutter "${flutter_args[@]}"
