/// 把 WebView 的错误翻成人话。
///
/// ## 为什么必须自己翻
///
/// `WebResourceError.description` 在安卓上是内核原文，长这样：
/// `net::ERR_NAME_NOT_RESOLVED`。直接把这段塞给用户等于什么都没说 ——
/// 他不知道是自己网断了、还是站点挂了、还是代理没起来。
///
/// ## 三个输入，各有各的用途
///
/// 1. **`kind`** —— 插件的跨平台枚举名（`HOST_LOOKUP` / `TIMEOUT` /
///    `CANNOT_CONNECT_TO_HOST` ...）。这是**最可靠**的一条：它是
///   插件自己映射过的语义，不随内核文案变化。
/// 2. **`code`** —— 安卓的 `WebViewClient.ERROR_*`（-1..-16）。
///    只在安卓上有意义，其它平台是 null。
/// 3. **`description`** —— 内核原文。当前两条都不认识时才用，按关键字猜。
///
/// 旧代码只用了 `description`，而且那张码表写的是 Chromium 的
/// `-105 / -137 / -118 / -200` 这类值 —— 那些在安卓的 `ERROR_*` 里
/// **一个都不存在**，于是永远走兜底，用户永远看到英文原文。
library;

/// 一条错误的说法。
class const LoadFailure({
  required this.title,
  required this.detail,
  required this.retryable,
}) {
  /// 一句话结论，给状态栏。
  final String title;

  /// 该怎么办。
  final String detail;

  /// 重试有没有意义。
  ///
  /// 网络类错误重试有意义；「地址格式不对」「本地文件读不到」重试一百次
  /// 也一样。
  final bool retryable;
}

