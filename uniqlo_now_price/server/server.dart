// 유니클로 할인 상품 로컬 서버
// 실행: dart run server/server.dart  (uniqlo_now_price 폴더에서)
// GET http://localhost:8080/products        → 캐시(오늘 날짜) 있으면 그대로, 없으면 새로 수집
// GET http://localhost:8080/products?refresh=1 → 강제 새로 수집
import 'dart:convert';
import 'dart:io';

const krBase = 'https://www.uniqlo.com/kr/api/commerce/v5/ko/products';
const jpBase = 'https://www.uniqlo.com/jp/api/commerce/v5/ja/products';
const guJpBase = 'https://www.gu-global.com/jp/api/commerce/v5/ja/products';
// GU 일본 사이트 카테고리 (2257 = MEN, 2256 = WOMEN; UNISEX는 양쪽에 섞여 있음)
const guJpPaths = ['2257', '2256'];
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
/// names를 넘기면 찾은 일본 상품명도 채워 준다
Future<Map<String, int>> fetchJpPrices(List<String> ids, {Map<String, String>? names}) async {
  final groups = <String, String>{};
  for (var i = 0; i < ids.length; i += 30) {
    final chunk = ids.sublist(i, i + 30 > ids.length ? ids.length : i + 30);
    final j = await getJson('$jpBase?productIds=${chunk.join(',')}&limit=50');
    for (final it in (j['result']['items'] as List)) {
      groups[it['productId'] as String] = it['priceGroup'] as String;
      names?[it['productId'] as String] = it['name'] as String;
    }
  }
  final prices = <String, int>{};
  await runPool(groups.keys.toList(), 6, (id) async {
    final p = await fetchPrice(jpBase, id, groups[id]!);
    if (p.base != null) prices[id] = p.base!;
  });
  return prices;
}

// ---------------------------------------------------------------------------
// GU 상품: 한국 유니클로 사이트의 GU 상품(이름이 'GU'로 시작)은 한국 전용 상품번호라
// 일본 GU 상품번호와 연결되지 않는다. 그래서 일본 GU 상품 이름(가타카나)을 한글로
// 바꿔 한국 상품명과 비교하고, 색상 코드 겹침을 더해 가장 비슷한 상품을 고른다.
// ---------------------------------------------------------------------------

bool isGu(String name) => name.startsWith('GU');

// 자주 쓰는 일본어 외래어 → 한국 유니클로 표기 (긴 단어부터 바꾼다)
const guWordMap = <String, String>{
  'ジャケット': '재킷', 'スウェット': '스웨트', 'パンツ': '팬츠', 'セーター': '스웨터',
  'カーディガン': '가디건', 'パーカ': '파카', 'ニット': '니트', 'シャツ': '셔츠',
  'ブルゾン': '블루종', 'コート': '코트', 'ジーンズ': '진', 'フリース': '후리스',
  'ワイド': '와이드', 'ストレート': '스트레이트', 'トラック': '트랙', 'ジップ': '집',
  'フルジップ': '풀집', 'ハーフジップ': '하프집', 'コクーン': '코쿤', 'ヘビーウェイト': '헤비웨이트',
  'バレル': '배럴', 'クルーネック': '크루넥', 'ボーダー': '스트라이프', 'ストライプ': '스트라이프',
  'チェック': '체크', 'テーラード': '테일러드', 'オーバーサイズ': '오버사이즈', 'コーデュロイ': '코듀로이',
  'パデッド': '패디드', 'スタンド': '스탠드', 'ウォーム': '웜', 'タック': '턱', 'テーパード': '테이퍼드',
  'フランネル': '플란넬', 'パジャマ': '파자마', 'ブロード': '브로드', 'マフラー': '스카프',
  'スカーフ': '스카프', 'マルチ': '멀티', 'ユーティリティ': '유틸리티', 'カーゴ': '카고',
  'デニム': '데님', 'ナイロン': '나일론', 'リップストップ': '립스탑', 'フェイクレザー': '페이크레더',
  'フェザーヤーン': '페더얀', 'Vネック': '브이넥', 'スムース': '스무스', 'メルトン': '멜톤',
  'バルマカーン': '발마칸', 'モッズ': '모즈', 'ワーク': '워크', 'ウォッシャブル': '워셔블',
  'ブークレ': '부클레', 'ポロ': '폴로', 'ポケット': '포켓', 'イージーケア': '이지케어',
  'ショーツ': '쇼츠', 'ジョーツ': '조츠', 'ジョガー': '조거', 'プルオーバー': '풀오버',
  'フーディ': '후디', 'バイカラー': '바이컬러', 'パフィータッチ': '퍼피터치', 'ボクシー': '박시',
  'ウォッシュ': '워시', 'コットン': '코튼', 'スーパー': '슈퍼', 'ワイドスリーブ': '와이드슬리브',
  'カラーブロック': '컬러블록', 'コージー': '코지', '長袖': '긴팔', '半袖': '반팔', '柄': '패턴',
  // 유니클로 상품명용 (영어 표기 포함)
  'パフテック': 'PUFFTECH', 'ライト': '라이트', 'ダウン': '다운', 'ボリューム': '볼륨',
  'ベスト': '베스트', 'シームレス': '심리스', 'オックスフォード': '옥스포드', 'ボア': '보아',
  'ショート': '쇼트', 'イージー': '이지', 'タートルネック': '터틀넥', 'ロング': '롱',
  'モックネック': '모크넥', 'ドライ': '드라이', 'ピケ': '피케', 'ナロー': '내로우',
  'リネンブレンド': '리넨블렌드', 'チノ': '치노', 'バギー': '배기', 'レッグ': '레그',
  'ボックス': '박스', 'リンガー': '링거', 'グラフィック': '그래픽', 'プリント': '프린트',
};
final _guWords = guWordMap.keys.toList()..sort((a, b) => b.length - a.length);

