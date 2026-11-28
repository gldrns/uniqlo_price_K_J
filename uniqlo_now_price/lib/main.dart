import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;

import 'store_stock.dart';

// 데이터 주소. 기본값은 로컬 Dart 서버 (server/server.dart).
// Cloudflare Pages 정적 배포 시: --dart-define=DATA_URL=products.json
const serverUrl = String.fromEnvironment(
  'DATA_URL',
  defaultValue: 'http://localhost:8080/products',
);

void main() {
  runApp(const UniqloNowApp());
}

class UniqloNowApp extends StatelessWidget {
  const UniqloNowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '유니클로 할인 가격비교',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE60012)),
      ),
      home: const ProductPage(),
    );
  }
}

class Product {
  Product.fromJson(Map<String, dynamic> j)
    : id = j['productId'],
      name = j['name'],
      gender = j['gender'],
      tag = j['tag'],
      priceGroup = j['priceGroup'] ?? '00',
      krBase = j['krBase'],
      krPromo = j['krPromo'],
      jpBase = j['jpBase'],
      jpBrand = j['jpBrand'],
      jpName = j['jpName'],
      image = j['image'],
      saleTypes = List<String>.from(j['saleTypes']),
      saleText = List<String>.from(j['saleText']);

  final String id, name, gender, tag, priceGroup;
  final int? krBase, krPromo, jpBase;
  final String? image, jpBrand, jpName;
  final List<String> saleTypes, saleText;

  /// 한국 할인율 (0.0~1.0). 정가·할인가가 없거나 할인이 아니면 0.
  double get discountRate {
    final base = krBase, promo = krPromo;
    if (base == null || promo == null || base <= 0 || promo >= base) return 0;
    return (base - promo) / base;
  }
}

enum SortBy {
  basic('기본순'),
  priceLow('가격 낮은순'),
  priceHigh('가격 높은순'),
  discount('할인율 높은순');

  const SortBy(this.label);
  final String label;
}

class ProductPage extends StatefulWidget {
  const ProductPage({super.key});

  @override
  State<ProductPage> createState() => _ProductPageState();
}

class _ProductPageState extends State<ProductPage> {
  List<Product> _items = [];
  String? _selectedTag; // null = 전체
  final _searchCtrl = TextEditingController();
  String _query = '';
  Store? _store; // 재고를 볼 매장
  SortBy _sort = SortBy.basic;

