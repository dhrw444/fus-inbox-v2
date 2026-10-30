import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox_v2/core/load_failure.dart';

void main() {
  group('错误翻译', () {
    test('枚举名优先于原生码', () {
      // 枚举说 HOST_LOOKUP，码给 -8（TIMEOUT）—— 该按枚举走。
      final f = describeLoadFailure(
        -8,
        'net::ERR_TIMED_OUT',
        kind: 'HOST_LOOKUP',
      );
      expect(f.title, '域名解析不了');
    });

    test('安卓码表命中', () {
      expect(describeLoadFailure(-2, '').title, '域名解析不了');
      expect(describeLoadFailure(-6, '').title, '连不上站点');
      expect(describeLoadFailure(-8, '').title, '连接超时');
      expect(describeLoadFailure(-11, '').title, '加密握手失败');
      expect(describeLoadFailure(-12, '').title, '地址不对');
      expect(describeLoadFailure(-15, '').title, '请求太频繁');
      expect(describeLoadFailure(-16, '').title, '页面里有不安全的内容');
    });

    test('地址不对不该重试', () {
      expect(describeLoadFailure(-12, '').retryable, isFalse);
    });

    test('网络类错误该重试', () {
      expect(describeLoadFailure(-8, '').retryable, isTrue);
      expect(describeLoadFailure(-2, '').retryable, isTrue);
    });

    test('枚举名覆盖跨平台值', () {
      expect(
        describeLoadFailure(null, '', kind: 'NOT_CONNECTED_TO_INTERNET').title,
        '设备没联网',
      );
      expect(
        describeLoadFailure(
          null,
          '',
          kind: 'SERVER_CERTIFICATE_UNTRUSTED',
        ).title,
        '证书有问题',
      );
      expect(
        describeLoadFailure(null, '', kind: 'PROXY_AUTHENTICATION').title,
        '出口要认证',
      );
      expect(
        describeLoadFailure(null, '', kind: 'TOO_MANY_REQUESTS').title,
        '请求太频繁',
      );
    });

    test('枚举不认识时按原文猜', () {
      expect(
        describeLoadFailure(null, 'net::ERR_NAME_NOT_RESOLVED').title,
        '域名解析不了',
      );
      expect(
        describeLoadFailure(null, 'net::ERR_INTERNET_DISCONNECTED').title,
        '设备没联网',
      );
      expect(
        describeLoadFailure(null, 'net::ERR_CONNECTION_REFUSED').title,
        '连接被拒绝',
      );
    });

    test('全都认不出来时兜底带上原文', () {
      // 关键：不能把原文丢掉 —— 那是唯一能定位问题的线索。
      final f = describeLoadFailure(null, 'some weird kernel message');
      expect(f.title, '页面加载失败');
      expect(f.detail, 'some weird kernel message');
    });

    test('空原文兜底也不给空白', () {
      final f = describeLoadFailure(null, '');
      expect(f.detail, '没有更多信息。');
    });

    test('用户自己取消算中性，不算失败原因', () {
      final f = describeLoadFailure(null, '', kind: 'CANCELLED');
      expect(f.title, '已取消');
    });

    test('每一条都有非空标题和说明', () {
      // 遍历所有可能输入，确认没有哪条会给出空字符串 ——
      // 状态栏显示空白等于用户什么都不知道。
      for (final code in [-2, -6, -8, -11, -12, -15, -16, -1, 0]) {
        final f = describeLoadFailure(code, 'net::ERR_X');
        expect(f.title, isNotEmpty, reason: 'code=$code');
        expect(f.detail, isNotEmpty, reason: 'code=$code');
      }
    });
  });
}
