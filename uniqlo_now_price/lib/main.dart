import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;

// 로컬 Dart 서버 (server/server.dart) 주소
const serverUrl = 'http://localhost:8080/products';

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
        krBase = j['krBase'],
        krPromo = j['krPromo'],
        jpBase = j['jpBase'],
        image = j['image'],
        saleTypes = List<String>.from(j['saleTypes']),
        saleText = List<String>.from(j['saleText']);

  final String id, name, gender, tag;
  final int? krBase, krPromo, jpBase;
  final String? image;
  final List<String> saleTypes, saleText;
}

class ProductPage extends StatefulWidget {
  const ProductPage({super.key});

  @override
  State<ProductPage> createState() => _ProductPageState();
}

class _ProductPageState extends State<ProductPage> {
  List<Product> _items = [];
  String? _selectedTag; // null = 전체
  String? _info;
  String? _error;
  bool _loading = false;

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await http.get(Uri.parse(refresh ? '$serverUrl?refresh=1' : serverUrl));
      if (res.statusCode != 200) throw Exception('서버 응답 ${res.statusCode}');
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      setState(() {
        _items = (data['items'] as List).map((e) => Product.fromJson(e)).toList();
        _selectedTag = null;
        _info = '${data['date']} 기준 · ${data['count']}개'
            '${data['fromCache'] == true ? ' (저장된 데이터)' : ' (새로 업데이트)'}';
      });
    } catch (e) {
      setState(() => _error = '불러오기 실패: $e\n서버(dart run server/server.dart)가 켜져 있는지 확인해줘.');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tags = <String, int>{};
    for (final p in _items) {
      tags[p.tag] = (tags[p.tag] ?? 0) + 1;
    }
    final sortedTags = tags.keys.toList()..sort((a, b) => tags[b]!.compareTo(tags[a]!));
    final shown = _selectedTag == null ? _items : _items.where((p) => p.tag == _selectedTag).toList();

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
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  label: const Text('조회'),
                ),
                const SizedBox(width: 12),
                if (_info != null) Expanded(child: Text(_info!, style: Theme.of(context).textTheme.bodySmall)),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          if (_items.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _tagChip('전체', _items.length, null),
                  for (final t in sortedTags) _tagChip(t, tags[t]!, t),
                ],
              ),
            ),
          Expanded(
            child: ListView.separated(
              itemCount: shown.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => _ProductTile(shown[i]),
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
String _comma(int v) => v.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

class _ProductTile extends StatelessWidget {
  const _ProductTile(this.p);
  final Product p;

  @override
  Widget build(BuildContext context) {
    final discounted = p.krPromo != null && p.krBase != null && p.krPromo! < p.krBase!;
    return ListTile(
      leading: p.image == null
          ? const SizedBox(width: 56, child: Icon(Icons.checkroom))
          // 웹에서 유니클로 이미지는 CORS 때문에 막히므로 <img> 태그로 표시
          : Image.network(p.image!, width: 56, fit: BoxFit.cover,
              webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
              errorBuilder: (_, _, _) => const SizedBox(width: 56, child: Icon(Icons.checkroom))),
      title: Text(p.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 4,
            children: [
              for (final s in p.saleTypes) _badge(s, s == '이번주할인' ? Colors.red : Colors.orange),
              _badge(p.tag, Colors.blueGrey),
              _badge(p.gender, Colors.grey),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (discounted) ...[
                Text(won(p.krBase!),
                    style: const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.grey)),
                const SizedBox(width: 6),
              ],
              Text('한국 ${p.krPromo != null ? won(p.krPromo!) : '-'}',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black)),
            ],
          ),
          Text('일본 정가 ${p.jpBase != null ? yen(p.jpBase!) : '일본 미판매/정보 없음'}'),
          if (p.saleText.isNotEmpty) Text(p.saleText.join(' · '), style: const TextStyle(fontSize: 11)),
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
