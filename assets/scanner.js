// 站点页面的抓取层。
//
// ## 它做什么
//
// 注入到 freeussms.com 的每个页面里，把「页面上有什么短信」告诉 App。
// 数据有两个来源，两个都要用：
//
//   1. **接口响应**（挂在 fetch 上）—— 字段完整、有时间戳。但只在站点
//      自己发请求时才有。
//   2. **DOM 扫描** —— 任何时刻都能扫，但字段可能残缺（正文被折叠、
//      受保护的行没有时间）。
//
// 两者产出的东西走同一条出口（post），由 Dart 侧按 id 去重合并。所以
// 这里**不需要**判断「接口有没有给过」—— 重复投递是正常的，合并是 Dart
// 的事。这条分工很重要：抓取层只管「看到什么说什么」。
//
// ## 通信
//
// 只有一个通道：`flutter_inappwebview.callHandler`。发出去的都是
// JSON 字符串，形状见 `lib2/data/frame.dart` 的注释。
//
// ## 为什么不缓存已发出的内容
//
// Dart 侧按 id 去重，这里再去重一次只会让「同一条消息补上了新字段」这种
// 情况发不出去 —— 而那恰恰是需要的（正文分批抵达）。

(function () {
  if (window.__fusScanner) return; // 重复注入直接退出
  window.__fusScanner = true;

  'use strict';

  // ── 发帧 ────────────────────────────────────────────────

  function post(obj) {
    try {
      var bridge = window.flutter_inappwebview;
      if (bridge && bridge.callHandler) {
        bridge.callHandler('FusInbox', JSON.stringify(obj));
      }
    } catch (e) {
      // 发不出去就算了 —— 抓取层不该因为通道异常而中断。
      // 不在这里重试：通道不通是宿主的问题，重试只会堆积。
    }
  }

  // ── 消息池 ──────────────────────────────────────────────

  // id -> 消息。用对象而不是数组：同一 id 的新帧要**合并**而不是追加。
  var pool = {};

  // 上限。和 Dart 侧保持一致 —— 两边都限流，谁先到都不至于爆。
  var MAX = 240;

  function put(msg) {
    if (!msg || !msg.id) return false;
    var old = pool[msg.id];
    if (!old) {
      pool[msg.id] = msg;
      return true;
    }
    // 新帧非空就覆盖，否则保留旧值。规则和 Dart 侧 `mergeWith` 完全一致 ——
    // 两处不一致的话，「DOM 先扫到残缺版、接口后给完整版」这条最常见的
    // 路径就会丢掉正文。
    pool[msg.id] = {
      id: msg.id,
      text: msg.text || old.text || '',
      code: msg.code || old.code || '',
      sender: msg.sender || old.sender || '',
      time: msg.time || old.time || '',
      phone: msg.phone || old.phone || '',
      protected: msg.protected === true,
    };
    return false;
  }

  function all() {
    var out = [];
    for (var k in pool) {
      if (Object.prototype.hasOwnProperty.call(pool, k)) out.push(pool[k]);
    }
    return out;
  }

  function trim() {
    var list = all();
    if (list.length <= MAX) return list;
    // 超出就裁 —— **按时间倒序取前 MAX 条**。
    // 不裁的话长时间挂着会吃满内存（页面上的短信一直在增加）。
    list.sort(function (a, b) {
      return String(b.time || '').localeCompare(String(a.time || ''));
    });
    pool = {};
    for (var i = 0; i < MAX; i++) pool[list[i].id] = list[i];
    return all();
  }

  // ── 上报 ────────────────────────────────────────────────

  var hits = 0; // 截获到几次接口响应
  var lastKey = ''; // 上一次发的内容指纹，用来去重

  function push(force) {
    var list = trim();
    // 指纹把 hits 也算进去：只比 messages 的话，「消息没变但 hits 从 0
    // 涨到 1」这种帧会被丢掉，而界面正是靠 hits 判断挂钩有没有生效。
    var key = JSON.stringify([list, hits]);
    if (!force && key === lastKey) return;
    lastKey = key;
    post({ type: 'messages', items: list, hits: hits, src: 'scan' });
  }

  function status(text) {
    post({ type: 'status', text: text });
  }

  // ── 从 DOM 抄一条消息 ──────────────────────────────────

  // 站点的消息容器。多个候选：站点改版过几次，老结构可能还在某些页面
  // 上出现。
  var ROW_SELECTORS = [
    '[data-event-id]',
    '[data-message-id]',
    '.message-item',
    '.sms-item',
  ];

  function rowEls() {
    for (var i = 0; i < ROW_SELECTORS.length; i++) {
      var found = document.querySelectorAll(ROW_SELECTORS[i]);
      if (found.length) return found;
    }
    return null;
  }

  function textOf(el, sel) {
    if (!el) return '';
    var n = el.querySelector(sel);
    return n ? (n.textContent || '').trim() : '';
  }

  function readRow(el) {
    var id =
      el.getAttribute('data-event-id') ||
      el.getAttribute('data-message-id') ||
      '';
    if (!id) {
      // 没有 id 的行没法去重 —— 拼一个稳定的（基于内容哈希的简化版）。
      // 用下标不行：列表会重排。
      var t = (el.textContent || '').trim();
      if (!t) return null;
      id = 'h' + hash(t);
    }
    return {
      id: id,
      text: textOf(el, '.message-text, .sms-text, .body, p') || '',
      code: el.getAttribute('data-copy-code') || '',
      sender: textOf(el, '.sender, .from, .title') || '',
      time: el.getAttribute('data-time') || textOf(el, '.time, .date') || '',
      phone: textOf(el, '.phone, .number') || '',
      protected: el.classList.contains('protected') ||
        el.getAttribute('data-protected') === '1',
    };
  }

  // 字符串哈希。只用来给「没有 id 的行」造一个稳定的 id，
  // 不需要抗碰撞 —— 撞了也只是两条消息合并，可接受。
  function hash(s) {
    var h = 5381;
    for (var i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0;
    return (h >>> 0).toString(36);
  }

  function scanDom() {
    var rows = rowEls();
    if (!rows || !rows.length) return 0;
    var added = 0;
    for (var i = 0; i < rows.length; i++) {
      var m = readRow(rows[i]);
      if (m && put(m)) added++;
    }
    return added;
  }

  // ── 接口挂钩 ────────────────────────────────────────────

  // 站点把收件箱数据放在 `/sms-api/` 下。别的请求（埋点、广告）不碰。
  var API_PATH = '/sms-api/';

  function isApi(u) {
    return typeof u === 'string' && u.indexOf(API_PATH) >= 0;
  }

  // 把接口返回的 JSON 拆成消息。
  //
  // 字段名不固定：站点用过 `items` / `messages` / `data` 三种外层键，
  // 单条里的正文键也换过。所以逐个候选试，而不是认死一个。
  function ingestJson(json) {
    if (!json) return false;
    var raw = json.items || json.messages || json.data;
    if (!raw || !raw.length) return false;

    var added = 0;
    for (var i = 0; i < raw.length; i++) {
      var e = raw[i];
      if (!e) continue;
      var id = e.id || e.event_id || e.msg_id || '';
      if (!id) continue;
      if (put({
        id: String(id),
        text: e.text || e.body || e.content || '',
        code: e.copy_code || e.code || '',
        sender: e.sender || e.from || e.title || '',
        time: e.time || e.created_at || e.date || '',
        phone: e.phone || e.number || '',
        protected: e.protected === true,
      })) added++;
    }
    return added > 0;
  }

  // 读响应头，判断站点是不是在拒绝我们。
  //
  // 站点用 `X-Fair-Use` 区分三种拒绝：
  //   pause       → 配额用完
  //   challenge   → 要过人机验证
  //   unavailable → 临时繁忙
  function readHold(res) {
    try {
      var marker = res.headers && res.headers.get('X-Fair-Use');
      if (!marker) return null;
      var retry = parseInt(res.headers.get('Retry-After') || '', 10);
      return { kind: marker, retry: isFinite(retry) ? retry : 0 };
    } catch (e) {
      return null;
    }
  }

  function hookFetch() {
    var orig = window.fetch;
    if (!orig || orig.__fus) return;

    var wrapped = function (input, init) {
      var url = typeof input === 'string' ? input : (input && input.url) || '';
      // 先抄号码 id —— 首屏那次请求一定带，抄到就不必猜。
      if (isApi(url)) captureNumberId(url);
      var p = orig.apply(this, arguments);
      if (!isApi(url)) return p;

      p.then(function (res) {
        hits++;
        var hold = readHold(res);
        if (hold) {
          post({
            type: 'holdup',
            kind: hold.kind,
            retry: hold.retry,
            title: '',
            message: '',
          });
          // 被拒时响应体里没有消息，不必读。
          return;
        }
        // 成功了 —— 清掉 hold（站点又开始给了）。
        post({ type: 'holdup', kind: '' });
        res
          .clone()
          .json()
          .then(function (json) {
            if (ingestJson(json)) push(true);
            else status('接口回来了，但里面没有消息');
          })
          .catch(function () {
            // 不是 JSON（HTML 挑战页之类）—— 不是错误，只是抓不到。
          });
      }).catch(function () {
        // 请求本身失败。不报错 —— 页面自己的错误处理会显示出来。
      });

      return p;
    };
    wrapped.__fus = true;
    window.fetch = wrapped;
  }

  // ── 号码 id ─────────────────────────────────────────────

  // inbox 接口要的是 32 位 hex 的号码 id，而页面 URL 里只有电话号码。
  // 从站点自己的 /sms-api/ 请求 URL 里抄 —— 首屏那次一定带，抄到就不用猜。
  var numberId = '';

  function captureNumberId(url) {
    if (numberId) return;
    var s = String(url);
    var m = s.match(/[?&]id=([0-9a-f]{32})/i) ||
            s.match(/\/numbers?\/([0-9a-f]{32})/i);
    if (m) numberId = m[1];
  }

  // 抄不到时的退路：页面里的 data 属性、或内联脚本里的常量。
  function resolveNumberId() {
    if (numberId) return numberId;
    var el = document.querySelector('[data-number-id]');
    if (el) {
      var v = el.getAttribute('data-number-id');
      if (v && /^[0-9a-f]{32}$/i.test(v)) return v;
    }
    try {
      var html = document.documentElement.innerHTML;
      var m = html.match(/data-number-id="([0-9a-f]{32})"/i) ||
              html.match(/"number_id"\s*:\s*"([0-9a-f]{32})"/i);
      if (m) return m[1];
    } catch (e) {
      // innerHTML 在某些内核上可能抛（页面太大）。抄不到就算了。
    }
    return '';
  }

  // ── 游标 ────────────────────────────────────────────────

  // 「最早那一条」的时间，就是游标。
  //
  // **不能取数组最后一项** —— 池子是按 id 存的，顺序不保证新→旧。
  // 取所有时间里最小的，与顺序无关。ISO 8601 字符串可以直接字典序比较
  // （这也是抓取层坚持不改写时间格式的原因）。
  function oldestCursor() {
    var min = '';
    for (var k in pool) {
      if (!Object.prototype.hasOwnProperty.call(pool, k)) continue;
      var t = pool[k] && pool[k].time;
      if (!t) continue;
      if (!min || t < min) min = t;
    }
    return min;
  }

  // ── 翻页 ────────────────────────────────────────────────

  var loadingMore = false;
  var exhausted = false; // 站点明确说没有更早的了
  var pageSize = 0; // 首屏每页条数，用来判断「这页是不是最后一页」

  function loadMore() {
    if (loadingMore || exhausted) {
      // 已经在拉、或已经到底 —— 也要回一声。
      // 不回的话 Dart 侧已经把 loadingMore 置真，会一直转圈。
      post({ type: 'moreDone', empty: true });
      return;
    }
    var cursor = oldestCursor();
    if (!cursor) {
      post({ type: 'moreFail', reason: 'no_cursor' });
      return;
    }
    var numId = resolveNumberId();
    if (!numId) {
      status('还拿不到号码 id，等页面加载完再试');
      post({ type: 'moreFail', reason: 'no_id' });
      return;
    }

    loadingMore = true;
    status('正在加载更早的消息…');

    var url = '/sms-api/v1/inbox?id=' + encodeURIComponent(numId) +
              '&before=' + encodeURIComponent(cursor);

    // 借用站点自己的签名入口。没有它就直接 fetch —— 会 401，
    // 但至少把失败原因如实报上去，而不是静默卡住。
    var send = (window.FUSReader && window.FUSReader.fetch)
      ? function (u) { return window.FUSReader.fetch(u, {}); }
      : function (u) { return fetch(u, { credentials: 'same-origin' }); };

    send(url)
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then(function (json) {
        var raw = json && (json.items || json.messages || json.data);
        if (!raw || !raw.length) {
          exhausted = true;
          post({ type: 'moreDone', empty: true });
          return;
        }
        // 「一页给不满 = 到底了」的基准必须是**接口返回的条数**。
        // 用池子大小当基准的话：DOM 扫了 60 条、接口返回 24，
        // 24 < 60 会被误判成最后一页。
        if (!pageSize) pageSize = raw.length;

        var added = 0;
        for (var i = 0; i < raw.length; i++) {
          var n = normApiItem(raw[i]);
          if (n && put(n)) added++;
        }
        if (raw.length < pageSize) exhausted = true;
        push(true);
        post({ type: 'moreDone', empty: exhausted });
      })
      .catch(function (e) {
        var why = String((e && e.message) || e);
        status('加载更早消息失败：' + why);
        post({ type: 'moreFail', reason: why });
      })
      .then(function () {
        loadingMore = false;
      });
  }

  // 接口单条 → 内部形状。字段名不固定，逐个候选试。
  function normApiItem(e) {
    if (!e) return null;
    var id = e.id || e.event_id || e.msg_id || '';
    if (!id) return null;
    return {
      id: String(id),
      text: e.text || e.body || e.content || '',
      code: e.copy_code || e.code || '',
      sender: e.sender || e.from || e.title || '',
      time: e.time || e.created_at || e.date || '',
      phone: e.phone || e.number || '',
      protected: e.protected === true,
    };
  }

  // ── 启动 ────────────────────────────────────────────────

  // 自适应节奏扫描。
  //
  // 站点从加载到渲染出第一条消息，实测 300ms ~ 4s。固定间隔要么太密
  // （空转烧 CPU）要么太疏（用户等太久）。所以：前几次密集试，
  // 之后退避，**一旦扫到就停**。
  var DENSE_GAP = 250;
  var DENSE_COUNT = 6;
  var scanDelay = DENSE_GAP;
  var scanCount = 0;
  var scanTimer = null;
  var stopped = false;

  function scheduleScan() {
    if (stopped) return;
    if (scanTimer) clearTimeout(scanTimer);
    scanTimer = setTimeout(function () {
      scanTimer = null;
      if (stopped) return;
      if (scanDom()) push(true);
      if (all().length) {
        stopped = true;
        return;
      }
      scanCount++;
      if (scanCount >= DENSE_COUNT) {
        scanDelay = Math.min(Math.round(scanDelay * 1.8), 4000);
      }
      scheduleScan();
    }, scanDelay);
  }

  function start() {
    hookFetch();
    status('抓取层已就绪');
    scheduleScan();

    // DOM 变动时补扫。
    //
    // 站点有广告轮播和倒计时，DOM 一直在变。不节流的话一天几万次全页
    // 遍历 —— 手机发烫。冷却 3 秒，且只在还没消息时扫。
    try {
      var mo = new MutationObserver(function () {
        if (all().length || stopped) return;
        clearTimeout(mo.__t);
        mo.__t = setTimeout(function () {
          if (scanDom()) push(true);
        }, 3000);
      });
      mo.observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) {
      // 内核不支持就不装 —— 上面的定时扫描已经能兜住。
    }

    // 兜底轮询：一直没数据时每 10 秒试一次。扫到就停。
    var tick = setInterval(function () {
      if (all().length || stopped) {
        clearInterval(tick);
        return;
      }
      if (scanDom()) push(true);
    }, 10000);
  }

  // 暴露给 Dart 的入口。翻页由 Dart 调。
  window.__fusScannerApi = {
    // 重扫 + 上报。用户点「刷新」时用。
    rescan: function () {
      scanDom();
      push(true);
    },
    // 往更早的消息拉一页。Dart 侧滑到底时调。
    loadMore: loadMore,
    // 池里现在有几条。排查用。
    count: function () {
      return all().length;
    },
  };

  // 页面可能在 injection 时还没建好 document。
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
