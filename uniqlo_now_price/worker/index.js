// Cloudflare Worker: 정적 웹앱(build/web) + 유니클로 한국 매장 재고 조회용 API 프록시
// 유니클로 API는 CORS를 허용하지 않아 브라우저에서 직접 부를 수 없으므로 여기서 대신 부른다.
//
//   GET /api/stores?q=명동                         → 매장 검색 [{id, name, address}]
//   GET /api/variants?productId=E492179-000&priceGroup=00
//                                                 → 색상/사이즈 목록과 사이즈·색상 조합(l2) 목록
//   GET /api/stock?storeId=132196&l2Ids=09823606,09823607
//                                                 → { l2Id: 'IN_STOCK' | 'LOW_STOCK' | 'OUT_OF_STOCK' | ... }

const UQ = 'https://www.uniqlo.com/kr/api/commerce/v5/ko';
const MAX_L2 = 20; // 요청 하나당 조합 수 (Workers 하위 요청 제한 50개 안쪽)

async function uq(path) {
  const res = await fetch(UQ + path + (path.includes('?') ? '&' : '?') + 'httpFailure=true', {
    headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json' },
  });
  const body = await res.json().catch(() => null);
  if (!res.ok || !body || body.status !== 'ok') {
    throw new Error(`uniqlo ${res.status} ${path}`);
  }
  return body.result;
}

const json = (data, status = 200, maxAge = 0) =>
  new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': maxAge ? `public, max-age=${maxAge}` : 'no-store',
    },
  });

async function stores(url) {
  const q = (url.searchParams.get('q') || '').trim().slice(0, 30);
  if (!q) return json({ error: '검색어가 필요해요' }, 400);
  const r = await uq(`/stores?keyword=${encodeURIComponent(q)}&limit=25`);
  const items = (r.items || [])
    .filter((s) => s.g1ImsStoreId6)
    .map((s) => ({ id: s.g1ImsStoreId6, name: s.name, address: s.address }));
  return json(items, 200, 86400);
}

async function variants(url) {
  const id = url.searchParams.get('productId') || '';
  const pg = url.searchParams.get('priceGroup') || '00';
  if (!/^E\d{6}-\d{3}$/.test(id) || !/^\d{2}$/.test(pg)) return json({ error: '잘못된 상품번호' }, 400);
  const [detail, l2] = await Promise.all([
    uq(`/products/${id}/price-groups/${pg}/details`),
    uq(`/products/${id}/price-groups/${pg}/l2s?withPrices=false&withStocks=false`),
  ]);
  return json(
    {
      colors: (detail.colors || []).map((c) => ({ code: c.displayCode, name: c.name })),
      sizes: (detail.sizes || []).map((s) => ({ code: s.displayCode, name: s.name })),
      l2s: (l2.l2s || [])
        .filter((x) => x.searchInStoresAvailable !== false)
        .map((x) => ({ l2Id: x.l2Id, color: x.color.displayCode, size: x.size.displayCode })),
    },
    200,
    3600,
  );
}

async function stock(url) {
  const storeId = url.searchParams.get('storeId') || '';
  const l2Ids = (url.searchParams.get('l2Ids') || '').split(',').filter(Boolean);
  if (!/^\d{4,8}$/.test(storeId) || l2Ids.length === 0 || l2Ids.length > MAX_L2 ||
      !l2Ids.every((x) => /^\d{6,10}$/.test(x))) {
    return json({ error: '잘못된 요청' }, 400);
  }
  const out = {};
  await Promise.all(
    l2Ids.map(async (l2Id) => {
      try {
        const r = await uq(`/l2s/${l2Id}/stores?storeIds=${storeId}&limit=1`);
        out[l2Id] = r.stores?.[0]?.stockStatus ?? 'UNKNOWN';
      } catch {
        out[l2Id] = 'ERROR';
      }
    }),
  );
  return json(out, 200, 300); // 재고는 5분만 캐시
}

const routes = { '/api/stores': stores, '/api/variants': variants, '/api/stock': stock };

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const handler = routes[url.pathname];
    if (!handler) {
      if (url.pathname.startsWith('/api/')) return json({ error: 'not found' }, 404);
      return env.ASSETS.fetch(request);
    }
    if (request.method !== 'GET') return json({ error: 'GET only' }, 405);

    // 같은 요청은 Cloudflare 캐시에서 (유니클로에 부담 덜 주도록)
    const cache = caches.default;
    const cached = await cache.match(request);
    if (cached) return cached;
    try {
      const res = await handler(url);
      if (res.ok) ctx.waitUntil(cache.put(request, res.clone()));
      return res;
    } catch (e) {
      return json({ error: String(e.message || e) }, 502);
    }
  },
};
