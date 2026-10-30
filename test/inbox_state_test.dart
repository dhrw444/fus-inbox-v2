import 'package:flutter_test/flutter_test.dart';
import 'package:fus_inbox/data/inbox_store.dart';

/// 造一帧真消息，走 `ingest` 的真实解析路径。
String frameJson(int n) {
  final items = List.generate(
    n,
    (i) => '{"id":"$i","text":"body $i","sender":"s","time":"2026-10-30T10:00:00Z"}',
  );
  return '{"type":"messages","items":[${items.join(',')}],"hits":1,"source":"dom"}';
}

void main() {
  group('显示更多', () {
    test('默认只显示 5 条', () {
      final store = InboxStore()..ingest(frameJson(20));
      final st = store.state;
      expect(st.shown.length, 5);
      expect(st.hasHidden, isTrue);
    });

    test('不足 5 条时全显示，没有隐藏的', () {
      final store = InboxStore()..ingest(frameJson(3));
      final st = store.state;
      expect(st.shown.length, 3);
      expect(st.hasHidden, isFalse);
    });

    test('revealMore 每次多放 5 条', () {
      final store = InboxStore();
      store.ingest(frameJson(20));
      expect(store.state.shown.length, 5);
      store.revealMore();
      expect(store.state.shown.length, 10);
      store.revealMore();
      expect(store.state.shown.length, 15);
    });

    test('放到最后就不再隐藏', () {
      final store = InboxStore();
      store.ingest(frameJson(7));
      store.revealMore();
      expect(store.state.shown.length, 7);
      expect(store.state.hasHidden, isFalse);
    });

    test('reset 后回到只显示 5 条', () {
      final store = InboxStore();
      store.ingest(frameJson(20));
      store.revealMore();
      expect(store.state.shown.length, 10);
      store.reset();
      expect(store.state.visible, 5);
    });
  });
}