// 반대 방향(한국 표기 → 가타카나): 일본 사이트 검색어 만들기용
final _krToJa = <String, String>{
  for (final e in guWordMap.entries) e.value: e.key,
  '스트라이프': 'ストライプ', // ボーダー보다 유니클로에서 흔한 표기
  '재킷': 'ジャケット', '자켓': 'ジャケット',
};
final _krWords = _krToJa.keys.toList()..sort((a, b) => b.length - a.length);

/// 한국 상품명 → 일본 검색어 토큰 (사전에 있는 단어만, 영어는 그대로)
List<String> toJaTokens(String krName) {
  final s = normName(krName);
  final tokens = <String>[];
  var i = 0;
  while (i < s.length) {
    final w = _krWords.firstWhere((w) => s.startsWith(w, i), orElse: () => '');
    if (w.isNotEmpty) {
      tokens.add(_krToJa[w]!);
      i += w.length;
      continue;
    }
    final eng = RegExp(r'[A-Z0-9]+').matchAsPrefix(s, i);
    if (eng != null) {
      tokens.add(eng[0]!);
      i = eng.end;
      continue;
    }
    i++; // 사전에 없는 한글은 건너뛴다
  }
  return tokens;
}

// 나머지 가타카나는 한 글자씩 대충 한글로
const _kana = 'アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲ'
    'ガギグゲゴザジズゼゾダヂヅデドバビブベボパピプペポンヴ';
const _hangul = '아이우에오카키쿠케코사시스세소타치츠테토나니누네노하히후헤호마미무메모야유요라리루레로와오'
    '가기구게고자지즈제조다지즈데도바비부베보파피푸페포ㄴ부';

String kanaToHangul(String s) {
  for (final w in _guWords) {
    s = s.replaceAll(w, guWordMap[w]!);
  }
  final out = StringBuffer();
  for (final ch in s.split('')) {
    final i = _kana.indexOf(ch);
    out.write(i >= 0 ? _hangul[i] : ch);
  }
  return out.toString();
}

/// 비교용: 'GU' 접두어, 괄호 내용, 공백·구두점 제거
String normName(String s) => s
    .replaceFirst(RegExp(r'^GU'), '')
    .replaceAll(RegExp(r'\(.*?\)|（.*?）|[\s·・,]'), '')
    .toUpperCase();

const _cho = 'ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ';

/// 한글 음절 → 초성 (모음 표기 차이를 흡수하려고)
String choseong(String s) => s.runes.map((r) {
      final k = r - 0xAC00;
      return (k >= 0 && k < 11172) ? _cho[k ~/ 588] : String.fromCharCode(r);
    }).join();

