// 매장 선택 + 매장별 사이즈·색상 재고 조회
// 재고 API는 Cloudflare Worker(worker/index.js)의 /api/* 를 쓴다.
// (로컬에서 보려면 `npx wrangler dev` 로 Worker까지 함께 띄운다)
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const apiBase = String.fromEnvironment('API_BASE', defaultValue: 'api');

class Store {
  const Store(this.id, this.name, [this.address = '']);
  final String id, name, address;
}

Future<dynamic> _getJson(String path, Map<String, String> params) async {
  final res = await http.get(Uri.parse('$apiBase/$path').replace(queryParameters: params));
  final body = jsonDecode(utf8.decode(res.bodyBytes));
  if (res.statusCode != 200) {
    throw Exception(body is Map && body['error'] != null ? body['error'] : '응답 ${res.statusCode}');
  }
  return body;
}

// ---------------------------------------------------------------------------
// 선택한 매장 기억하기
// ---------------------------------------------------------------------------

const _kStoreId = 'storeId', _kStoreName = 'storeName';

Future<Store?> loadSavedStore() async {
  try {
    final p = await SharedPreferences.getInstance();
    final id = p.getString(_kStoreId), name = p.getString(_kStoreName);
    return (id != null && name != null) ? Store(id, name) : null;
  } catch (_) {
    return null; // 저장소를 못 쓰는 환경이면 그냥 매번 선택
  }
}

Future<void> saveStore(Store s) async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kStoreId, s.id);
    await p.setString(_kStoreName, s.name);
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// 매장 검색·선택 다이얼로그
// ---------------------------------------------------------------------------

Future<Store?> pickStore(BuildContext context) =>
    showDialog<Store>(context: context, builder: (_) => const _StorePickerDialog());

class _StorePickerDialog extends StatefulWidget {
  const _StorePickerDialog();

  @override
  State<_StorePickerDialog> createState() => _StorePickerDialogState();
}

class _StorePickerDialogState extends State<_StorePickerDialog> {
  final _ctrl = TextEditingController();
  List<Store>? _results;
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _getJson('stores', {'q': q}) as List;
      setState(() => _results = [for (final s in list) Store(s['id'], s['name'], s['address'] ?? '')]);
    } catch (e) {
      setState(() => _error = '매장 검색 실패: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('매장 선택'),
      content: SizedBox(
        width: 420,
        height: 400,
        child: Column(
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                isDense: true,
                hintText: '매장 이름 (예: 명동, 강남, 잠실)',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: '검색',
                  icon: _loading
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  onPressed: _loading ? null : _search,
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            if (_results != null && _results!.isEmpty) const Padding(
              padding: EdgeInsets.all(16),
              child: Text('검색된 매장이 없어요.'),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final s in _results ?? <Store>[])
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.store),
                      title: Text(s.name),
                      subtitle: Text(s.address, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(context, s),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('닫기'))],
    );
  }
}

// ---------------------------------------------------------------------------
// 상품 재고 시트: 색상(행) × 사이즈(열)
// ---------------------------------------------------------------------------

class StockSheet extends StatefulWidget {
  const StockSheet({
    super.key,
    required this.productId,
    required this.priceGroup,
    required this.productName,
    required this.store,
  });

  final String productId, priceGroup, productName;
  final Store store;

  @override
  State<StockSheet> createState() => _StockSheetState();
}

