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

  // 翻页状态。定义在这里（而不是翻页那一节）是因为 `syncPoolToPage`
  // 要用它们 —— 切号时池子和翻页状态必须一起清。
  var loadingMore = false;
  var exhausted = false; // 站点明确说没有更早的了

  /// 池子所属的号码页。切号时要靠它判断「该清了」。
  ///
  /// 站点是 SPA：点另一个号码走 `pushState` 不重载页面
  /// （live.js:1002 `history.pushState({freeussms:true},'',u.pathname+u.search)`），
  /// 所以这个注入脚本的上下文不会被重建，`pool` 会一直留着上一个号码的消息。
  /// 后果不只是「列表里混进别人的短信」—— `oldestCursor()` 取池内最小 id，
  /// 混了别的号码的 id 之后游标会偏小，翻页会跳过当前号码的一段历史。
  var poolFor = '';

  /// 当前页面属于哪个号码（取 `/numbers/<数字>/` 里的数字）。
  ///
  /// 目录页 `/numbers/` 和首页返回空串 —— 那种页面本来就不该有池子。
  function currentPhone() {
    var m = location.pathname.match(/\/numbers\/(\d{6,15})\/?/);
    return m ? m[1] : '';
  }

  /// 如果页面已经换到另一个号码，把池子和翻页状态全部清掉。
  ///
  /// 返回 true 表示刚清过（调用方据此决定要不要重新扫）。
  ///
  /// **切号时要清的东西必须在这里一次清完。** 漏一个的后果都不是「功能少一点」，
  /// 而是「把别的号码的数据当成本号的」—— 用户看不出来。
  function syncPoolToPage() {
    var now = currentPhone();
    if (now === poolFor) return false;
    poolFor = now;
    pool = {};
    // 翻页状态必须跟着池子一起清 —— 否则新号码第一页就显示「没有更早的消息」。
    exhausted = false;
    // 号码 id 的缓存也要失效：它记着「属于哪个号码」，换号了就不再可信。
    // 不清的话翻页会带着旧号码的 id 去请求，拉回来的是别的号的短信。
    numberId = '';
    numberIdFor = '';
    // 扫描停摆标志也要复位：扫到消息后 `stopped` 会永久为真，
    // 而新号码若首屏是服务端直出（没有接口请求），就只能靠 DOM 扫描。
    // 不复位的话新号码一条都拿不到。
    stopped = false;
    scanDelay = DENSE_GAP;
    scanCount = 0;
    return true;
  }

  // 上限。和 Dart 侧保持一致 —— 两边都限流，谁先到都不至于爆。
  var MAX = 240;

  /// 站点的「客户端渲染上限」，用来对齐它算「还有没有下一页」的语义。
  ///
  /// live.js:83 `let messageSize=matchMedia('(max-width:760px)').matches?20:50,...`
  /// 手机（窄屏）是 20，桌面是 50。App 的 WebView 恒为手机宽度，所以取 20。
  var kRenderCap = 20;

  function put(msg) {
    if (!msg || !msg.id) return false;
    syncPoolToPage();
    var old = pool[msg.id];
    if (!old) {
      pool[msg.id] = msg;
      return true;
    }
    // 新帧非空就覆盖，否则保留旧值。规则和 Dart 侧 `mergeWith` 完全一致 ——
    // 两处不一致的话，「DOM 先扫到残缺版、接口后给完整版」这条最常见的
    // 路径就会丢掉正文。
    //
    // `protected` 用「真值粘住」（`old.protected || msg.protected`），
    // 和 Dart 侧 `mergeWith` 同一条规则：DOM 路径靠「页面上有没有那句说明」
    // 反推，说明还没渲染出来时会给出 false，不该拿它抹掉接口帧的 true。
    pool[msg.id] = {
      id: msg.id,
      text: msg.text || old.text || '',
      code: msg.code || old.code || '',
      sender: msg.sender || old.sender || '',
      time: msg.time || old.time || '',
      phone: msg.phone || old.phone || '',
      protected: old.protected === true || msg.protected === true,
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

  // 消息卡片的容器。
  //
  // 站点自己渲染的消息卡片是 `article.sms-message[data-event-id]`
  //   live.js:541 `const card=el('article','sms-message');card.dataset.eventId=String(m.event_id);`
  //
  // 只认这一个选择器。原来还列了 `[data-message-id]` / `.message-item` /
  // `.sms-item` 三个候选，那三个在站点 JS 里一处都不存在（rg 全仓 0 命中），
  // 留着只会让「改版了」这件事被一个永远为空的候选掩盖住。
  var ROW_SELECTOR = 'article.sms-message[data-event-id]';

  function rowEls() {
    var found = document.querySelectorAll(ROW_SELECTOR);
    return found.length ? found : null;
  }

  function textOf(el, sel) {
    if (!el) return '';
    var n = el.querySelector(sel);
    return n ? (n.textContent || '').trim() : '';
  }

  /// 从卡片里读一条消息。
  ///
  /// 字段名全部对着站点 `messageCard()` 的真实产物写。下面每条都附
  /// `live.js` 的行号，**引用可被 `awk 'NR==N' live.js` 直接验到**。
  ///   - 发送方：`.sms-message-top .message-origin h3`
  ///     live.js:543 `const top=el('div','sms-message-top'),who=el('div','message-origin');who.append(el('span','message-label','From'),el('h3','',m.sender||'Unknown sender'));`
  ///   - 时间：`.sms-message-top time[datetime]`
  ///     live.js:544 `time.dateTime=d.toISOString()`
  ///     注意站点写进去的是 DOM 属性 `datetime`，不是 `data-time`。
  ///   - 正文：`p.live-message-body`
  ///     live.js:546 `card.append(el('p','live-message-body',m.content||''));`
  ///   - 验证码：读 `button.code-chip` 上的 `data-live-copy`
  ///     live.js:551 `button.dataset.liveCopy=m.copy_code;`
  ///     属性里就是验证码本身，所以正常情况下走属性分支。
  ///     `data-code-copy` 在同一行被赋成**空串**（`button.dataset.codeCopy='';`），
  ///     读它等于永远拿不到验证码 —— 原来那版就是这么错的。
  ///     属性读不到时才退回按钮内第一个 `<span>` 的文本
  ///     （live.js:552 `button.append(el('span','',m.copy_code),...)`）。
  ///   - 受保护：站点**没有** `data-protected` 属性，也没有 `.protected` 类
  ///     （`rg -c 'data-protected' live.js` = 0）。它靠的是
  ///     live.js:549 `if(m.protected)actions.append(el('span','message-label','Message temporarily unavailable. Please refresh the inbox.'));`
  ///     所以只能从「正文为空 + 存在那条说明」反推。
  function readRow(el) {
    // 编号直接取。选择器是 `article.sms-message[data-event-id]`（属性存在
    // 才匹配），而站点赋值是 live.js:541 `card.dataset.eventId=String(m.event_id);`
    // —— 所以这里必然拿得到非空串，不需要兜底。
    //
    // 原来有一条「没有编号就用内容哈希造一个」的分支，那是死代码：
    // 属性存在性选择器保证了 getAttribute 不会返回空。
    var id = el.getAttribute('data-event-id');
    if (!id) return null;

    var text = textOf(el, 'p.live-message-body');

    // 验证码：先读按钮上的 `data-live-copy`（那是站点用来复制的真值），
    // 再退回按钮里第一个 `<span>` 的文本。
    var chip = el.querySelector('button.code-chip');
    var code = '';
    if (chip) {
      code = (chip.getAttribute('data-live-copy') || '').trim();
      if (!code) {
        var codeSpan = chip.querySelector('span');
        code = codeSpan ? (codeSpan.textContent || '').trim() : '';
      }
    }

    // 时间：站点写的是 `<time datetime="ISO">`。
    var timeEl = el.querySelector('.sms-message-top time');
    var time = '';
    if (timeEl) {
      time = (timeEl.getAttribute('datetime') || '').trim();
      if (!time) time = (timeEl.textContent || '').trim();
    }

    // 受保护：只认那条固定说明 span，**不要求正文为空**。
    //
    // 原来写成「正文为空 + 有说明」，前提是「受保护 ⇒ 正文为空」。这个前提
    // 站点并不保证：live.js:546 `card.append(el('p','live-message-body',m.content||''));`
    // 是无条件渲染，`rg -n "content\s*[:=]\s*''" live.js` 零命中 —— 站点从不清空正文。
    // 更硬的反证是站点自己判断「这条有没有正文」时得额外排除 protected：
    // live.js:69 `nonempty:items.some(item=>typeof item.content==='string'&&item.content.trim()&&!item.protected)`
    // —— 正文非空与 protected 可以同时成立，否则那个 `!item.protected` 是多余的。
    //
    // 所以判据改成「只看说明 span 在不在」。说明 span 只在 protected 时追加
    // （live.js:549），它出现就说明是受保护，与正文是否为空无关。
    var protectedFlag = false;
    var labels = el.querySelectorAll('.message-actions .message-label');
    for (var i = 0; i < labels.length; i++) {
      if (/temporarily unavailable/i.test(labels[i].textContent || '')) {
        protectedFlag = true;
        break;
      }
    }

    return {
      id: id,
      text: text,
      code: code,
      sender: textOf(el, '.sms-message-top .message-origin h3'),
      time: time,
      // 单个号码的收件页不显示接收号码（页面本身就是那个号），
      // 所以这里是空串；界面用页面的号码补。
      phone: '',
      protected: protectedFlag,
    };
  }

  function scanDom() {
    // 切号时先把池子清掉再扫 —— 否则新号码的第一帧会和旧号码的消息混在一起。
    syncPoolToPage();
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
  // 把接口返回的一条消息转成内部形状。
  //
  // 字段名全部对着站点 `live.js` 的真实产物写，不是猜的：
  //
  //   站点真实字段                     本函数用的
  //   ------------------------------   ---------------------------
  //   `event_id`（整数）           →   `id`（转字符串，去重键）
  //   `content`                    →   `text`
  //   `copy_code`                  →   `code`
  //   `sender`                     →   `sender`
  //   `received_at`（ISO 串）      →   `time`
  //   `receiver`（`+1...` 带加号） →   `phone`
  //   `protected`（布尔）          →   `protected`
  //
  // 字段名的出处（live.js:541-549 的 `messageCard(m,feed)` 逐字读过）：
  //   `m.event_id` / `m.content` / `m.copy_code` / `m.sender` /
  //   `m.received_at` / `m.receiver` / `m.protected` / `m.number_id`
  // 卡片上的 DOM 属性名是 `data-event-id`
  //   live.js:559 `[...priorList.querySelectorAll('[data-event-id]')].map(n=>n.dataset.eventId)`
  //
  // **站点没有 `time` / `created_at` / `date` / `phone` / `number` 这几个字段。**
  // 原来那几个候选名一个都不存在，导致 time 和 phone 恒为空。
  // 保留 `event_id`→`id` 的映射而不是直接叫 `event_id`，是因为 Dart 侧
  // `frame.dart` 与 `merge_frame.dart` 用 `id` 做去重键，改名要动两边。
  function normApiItem(e) {
    if (!e) return null;
    var id = e.event_id != null ? e.event_id : e.id;
    if (id == null || id === '') return null;
    return {
      id: String(id),
      text: e.content || e.text || '',
      code: e.copy_code || e.code || '',
      sender: e.sender || '',
      time: e.received_at || '',
      phone: e.receiver || '',
      protected: e.protected === true,
    };
  }

  // 把接口返回的 JSON 拆成消息。
  //
  // 外层键：站点给的是 `{items:[...], has_more:bool, server_time_ms, code_policy}`
  //   live.js:115 `function applyMessageBatch(batch,...)` 里逐字用
  //   `batch.items.slice(...)` / `!!batch.has_more` / `batch.code_policy`
  //   live.js:134 `Number.isFinite(batch.server_time_ms)` —— server_time_ms 在 134 行，不在 115
  // `messages` / `data` 两个候选留着做降级 —— 站点改版时至少不会一条都拿不到。
  // 把接口返回的 JSON 拆成消息。
  //
  // 返回值语义：**「这批里有没有消息」**，不是「有没有新消息」。
  // 原来写 `return ingestItems(raw) > 0`，而 `put()` 只在新 id 时才返回 true，
  // 所以同一批消息第二次到达（站点轮询会重发同一批）时返回 false，
  // 调用方据此弹出「接口回来了，但里面没有消息」—— 消息明明拿到了。
  function ingestJson(json) {
    var raw = apiItems(json);
    if (!raw || !raw.length) return false;
    ingestItems(raw);
    return true;
  }

  /// 从响应 JSON 里取消息数组。
  ///
  /// 单独一个函数是因为有两处要用（首次挂钩、翻页），两处写两份候选列表
  /// 迟早会漂 —— 一处加了 `data`、另一处忘了加。
  function apiItems(json) {
    if (!json) return null;
    return json.items || json.messages || json.data || null;
  }

  /// 把一批消息装进池子，返回新增了几条。
  function ingestItems(raw) {
    var added = 0;
    for (var i = 0; i < raw.length; i++) {
      var n = normApiItem(raw[i]);
      if (n && put(n)) added++;
    }
    return added;
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
  //
  // 站点把「当前号码」写在一段内嵌 JSON 里，它自己就是这么读的：
  //   live.js:26 `boot=JSON.parse(q('#fus-bootstrap')?.textContent||'{}')`
  // 那段 JSON 的形状（实测抓到的收件页原文）：
  //   {"phone":"14044225634","selected":{"id":"f0f55f...","number":"+14044225634",...}}
  // 所以 `selected.id` 就是号码 id，`phone` 就是当前号码 —— 两个都在同一个地方，
  // 一起读能保证「id 和号码」永远是同一对，不会像从请求 URL 里抄那样抄到别的号的。
  //
  // 站点**没有** `data-number-id` 属性（`rg -c 'data-number-id' live.js` = 0，
  // 收件页 HTML 里也 0 命中），原来那条兜底是死的。

  /// 从页面内嵌 JSON 读当前号码信息。返回 `{phone, id}`，读不到给空串。
  ///
  /// **每次都重新读**，不缓存 —— 站点切号走 `pushState` 不重载页面
  /// （live.js:1002 `if(push)history.pushState(...)`），但服务端渲染的那段
  /// JSON 不会跟着变。所以切号之后这段 JSON 是旧的，不能当唯一来源：
  /// 见下面 `resolveNumberId` 的处理顺序。
  function readBootstrap() {
    var out = { phone: '', id: '' };
    try {
      var node = document.querySelector('#fus-bootstrap');
      if (!node) return out;
      var data = JSON.parse(node.textContent || '{}');
      out.phone = (data && data.phone) || '';
      var sel = data && data.selected;
      if (sel && /^[0-9a-f]{32}$/i.test(sel.id || '')) out.id = sel.id;
    } catch (e) {
      // 解析失败就当没有 —— 下面还有别的来源。
    }
    return out;
  }

  /// 从站点的请求 URL 里抄号码 id。
  ///
  /// 返回抄到的 id，没有就返回空串。**不写全局缓存** —— 缓存由调用方管，
  /// 而且必须跟着号码一起换。
  function idFromUrl(url) {
    var s = String(url);
    var m = s.match(/[?&]id=([0-9a-f]{32})/i) ||
            s.match(/\/numbers?\/([0-9a-f]{32})/i);
    return m ? m[1] : '';
  }

  // 最近一次抄到的 id，以及它属于哪个号码。切号时 `syncPoolToPage` 会清掉。
  var numberId = '';
  var numberIdFor = '';

  function captureNumberId(url) {
    var id = idFromUrl(url);
    if (!id) return;
    // **不能「有值就跳过」** —— 站点切号后脚本上下文不重建，
    // 原来那句 `if (numberId) return;` 会让翻页一直打到旧号码的 id，
    // 拉回来的是**上一个号码**的短信。
    numberId = id;
    numberIdFor = poolFor;
  }

  /// 拿到当前号码的 id。
  ///
  /// 优先级（每一级都要能解释「为什么它更可信」）：
  ///   1. 缓存里那个 id，**但必须属于当前号码**（`numberIdFor === poolFor`）
  ///   2. 页面内嵌 JSON 的 `selected.id`，**且它的 phone 和当前号码一致**
  ///   3. 从最近一次站点请求 URL 里抄（这条最不可靠，只在前两条都不成立时用）
  function resolveNumberId() {
    // ① 缓存属于当前号码才认。
    if (numberId && numberIdFor === poolFor) return numberId;

    // ② 内嵌 JSON。它的 phone 必须和地址栏里的号码一致 ——
    //    不一致说明这段 JSON 是切号之前渲染的，已经过期了。
    var boot = readBootstrap();
    if (boot.id && boot.phone && boot.phone === poolFor) {
      numberId = boot.id;
      numberIdFor = poolFor;
      return boot.id;
    }

    // ③ 缓存里的 id 虽然不属于当前号码，但至少是个真 id —— 不用它。
    //    返回空串让调用方报错，比发一个错号码的请求好：
    //    那种失败用户看不出来（列表照样往下接，只是内容属于别的号）。
    return '';
  }

  // ── 游标 ────────────────────────────────────────────────

  // 翻页游标是**最早那条的 event_id 整数**，不是时间。
  //
  // 站点自己发 `before` 的两处，原文：
  //   live.js:1062 `const before=direction==='older'?items.at(-1)?.event_id:...`
  //   live.js:141  `const cursor=Number(items[0].event_id)+1;`
  // 两处都拿 event_id 当数值用（`+1`、`>` 比较），全文件搜不到任何
  // 拿时间戳当 `before` 的写法。
  //
  // 原来这里取的是 `pool[k].time`（ISO 串），所以发出去的是
  // `&before=2026-10-30T...` —— 类型就和站点对不上，翻页必然失败。
  //
  // **不能取数组最后一项** —— 池子是按 id 存的，顺序不保证新→旧。
  // 取所有 id 里最小的那个，与顺序无关。
  function oldestCursor() {
    var min = 0;
    for (var k in pool) {
      if (!Object.prototype.hasOwnProperty.call(pool, k)) continue;
      var raw = pool[k] && pool[k].id;
      // id 现在是纯数字串（站点 `String(m.event_id)`），但保留这道
      // 数值校验：万一以后有人加回非数字来源，游标会变成 NaN，
      // 而 `&before=NaN` 是比「没有游标」更难查的失败。
      var n = Number(raw);
      if (!isFinite(n) || n <= 0) continue;
      if (min === 0 || n < min) min = n;
    }
    return min;
  }

  // ── 翻页 ────────────────────────────────────────────────

  function loadMore() {
    // 切号后第一次翻页也要先把池子同步过来，否则游标会取到旧号码的 id。
    syncPoolToPage();
    if (loadingMore) {
      // **正在拉**和**已到底**是两件事，不能回同一个帧。
      //
      // 原来两者都回 `moreDone{empty:true}`，而 `empty:true` 在 Dart 侧是
      // 「到底了」—— 于是「用户滑到底时手抖再触发一次」这个常见时序
      // 会把 hasMore 永久置假：
      //   ① 上一次请求还在飞（loadingMore=true）
      //   ② Dart 侧刚收到 moreDone 清了 loadingMore，滚动监听又触发一次
      //   ③ 这里走 loadingMore 分支 → 发 empty:true → Dart 认为到底了
      // 之后整轮会话翻页关闭，界面显示「没有更早的消息了」。
      //
      // 现在只回一句「正在拉」，不动 hasMore。
      status('正在加载更早的消息…');
      return;
    }
    if (exhausted) {
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
        var raw = apiItems(json);
        if (!raw || !raw.length) {
          // 空批不等于到底 —— 站点可能给了空页但 `has_more` 仍为真
          // （游标落在边界、活消息窗口滚动）。所以这里也要读 has_more。
          exhausted = json && json.has_more !== true;
          post({ type: 'moreDone', empty: exhausted });
          return;
        }

        // **「还有没有更早的」按站点自己的式子算，不能只取一半。**
        //
        // 站点原式（live.js:115）：
        //   `more=!!batch.has_more||batch.items.length>next.length`
        // 其中 `next=batch.items.slice(0,messageSize)`，`messageSize` 是
        // **客户端渲染上限**（手机 20 / 桌面 50，live.js:83）：
        //   `let messageSize=matchMedia('(max-width:760px)').matches?20:50,...`
        //
        // 也就是说站点认为「还有更多」= `has_more` 为真 **或** 本批条数
        // 超过渲染上限（说明服务端手里还有没给完的）。
        //
        // 我上一版只取了 `has_more === true`，比站点**更严**：
        // 当 `has_more:false` 而本批条数超过上限时，站点会继续翻，
        // 我会直接判到底 → 漏页。
        //
        // App 不做渲染截断（整批都收），所以用同一个上限常量对齐站点的语义。
        var rendered = raw.length > kRenderCap ? kRenderCap : raw.length;
        var hasMore = json.has_more === true || raw.length > rendered;

        var added = ingestItems(raw);
        exhausted = !hasMore;
        // `added` 必须用上：全是重复消息时界面会「什么都没发生」，
        // 用户以为按钮没响应。说一句「这一页没有更早的新消息」比静默好。
        if (added === 0 && !exhausted) status('这一页没有更早的新消息，再点一次试试');
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
      // **翻页状态必须一起重置。**
      //
      // `exhausted` 只有「站点给了 has_more:false」和这里两处置真。
      // 前者是站点真值，一般不会错；但用户主动点刷新，语义就是
      // 「重新来过」，所以这里清零是对的 —— 万一之前判错了还能救回来。
      exhausted = false;
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
