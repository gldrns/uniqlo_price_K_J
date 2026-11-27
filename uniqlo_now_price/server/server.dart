// 유니클로 할인 상품 로컬 서버
// 실행: dart run server/server.dart  (uniqlo_now_price 폴더에서)
// GET http://localhost:8080/products        → 캐시(오늘 날짜) 있으면 그대로, 없으면 새로 수집
// GET http://localhost:8080/products?refresh=1 → 강제 새로 수집
import 'dart:convert';
import 'dart:io';

const krBase = 'https://www.uniqlo.com/kr/api/commerce/v5/ko/products';
const jpBase = 'https://www.uniqlo.com/jp/api/commerce/v5/ja/products';
const port = 8080;

// 이번주할인 = limitedOffer(기간한정가격), 가격할인 = discount(가격인하)
const flagCodes = {'limitedOffer': '이번주할인', 'discount': '가격할인'};
const targetGenders = {'MEN', 'UNISEX'};

final cacheFile = File('server/data/products.json');
final client = HttpClient()..userAgent = 'Mozilla/5.0';

// 상품명 키워드 → 태그 (위에서부터 먼저 걸리는 것으로)
const tagRules = <String, List<String>>{
  '양말': ['삭스', '양말'],
  '이너웨어': ['히트텍', '에어리즘', '트렁크', '브리프', '복서', '이너'],
  '아우터': ['재킷', '자켓', '코트', '다운', '파카', '블루종', '점퍼', '베스트', '플리스'],
  '니트': ['니트', '스웨터', '카디건', '가디건'],
  '스웨트': ['스웨트', '후디', '후드'],
  '티셔츠': ['티셔츠', 'T셔츠', 'UT', '그래픽T', 'T(', '롱T', '박시T', '크롭T', '크루넥T', '폴로'],
  '셔츠': ['셔츠'],
  '바지': ['팬츠', '진', '조거', '슬랙스', '치노', '쇼츠', '반바지'],
  '신발': ['슈즈', '스니커즈', '부츠', '샌들'],
  '모자·소품': ['캡', '모자', '비니', '머플러', '스카프', '스톨', '장갑', '글러브', '벨트', '가방', '백'],
  '홈웨어': ['파자마', '라운지', '룸'],
};

String tagOf(String name) {
  for (final e in tagRules.entries) {
    if (e.value.any(name.contains)) return e.key;
  }
  return '기타';
}

Future<Map<String, dynamic>> getJson(String url) async {
  final req = await client.getUrl(Uri.parse(url));
  final res = await req.close();
  final body = await res.transform(utf8.decoder).join();
  if (res.statusCode != 200) {
    throw HttpException('HTTP ${res.statusCode}: $url');
  }
  return jsonDecode(body) as Map<String, dynamic>;
}

/// 한국 사이트에서 플래그별 상품을 전부 가져온다 (100개씩 페이지)
Future<List<Map<String, dynamic>>> fetchKr(String flag) async {
  final items = <Map<String, dynamic>>[];
  var offset = 0;
  while (true) {
    final j = await getJson('$krBase?flagCodes=$flag&limit=100&offset=$offset');
    final result = j['result'] as Map<String, dynamic>;
    final page = (result['items'] as List).cast<Map<String, dynamic>>();
    items.addAll(page);
    final total = result['pagination']['total'] as int;
    offset += page.length;
    if (page.isEmpty || offset >= total) break;
  }
  return items;
}

/// 상품별 가격 API: 목록 API 가격은 할인 적용된 현재가라서,
/// 원래 가격(정가)은 includePreviousPrice=true 로 따로 받아야 한다.
/// 반환: (정가 = base 최댓값, 현재가 = promo 최솟값)
Future<({int? base, int? promo})> fetchPrice(String apiBase, String id, String priceGroup) async {
  try {
    final j = await getJson('$apiBase/$id/price-groups/$priceGroup/l2s'
        '?withPrices=true&withStocks=false&includePreviousPrice=true&httpFailure=true');
    int? base, promo;
    for (final p in (j['result']['prices'] as Map).values) {
      final b = (p['base']?['value'] as num?)?.toInt();
      final r = (p['promo']?['value'] as num?)?.toInt();
      if (b != null && (base == null || b > base)) base = b;
      if (r != null && (promo == null || r < promo)) promo = r;
    }
    return (base: base, promo: promo);
  } catch (e) {
    stderr.writeln('가격 조회 실패 $id: $e');
    return (base: null, promo: null);
  }
}