class _StockSheetState extends State<StockSheet> {
  List<({String code, String name})> _colors = [], _sizes = [];
  final _l2 = <String, String>{}; // '색상|사이즈' → l2Id
  final _status = <String, String>{}; // l2Id → 재고 상태
  final _loadingColors = <String>{};
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await _getJson('variants', {
        'productId': widget.productId,
        'priceGroup': widget.priceGroup,
      }) as Map<String, dynamic>;
      final l2s = (v['l2s'] as List).cast<Map<String, dynamic>>();
      final usedColors = {for (final x in l2s) x['color']};
      final usedSizes = {for (final x in l2s) x['size']};
      setState(() {
        _colors = [
          for (final c in v['colors'] as List)
            if (usedColors.contains(c['code'])) (code: c['code'] as String, name: c['name'] as String),
        ];
        _sizes = [
          for (final s in v['sizes'] as List)
            if (usedSizes.contains(s['code'])) (code: s['code'] as String, name: s['name'] as String),
        ];
        for (final x in l2s) {
          _l2['${x['color']}|${x['size']}'] = x['l2Id'];
        }
        _loading = false;
        _loadingColors.addAll(_colors.map((c) => c.code));
      });
      // 색상별로 나눠서 조회 (한 요청에 조합 20개 이하), 도착하는 대로 표시
      await Future.wait([for (final c in _colors) _loadColor(c.code, l2s)]);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '재고 조회 실패: $e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadColor(String color, List<Map<String, dynamic>> l2s) async {
    final ids = [for (final x in l2s) if (x['color'] == color) x['l2Id'] as String];
    try {
      for (var i = 0; i < ids.length; i += 20) {
        final chunk = ids.sublist(i, i + 20 > ids.length ? ids.length : i + 20);
        final r = await _getJson('stock', {'storeId': widget.store.id, 'l2Ids': chunk.join(',')})
            as Map<String, dynamic>;
        if (!mounted) return;
        setState(() => r.forEach((k, v) => _status[k] = v as String));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          for (final id in ids) {
            _status.putIfAbsent(id, () => 'ERROR');
          }
        });
      }
    } finally {
      if (mounted) setState(() => _loadingColors.remove(color));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.productName, style: Theme.of(context).textTheme.titleMedium),
            Text('${widget.store.name} 재고 · ${widget.productId}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            if (_loading) const Center(child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            )),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            if (!_loading && _error == null) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: _table(),
              ),
              const SizedBox(height: 12),
              const Wrap(spacing: 12, runSpacing: 4, children: [
                _Legend('○', '재고 있음', Colors.green),
                _Legend('△', '재고 적음', Colors.orange),
                _Legend('×', '재고 없음', Colors.grey),
                _Legend('-', '해당 사이즈 없음', Colors.black38),
              ]),
              const SizedBox(height: 4),
              Text('유니클로 매장 재고 기준이며 실제와 다를 수 있어요.',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  Widget _table() {
    const cellPad = EdgeInsets.symmetric(horizontal: 10, vertical: 8);
    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      border: TableBorder.all(color: Colors.black12),
      children: [
        TableRow(
          decoration: const BoxDecoration(color: Color(0x0F000000)),
          children: [
            const Padding(padding: cellPad, child: Text('색상 \\ 사이즈')),
            for (final s in _sizes)
              Padding(padding: cellPad, child: Text(s.name, textAlign: TextAlign.center)),
          ],
        ),
        for (final c in _colors)
          TableRow(children: [
            Padding(
              padding: cellPad,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('${c.code} ${c.name}'),
                if (_loadingColors.contains(c.code)) ...[
                  const SizedBox(width: 6),
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                ],
              ]),
            ),
            for (final s in _sizes) Padding(padding: cellPad, child: Center(child: _cell(c.code, s.code))),
          ]),
      ],
    );
  }

  Widget _cell(String color, String size) {
    final l2 = _l2['$color|$size'];
    if (l2 == null) return const Text('-', style: TextStyle(color: Colors.black38));
    final st = _status[l2];
    if (st == null) return const Text('…', style: TextStyle(color: Colors.black38));
    final (mark, col, tip) = switch (st) {
      'IN_STOCK' => ('○', Colors.green, '재고 있음'),
      'LOW_STOCK' => ('△', Colors.orange, '재고 적음'),
      'OUT_OF_STOCK' => ('×', Colors.grey, '재고 없음'),
      'ERROR' => ('!', Colors.red, '조회 실패'),
      _ => ('?', Colors.black38, st),
    };
    return Tooltip(
      message: tip,
      child: Text(mark, style: TextStyle(color: col, fontWeight: FontWeight.bold, fontSize: 16)),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.mark, this.label, this.color);
  final String mark, label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text(mark, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ]);
}