/// 翻成人话。
///
/// [kind] 是插件枚举名（可空），[code] 是安卓原生码（可空），
/// [description] 是内核原文。
LoadFailure describeLoadFailure(
  int? code,
  String description, {
  String kind = '',
}) {
  // ── ① 枚举名优先：最可靠 ────────────────────────────────
  switch (kind) {
    case 'HOST_LOOKUP':
      return const LoadFailure(
        title: '域名解析不了',
        detail: '检查一下网络，或者换一条出口再试。',
        retryable: true,
      );
    case 'CANNOT_CONNECT_TO_HOST':
      return const LoadFailure(
        title: '连不上站点',
        detail: '站点可能挂了，也可能这条出口不通。换一条出口试试。',
        retryable: true,
      );
    case 'TIMEOUT':
      return const LoadFailure(
        title: '连接超时',
        detail: '这条出口太慢或者不通。换一条出口，或者稍后再试。',
        retryable: true,
      );
    case 'NOT_CONNECTED_TO_INTERNET':
      return const LoadFailure(
        title: '设备没联网',
        detail: '打开一下 Wi-Fi 或移动数据再试。',
        retryable: true,
      );
    case 'FAILED_SSL_HANDSHAKE':
    case 'SECURE_CONNECTION_FAILED':
      return const LoadFailure(
        title: '加密握手失败',
        detail: '出口可能在中间拦了 HTTPS。换一条出口。',
        retryable: true,
      );
    case 'SERVER_CERTIFICATE_UNTRUSTED':
    case 'SERVER_CERTIFICATE_REVOKED':
    case 'TLS_CERTIFICATE_GENERIC_ERROR':
    case 'CLIENT_CERTIFICATE_REJECTED':
    case 'CLIENT_CERTIFICATE_REQUIRED':
      return const LoadFailure(
        title: '证书有问题',
        detail: '出口可能在中间拦了 HTTPS。换一条出口。',
        retryable: true,
      );
    case 'PROXY_AUTHENTICATION':
      return const LoadFailure(
        title: '出口要认证',
        detail: '这条出口的账号密码不对。换一条，或者重新填。',
        retryable: false,
      );
    case 'BAD_URL':
      return const LoadFailure(
        title: '地址不对',
        detail: '号码格式可能有问题（站点只认 11 位）。',
        retryable: false,
      );
    case 'UNSUPPORTED_SCHEME':
      return const LoadFailure(
        title: '不支持的链接',
        detail: '页面跳到了一个打不开的地址。',
        retryable: false,
      );
    case 'TOO_MANY_REQUESTS':
      return const LoadFailure(
        title: '请求太频繁',
        detail: '站点在限流。等一会儿，或者换一条出口。',
        retryable: true,
      );
    case 'TOO_MANY_REDIRECTS':
      return const LoadFailure(
        title: '跳转次数过多',
        detail: '站点在来回跳。等一下再试。',
        retryable: true,
      );
    case 'UNSAFE_RESOURCE':
      return const LoadFailure(
        title: '页面里有不安全的内容',
        detail: '站点自己的问题，换个页面看看。',
        retryable: false,
      );
    case 'FILE_NOT_FOUND':
    case 'GENERIC_FILE_ERROR':
    case 'NO_PERMISSIONS_TO_READ_FILE':
      return const LoadFailure(
        title: '本地文件读不到',
        detail: '安装包可能不完整，重装一次试试。',
        retryable: false,
      );
    case 'CANCELLED':
    case 'USER_CANCELLED_AUTHENTICATION':
      // 用户自己取消的，不是错误。调用方一般会忽略，这里给个中性说法。
      return const LoadFailure(
        title: '已取消',
        detail: '这次加载被取消了。',
        retryable: true,
      );
    case 'RESET':
    case 'CONNECTION_ABORTED':
    case 'NETWORK_CONNECTION_LOST':
      return const LoadFailure(
        title: '连接被中断',
        detail: '这条出口不稳定。换一条试试。',
        retryable: true,
      );
    case 'SERVER_UNREACHABLE':
    case 'CANNOT_LOAD_FROM_NETWORK':
      return const LoadFailure(
        title: '连不上服务器',
        detail: '换一条出口，或者稍后再试。',
        retryable: true,
      );
    case 'ZERO_BYTE_RESOURCE':
    case 'BAD_SERVER_RESPONSE':
      return const LoadFailure(
        title: '站点返回了空内容',
        detail: '重试一次。还不行就换一条出口。',
        retryable: true,
      );
    case 'IO':
    case 'UNEXPECTED_ERROR':
    case 'UNKNOWN':
      // 这三种没有明确语义，落到下面。
      break;
    default:
      break;
  }

  // ── ② 安卓原生码 ───────────────────────────────────────
  switch (code) {
    case -2: // ERROR_HOST_LOOKUP
      return const LoadFailure(
        title: '域名解析不了',
        detail: '检查一下网络，或者换一条出口再试。',
        retryable: true,
      );
    case -6: // ERROR_CONNECT
      return const LoadFailure(
        title: '连不上站点',
        detail: '站点可能挂了，也可能这条出口不通。换一条出口试试。',
        retryable: true,
      );
    case -8: // ERROR_TIMEOUT
      return const LoadFailure(
        title: '连接超时',
        detail: '这条出口太慢或者不通。换一条出口，或者稍后再试。',
        retryable: true,
      );
    case -11: // ERROR_FAILED_SSL_HANDSHAKE
      return const LoadFailure(
        title: '加密握手失败',
        detail: '出口可能在中间拦了 HTTPS。换一条出口。',
        retryable: true,
      );
    case -12: // ERROR_BAD_URL
      return const LoadFailure(
        title: '地址不对',
        detail: '号码格式可能有问题（站点只认 11 位）。',
        retryable: false,
      );
    case -15: // ERROR_TOO_MANY_REQUESTS
      return const LoadFailure(
        title: '请求太频繁',
        detail: '站点在限流。等一会儿，或者换一条出口。',
        retryable: true,
      );
    case -16: // ERROR_UNSAFE_RESOURCE
      return const LoadFailure(
        title: '页面里有不安全的内容',
        detail: '站点自己的问题，换个页面看看。',
        retryable: false,
      );
    default:
      break;
  }

  // ── ③ 按内核原文猜（兜底）──────────────────────────────
  final d = description.toLowerCase();
  if (d.contains('err_name_not_resolved')) {
    return const LoadFailure(
      title: '域名解析不了',
      detail: '检查一下网络，或者换一条出口再试。',
      retryable: true,
    );
  }
  if (d.contains('err_internet_disconnected') || d.contains('offline')) {
    return const LoadFailure(
      title: '设备没联网',
      detail: '打开一下 Wi-Fi 或移动数据再试。',
      retryable: true,
    );
  }
  if (d.contains('err_connection_timed_out')) {
    return const LoadFailure(
      title: '连接超时',
      detail: '这条出口太慢或者不通。换一条出口，或者稍后再试。',
      retryable: true,
    );
  }
  if (d.contains('err_connection_refused')) {
    return const LoadFailure(
      title: '连接被拒绝',
      detail: '出口那端没在监听 —— 本地桥可能没起来。',
      retryable: true,
    );
  }
  if (d.contains('err_connection_reset') ||
      d.contains('err_connection_closed')) {
    return const LoadFailure(
      title: '连接被中断',
      detail: '这条出口不稳定。换一条试试。',
      retryable: true,
    );
  }
  if (d.contains('err_ssl') || d.contains('certificate')) {
    return const LoadFailure(
      title: '证书有问题',
      detail: '出口可能在中间拦了 HTTPS。换一条出口。',
      retryable: true,
    );
  }
  if (d.contains('err_proxy')) {
    return const LoadFailure(
      title: '代理出错',
      detail: '本地桥或上游出口有问题。换一条出口再试。',
      retryable: true,
    );
  }
  if (d.contains('err_empty_response') || d.contains('err_cache_miss')) {
    return const LoadFailure(
      title: '站点返回了空内容',
      detail: '重试一次。还不行就换一条出口。',
      retryable: true,
    );
  }

  // ── ④ 真兜底 ───────────────────────────────────────────
  //
  // 把原文带上：用户截图发过来能定位，我这边不用再猜。原文可能是
  // 英文 —— 但那是**唯一**能提供线索的东西，删掉只会让问题更难查。
  return LoadFailure(
    title: '页面加载失败',
    detail: description.isEmpty ? '没有更多信息。' : description,
    retryable: true,
  );
}