  /// 정렬 (가격 정보가 없는 상품은 항상 맨 뒤). 같은 값이면 원래 순서 유지.
  void _sortList(List<Product> list) {
    if (_sort == SortBy.basic) return;
    double? key(Product p) => switch (_sort) {
      SortBy.priceLow || SortBy.priceHigh => p.krPromo?.toDouble(),
      SortBy.discount => p.discountRate,
      SortBy.basic => null,
    };
    final desc = _sort == SortBy.priceHigh || _sort == SortBy.discount;
    final indexed = list.asMap().entries.toList()
      ..sort((a, b) {
        final ka = key(a.value), kb = key(b.value);
        if (ka == null || kb == null) {
          if (ka == null && kb == null) return a.key.compareTo(b.key);
          return ka == null ? 1 : -1;
        }
        final c = desc ? kb.compareTo(ka) : ka.compareTo(kb);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    list
      ..clear()
      ..addAll(indexed.map((e) => e.value));
  }

  @override
  void initState() {
    super.initState();
    loadSavedStore().then((s) {
      if (mounted && s != null) setState(() => _store = s);
    });
  }

  Future<Store?> _chooseStore() async {
    final s = await pickStore(context);
    if (s != null) {
      await saveStore(s);
      if (mounted) setState(() => _store = s);
    }
    return s;
  }

  /// 상품을 누르면: 매장이 없으면 먼저 고르고, 그 매장의 사이즈·색상별 재고를 보여준다
  Future<void> _showStock(Product p) async {
    final store = _store ?? await _chooseStore();
    if (store == null || !mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => StockSheet(
        productId: p.id,
        priceGroup: p.priceGroup,
        productName: p.name,
        store: store,
      ),
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 공백 무시, 대소문자 무시
  static String _norm(String s) =>
      s.replaceAll(RegExp(r'\s'), '').toLowerCase();

  /// 상품명(한국/일본) 또는 상품번호(E492179-000, 492179 모두 가능)에 검색어가 들어 있으면 true
  bool _matches(Product p) {
    final q = _norm(_query);
    if (q.isEmpty) return true;
    return _norm(p.name).contains(q) ||
        _norm(p.id).contains(q) ||
        (p.jpName != null && _norm(p.jpName!).contains(q));
  }

  String? _info;
  String? _error;
  bool _loading = false;

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await http.get(
        Uri.parse(refresh ? '$serverUrl?refresh=1' : serverUrl),
      );
      if (res.statusCode != 200) throw Exception('서버 응답 ${res.statusCode}');
      final data =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      setState(() {
        _items = (data['items'] as List)
            .map((e) => Product.fromJson(e))
            .toList();
        _selectedTag = null;
        _info =
            '${data['date']} 기준 · ${data['count']}개'
            '${data['fromCache'] == true ? ' (저장된 데이터)' : ' (새로 업데이트)'}';
      });
    } catch (e) {
      setState(
        () => _error =
            '불러오기 실패: $e\n서버(dart run server/server.dart)가 켜져 있는지 확인해줘.',
      );
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 검색어로 먼저 거르고, 카테고리 개수도 검색 결과 기준으로 센다
    final searched = _items.where(_matches).toList();
    final tags = <String, int>{};
    for (final p in searched) {
      tags[p.tag] = (tags[p.tag] ?? 0) + 1;
    }
    final sortedTags = tags.keys.toList()
      ..sort((a, b) => tags[b]!.compareTo(tags[a]!));
    final shown = _selectedTag == null
        ? searched
        : searched.where((p) => p.tag == _selectedTag).toList();
    _sortList(shown);

    return Scaffold(
      appBar: AppBar(
        title: const Text('유니클로 할인 (남성·유니섹스)'),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              tooltip: '강제 새로고침',
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : () => _load(refresh: true),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                FilledButton.icon(
                  onPressed: _loading ? null : _load,
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: const Text('조회'),
                ),
                const SizedBox(width: 12),
                if (_info != null)
                  Expanded(
                    child: Text(
                      _info!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          if (_items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.store, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _store == null
                          ? '재고를 볼 매장을 선택하세요 (상품을 누르면 재고 표시)'
                          : '매장: ${_store!.name} · 상품을 누르면 재고 표시',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: _chooseStore,
                    child: Text(_store == null ? '매장 선택' : '매장 변경'),
                  ),
                ],
              ),
            ),
          if (_items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: (v) => setState(() {
                        _query = v;
                        // 검색 결과에 없는 카테고리가 선택돼 있으면 전체로
                        if (_selectedTag != null &&
                            !_items.any(
                              (p) => p.tag == _selectedTag && _matches(p),
                            )) {
                          _selectedTag = null;
                        }
                      }),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search),
                        hintText: '상품명 또는 상품번호로 검색 (예: 히트텍, 492179)',
                        border: const OutlineInputBorder(),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '지우기',
                                icon: const Icon(Icons.clear),
                                onPressed: () => setState(() {
                                  _searchCtrl.clear();
                                  _query = '';
                                }),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 정렬: 받아 둔 데이터만으로 계산 (API 호출 없음)
                  DropdownButton<SortBy>(
                    value: _sort,
                    underline: const SizedBox.shrink(),
                    icon: const Icon(Icons.sort),
                    onChanged: (v) => setState(() => _sort = v ?? SortBy.basic),
                    items: [
                      for (final s in SortBy.values)
                        DropdownMenuItem(value: s, child: Text(s.label)),
                    ],
                  ),
                ],
              ),
            ),
          if (_items.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _tagChip('전체', searched.length, null),
                  for (final t in sortedTags) _tagChip(t, tags[t]!, t),
                ],
              ),
            ),
          if (_items.isNotEmpty && shown.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('검색 결과가 없어요.'),
            ),
          Expanded(
            child: ListView.separated(
              itemCount: shown.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) =>
                  _ProductTile(shown[i], onTap: () => _showStock(shown[i])),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tagChip(String label, int count, String? value) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text('$label $count'),
        selected: _selectedTag == value,
        onSelected: (_) => setState(() => _selectedTag = value),
      ),
    );
  }
}

String won(int v) => '₩${_comma(v)}';
String yen(int v) => '¥${_comma(v)}';
String _comma(int v) =>
    v.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

class _ProductTile extends StatelessWidget {
  const _ProductTile(this.p, {this.onTap});
  final Product p;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final discounted =
        p.krPromo != null && p.krBase != null && p.krPromo! < p.krBase!;
    return ListTile(
      onTap: onTap,
      leading: p.image == null
          ? const SizedBox(width: 56, child: Icon(Icons.checkroom))
          // 웹에서 유니클로 이미지는 CORS 때문에 막히므로 <img> 태그로 표시
          : Image.network(
              p.image!,
              width: 56,
              fit: BoxFit.cover,
              webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
              errorBuilder: (_, _, _) =>
                  const SizedBox(width: 56, child: Icon(Icons.checkroom)),
            ),
      title: Text(p.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 4,
            children: [
              for (final s in p.saleTypes)
                _badge(s, s == '이번주할인' ? Colors.red : Colors.orange),
              _badge(p.tag, Colors.blueGrey),
              _badge(p.gender, Colors.grey),
              Text(
                p.id,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (discounted) ...[
                Text(
                  won(p.krBase!),
                  style: const TextStyle(
                    decoration: TextDecoration.lineThrough,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                '한국 ${p.krPromo != null ? won(p.krPromo!) : '-'}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
              if (discounted) ...[
                const SizedBox(width: 6),
                Text(
                  '-${(p.discountRate * 100).round()}%',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                  ),
                ),
              ],
            ],
          ),
          Text(
            '일본${p.jpBrand == 'GU' ? ' GU' : ''} 정가 '
            '${p.jpBase != null ? yen(p.jpBase!) : '일본 미판매/정보 없음'}',
          ),
          if (p.saleText.isNotEmpty)
            Text(p.saleText.join(' · '), style: const TextStyle(fontSize: 11)),
        ],
      ),
      isThreeLine: true,
    );
  }

  Widget _badge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(text, style: TextStyle(fontSize: 11, color: color)),
  );
}
