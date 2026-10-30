// 用假的 indexedDB 跑**真实**的 `_wipeBody`，验清库脚本的语义。
//
// 为什么需要它：`_wipeBody` 是写在 Dart 里的 JS 字符串，Dart 测试跑不了
// 它。只做字符串搜索（比如「检查有没有 `out.db = true`」）证明不了
// 任何行为 —— 那只能证明那行字还在。
//
// 用法：
//   node tool/wipe_harness.js
// 退出码非 0 = 有断言没过。

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const src = fs.readFileSync(
  path.join(__dirname, '..', 'lib', 'platform', 'site_wipe.dart'),
  'utf8',
);

// 从 Dart 源码里把脚本体抠出来。抠不到就是脚本结构变了，直接失败。
const m = src.match(/const _wipeBody = r'''([\s\S]*?)''';/);
if (!m) {
  console.error('找不到 _wipeBody 字面量 —— 脚本结构变了，改这个工具');
  process.exit(1);
}
const body = m[1]
  .replaceAll('%DB%', 'fus-reader-v1')
  .replaceAll('%GRANT%', 'fus:reader:v1');

// 假 indexedDB。
//   dbs      : 现存的库名
//   blocked  : 这些库名会进 onblocked（有连接开着）
function makeIdb({ dbs = [], blocked = [] } = {}) {
  const live = new Set(dbs);
  return {
    deleteDatabase(name) {
      const req = { onsuccess: null, onerror: null, onblocked: null };
      setTimeout(() => {
        if (blocked.includes(name)) {
          req.onblocked && req.onblocked();
          return;
        }
        live.delete(name);
        req.onsuccess && req.onsuccess();
      }, 0);
      return req;
    },
    databases: async () => Array.from(live).map((n) => ({ name: n })),
  };
}

// `callAsyncJavaScript` 会把 functionBody 包成 async function，所以这里
// 也包一层 —— 和真实运行时的形状一致。
function run(idb) {
  const ctx = {
    indexedDB: idb,
    localStorage: { removeItem() {} },
    sessionStorage: { clear() {} },
    setTimeout,
    Promise,
  };
  vm.createContext(ctx);
  return vm.runInContext(`(async () => { ${body} })()`, ctx);
}

let failed = 0;
function check(label, cond) {
  if (cond) {
    console.log(`  PASS  ${label}`);
  } else {
    console.log(`  FAIL  ${label}`);
    failed++;
  }
}

(async () => {
  // ① 主库被 blocked、无关库删成功。
  //
  // 这条最要紧：`out.db` 必须是**主库**的状态，不能被「顺手删掉的
  // 别的库」置成 true。否则排查时看到 `db:true` 会以为密钥没了。
  const r1 = await run(makeIdb({
    dbs: ['fus-reader-v1', 'unrelated'],
    blocked: ['fus-reader-v1'],
  }));
  console.log('① 主库 blocked + 他库成功:', JSON.stringify(r1));
  check('db 为 false（主库没删掉）', r1.db === false);
  check('blocked 为 true', r1.blocked === true);
  check('ls 仍为 true（凭证照删）', r1.ls === true);

  // ② 主库删成功、无关库被 blocked。db 该是 true，blocked 也该是 true。
  const r2 = await run(makeIdb({
    dbs: ['fus-reader-v1', 'unrelated'],
    blocked: ['unrelated'],
  }));
  console.log('② 主库成功 + 他库 blocked:', JSON.stringify(r2));
  check('db 为 true', r2.db === true);
  check('blocked 为 true（有库没删掉）', r2.blocked === true);

  // ③ 全干净。
  const r3 = await run(makeIdb({ dbs: ['fus-reader-v1'] }));
  console.log('③ 全干净:', JSON.stringify(r3));
  check('db true', r3.db === true);
  check('blocked false', r3.blocked === false);

  // ④ 主库本来就不在。`deleteDatabase` 对不存在的库也回调 onsuccess，
  //    这是规范行为 —— 该算成功。
  const r4 = await run(makeIdb({ dbs: [] }));
  console.log('④ 主库不存在:', JSON.stringify(r4));
  check('db true（不存在的库算删成功）', r4.db === true);

  // ⑤ 老内核没有 `indexedDB.databases()`。不能抛，主库照样要删。
  const idb5 = makeIdb({ dbs: ['fus-reader-v1'] });
  delete idb5.databases;
  const r5 = await run(idb5);
  console.log('⑤ 无 databases():', JSON.stringify(r5));
  check('db true', r5.db === true);

  // ⑥ onblocked 会重试一次（300ms 后），第二次成功就算删掉了。
  //    站点自己的连接可能刚好在这一刻关掉。
  let n = 0;
  const idb6 = {
    deleteDatabase() {
      const req = { onsuccess: null, onerror: null, onblocked: null };
      setTimeout(() => {
        n++;
        if (n === 1) req.onblocked && req.onblocked();
        else req.onsuccess && req.onsuccess();
      }, 0);
      return req;
    },
    databases: async () => [],
  };
  const r6 = await run(idb6);
  console.log('⑥ blocked 后重试成功:', JSON.stringify(r6));
  check('重试后 db true', r6.db === true);
  check('blocked 未被置位', r6.blocked === false);

  console.log(failed === 0 ? '\n全部通过' : `\n${failed} 条失败`);
  process.exit(failed === 0 ? 0 : 1);
})();