/// 여러 작업을 동시에 n개씩 돌린다 (사이트에 부담 덜 주도록)
Future<void> runPool<T>(List<T> list, int n, Future<void> Function(T) task) async {
  var i = 0;
  Future<void> worker() async {
    while (i < list.length) {
      await task(list[i++]);
    }
  }
  await Future.wait(List.generate(n, (_) => worker()));
}

/// 일본 상품을 상품번호로 찾아 priceGroup을 얻은 뒤 일본 정가를 조회
Future<Map<String, int>> fetchJpPrices(List<String> ids) async {
  final groups = <String, String>{};
  for (var i = 0; i < ids.length; i += 30) {
    final chunk = ids.sublist(i, i + 30 > ids.length ? ids.length : i + 30);
    final j = await getJson('$jpBase?productIds=${chunk.join(',')}&limit=50');
    for (final it in (j['result']['items'] as List)) {
      groups[it['productId'] as String] = it['priceGroup'] as String;
    }
  }
  final prices = <String, int>{};
  await runPool(groups.keys.toList(), 6, (id) async {
    final p = await fetchPrice(jpBase, id, groups[id]!);
    if (p.base != null) prices[id] = p.base!;
  });
  return prices;
}

String? imageOf(Map<String, dynamic> it) {
  final main = it['images']?['main'];
  if (main is Map && main.isNotEmpty) {
    final first = main.values.first;
    if (first is Map) return first['image'] as String?;
  }
  return null;
}

Future<Map<String, dynamic>> collect() async {
  final byId = <String, Map<String, dynamic>>{};
  for (final flag in flagCodes.keys) {
    for (final it in await fetchKr(flag)) {
      if (!targetGenders.contains(it['genderCategory'])) continue;
      final id = it['productId'] as String;
      final p = byId.putIfAbsent(id, () {
        final name = it['name'] as String;
        return {
          'productId': id,
          'name': name,
          'gender': it['genderCategory'],
          'priceGroup': it['priceGroup'],
          'tag': tagOf(name),
          'krBase': (it['prices']['base']?['value'] as num?)?.toInt(),
          'krPromo': (it['prices']['promo']?['value'] as num?)?.toInt(),
          'image': imageOf(it),
          'url': 'https://www.uniqlo.com/kr/ko/products/$id',
          'saleTypes': <String>[],
          'saleText': <String>[],
        };
      });
      (p['saleTypes'] as List).add(flagCodes[flag]!);
      final pf = (it['representative']?['flags']?['priceFlags'] as List?) ?? [];
      for (final f in pf) {
        if (f['code'] == flag) (p['saleText'] as List).add(f['name']);
      }
    }
  }
  // 한국 정가/할인가를 상품별 가격 API로 다시 받는다
  await runPool(byId.values.toList(), 6, (p) async {
    final kr = await fetchPrice(krBase, p['productId'], p['priceGroup']);
    if (kr.base != null) p['krBase'] = kr.base;
    if (kr.promo != null) p['krPromo'] = kr.promo;
  });
  final jp = await fetchJpPrices(byId.keys.toList());
  for (final p in byId.values) {
    p['jpBase'] = jp[p['productId']]; // 일본에 없으면 null
  }
  final now = DateTime.now();
  return {
    'fetchedAt': now.toIso8601String(),
    'date': now.toIso8601String().substring(0, 10),
    'count': byId.length,
    'items': byId.values.toList(),
  };
}

/// 캐시가 오늘 날짜면 그대로, 아니면 새로 수집해서 저장
Future<Map<String, dynamic>> load({bool force = false}) async {
  final today = DateTime.now().toIso8601String().substring(0, 10);
  if (!force && await cacheFile.exists()) {
    final cached = jsonDecode(await cacheFile.readAsString()) as Map<String, dynamic>;
    if (cached['date'] == today) return cached..['fromCache'] = true;
  }
  stdout.writeln('[${DateTime.now()}] 유니클로에서 새로 수집 중...');
  final data = await collect();
  await cacheFile.parent.create(recursive: true);
  await cacheFile.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  stdout.writeln('수집 완료: ${data['count']}개');
  return data..['fromCache'] = false;
}

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('서버 시작: http://localhost:$port/products');
  await for (final req in server) {
    req.response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..contentType = ContentType.json;
    try {
      if (req.uri.path == '/products') {
        final data = await load(force: req.uri.queryParameters['refresh'] == '1');
        req.response.write(jsonEncode(data));
      } else {
        req.response.statusCode = 404;
      }
    } catch (e) {
      stderr.writeln('에러: $e');
      req.response
        ..statusCode = 500
        ..write(jsonEncode({'error': e.toString()}));
    }
    await req.response.close();
  }
}
