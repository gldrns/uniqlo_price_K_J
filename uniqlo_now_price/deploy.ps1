# Cloudflare Pages 정적 배포 스크립트 (uniqlo_now_price 폴더에서 실행)
# 1) 최신 데이터가 필요하면 먼저: dart run server/server.dart 실행 후 http://localhost:8080/products?refresh=1 호출
# 2) 이 스크립트 실행: .\deploy.ps1
$ErrorActionPreference = 'Stop'

flutter build web --release --dart-define=DATA_URL=products.json
if ($LASTEXITCODE -ne 0) { throw 'flutter build 실패' }

Copy-Item server/data/products.json build/web/products.json -Force

# wrangler.jsonc 설정(build/web 정적 에셋)으로 Cloudflare Workers에 배포
npx --yes wrangler deploy