double dice(String a, String b) {
  Set<String> grams(String s) => {for (var i = 0; i < s.length - 1; i++) s.substring(i, i + 2)};
  final ga = grams(a), gb = grams(b);
  if (ga.isEmpty || gb.isEmpty) return 0;
  return 2 * ga.intersection(gb).length / (ga.length + gb.length);
}

double jaccard(Set<String> a, Set<String> b) {
  final union = a.union(b).length;
  return union == 0 ? 0 : a.intersection(b).length / union;
}

Set<String> colorCodes(Map<String, dynamic>? it) =>
    {for (final c in (it?['colors'] as List? ?? [])) c['displayCode'] as String};

/// 한국 상품명/색상과 가장 비슷한 일본 상품을 고른다. 확실하지 않으면 null.
Map<String, dynamic>? pickBestMatch(
    String krName, Map<String, dynamic>? krItem, List<Map<String, dynamic>> candidates) {
  final kn = normName(krName);
  final kc = colorCodes(krItem);
  Map<String, dynamic>? best;
  var bestScore = -1.0, bestName = 0.0, bestExact = 0.0;
  for (final c in candidates) {
    final cn = normName(kanaToHangul(c['name'] as String));
    final exact = dice(kn, cn);
    final nameSim = [exact, dice(choseong(kn), choseong(cn)) * 0.8].reduce((a, b) => a > b ? a : b);
    final score = nameSim * 0.7 + jaccard(kc, colorCodes(c)) * 0.3;
    // 동점이면 한글 그대로 더 비슷한 쪽, 그래도 같으면 이름이 짧은 쪽(丈長め 같은 변형이 아닌 기본 상품)
    final better = score > bestScore ||
        (score == bestScore &&
            (exact > bestExact ||
                (exact == bestExact && (c['name'] as String).length < (best!['name'] as String).length)));
    if (better) {
      best = c;
      bestScore = score;
      bestName = nameSim;
      bestExact = exact;
    }
  }
  // 확실한 것만: 종합 점수가 높거나, 이름이 거의 같을 때
  return (best != null && (bestScore >= 0.65 || bestName >= 0.95)) ? best : null;
}

/// 일본 GU 남성/유니섹스 상품 전체 목록
Future<List<Map<String, dynamic>>> fetchGuJpCatalog() async {
  final byId = <String, Map<String, dynamic>>{};
  for (final path in guJpPaths) {
    var offset = 0;
    while (true) {
      final j = await getJson('$guJpBase?path=$path&limit=100&offset=$offset');
      final page = (j['result']['items'] as List).cast<Map<String, dynamic>>();
      for (final it in page) {
        if (targetGenders.contains(it['genderCategory'])) byId[it['productId']] = it;
      }
      offset += page.length;
      if (page.isEmpty || offset >= (j['result']['pagination']['total'] as int)) break;
    }
  }
  return byId.values.toList();
}

/// 한국 GU 상품들 → 일본 GU 상품 매칭 후 일본 정가 조회
/// krItems: 한국 목록 API 원본(색상 정보용), 키는 상품번호
Future<Map<String, ({int price, String name, String url})>> fetchGuJpPrices(
    List<Map<String, dynamic>> products, Map<String, Map<String, dynamic>> krItems) async {
  final catalog = await fetchGuJpCatalog();
  final matched = <String, Map<String, dynamic>>{};
  for (final p in products) {
    final best = pickBestMatch(p['name'] as String, krItems[p['productId']], catalog);
    if (best != null) {
      matched[p['productId'] as String] = best;
    } else {
      stdout.writeln('GU 일본 상품 못 찾음: ${p['name']}');
    }
  }
  final prices = <String, ({int price, String name, String url})>{};
  await runPool(matched.keys.toList(), 6, (krId) async {
    final g = matched[krId]!;
    final pr = await fetchPrice(guJpBase, g['productId'], g['priceGroup']);
    if (pr.base != null) {
      prices[krId] = (
        price: pr.base!,
        name: g['name'] as String,
        url: 'https://www.gu-global.com/jp/ja/products/${g['productId']}',
      );
    }
  });
  return prices;
}

