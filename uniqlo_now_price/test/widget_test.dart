import 'package:flutter_test/flutter_test.dart';

import 'package:uniqlo_now_price/main.dart';

void main() {
  testWidgets('처음 화면에 조회 버튼이 보인다', (WidgetTester tester) async {
    await tester.pumpWidget(const UniqloNowApp());
    expect(find.text('조회'), findsOneWidget);
  });
}