/// 상품번호로 일본 유니클로에서 못 찾은 상품을 다시 찾는다.
/// 1) 끝번호만 다른 같은 상품 (E470118-001 → E470118-000)
/// 2) 상품명을 가타카나로 바꿔 일본 유니클로에서 검색 → 이름+색상으로 가장 비슷한 것
Future<Map<String, ({int price, String name, String url})>> fetchUqJpByName(
    List<Map<String, dynamic>> products, Map<String, Map<String, dynamic>> krItems) async {
  final result = <String, ({int price, String name, String url})>{};

  final alt = <String, String>{}; // 한국 번호 → 일본 -000 번호
  for (final p in products) {
    final id = p['productId'] as String;
    if (!id.endsWith('-000')) alt[id] = id.replaceFirst(RegExp(r'-\d{3}$'), '-000');
  }
  if (alt.isNotEmpty) {
    final names = <String, String>{};
    final jp = await fetchJpPrices(alt.values.toSet().toList(), names: names);
    alt.forEach((kr, ja) {
      if (jp[ja] != null) {
        result[kr] = (price: jp[ja]!, name: names[ja] ?? ja, url: 'https://www.uniqlo.com/jp/ja/products/$ja');
      }
    });
  }

  for (final p in products) {
    final id = p['productId'] as String;
    if (result.containsKey(id)) continue;
    final tokens = toJaTokens(p['name'] as String);
    Map<String, dynamic>? best;
    // 전체 검색어로 먼저, 결과가 없으면 뒤 단어부터 하나씩 빼며 다시
    for (var n = tokens.length; n > 0 && best == null; n--) {
      final q = Uri.encodeQueryComponent(tokens.take(n).join(' '));
      try {
        final j = await getJson('$jpBase?q=$q&limit=30');
        final cands = [
          for (final it in (j['result']['items'] as List).cast<Map<String, dynamic>>())
            if (targetGenders.contains(it['genderCategory'])) it,
        ];
        if (cands.isEmpty) continue;
        best = pickBestMatch(p['name'] as String, krItems[id], cands);
        // 이름 점수가 모자라도, 검색어 단어를 전부 포함하는 상품이 딱 하나면 그것
        // (예: PUFFTECH베스트 → パフテックコンパクトベスト)
        if (best == null && n == tokens.length) {
          final all = cands
              .where((c) => tokens.every((t) => (c['name'] as String).toUpperCase().contains(t)))
              .toList();
          if (all.length == 1) best = all.first;
        }
        break; // 검색 결과가 있었으면 더 줄이지 않는다
      } catch (e) {
        stderr.writeln('일본 검색 실패 ${p['name']}: $e');
        break;
      }
    }
    if (best == null) {
      stdout.writeln('일본 유니클로 상품 못 찾음: ${p['name']}');
      continue;
    }
    final pr = await fetchPrice(jpBase, best['productId'], best['priceGroup']);
    if (pr.base != null) {
      result[id] = (
        price: pr.base!,
        name: best['name'] as String,
        url: 'https://www.uniqlo.com/jp/ja/products/${best['productId']}',
      );
    }
  }
  return result;
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
  final krRaw = <String, Map<String, dynamic>>{}; // 한국 목록 원본 (GU 매칭 시 색상 비교용)
  for (final flag in flagCodes.keys) {
    for (final it in await fetchKr(flag)) {
      if (!targetGenders.contains(it['genderCategory'])) continue;
      final id = it['productId'] as String;
      krRaw[id] = it;
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
  // 유니클로 상품은 상품번호로 일본 유니클로에서, GU 상품은 일본 GU에서 이름으로 찾는다
  final uq = byId.values.where((p) => !isGu(p['name'])).toList();
  final gu = byId.values.where((p) => isGu(p['name'])).toList();
  final jp = await fetchJpPrices([for (final p in uq) p['productId'] as String]);
  for (final p in uq) {
    p['jpBase'] = jp[p['productId']]; // 일본에 없으면 null
  }
  // 상품번호로 못 찾은 것은 가타카나 이름 검색으로 다시
  final missing = uq.where((p) => p['jpBase'] == null).toList();
  final byName = await fetchUqJpByName(missing, krRaw);
  for (final p in missing) {
    final m = byName[p['productId']];
    if (m != null) {
      p['jpBase'] = m.price;
      p['jpName'] = m.name;
      p['jpUrl'] = m.url;
    }
  }
  final guJp = await fetchGuJpPrices(gu, krRaw);
  for (final p in gu) {
    final m = guJp[p['productId']];
    p['jpBase'] = m?.price;
    p['jpBrand'] = 'GU';
    if (m != null) {
      p['jpName'] = m.name;
      p['jpUrl'] = m.url;
    }
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
