import 'package:flutter_test/flutter_test.dart';

import 'package:sports_talent_app/main.dart';

void main() {
  testWidgets('Home screen shows both test buttons', (WidgetTester tester) async {
    await tester.pumpWidget(const SportsTalentApp());

    expect(find.text('Standing Vertical Jump'), findsOneWidget);
    expect(find.text('Push-ups'), findsOneWidget);
  });

  testWidgets('Vertical jump button opens height dialog', (WidgetTester tester) async {
    await tester.pumpWidget(const SportsTalentApp());

    await tester.tap(find.text('Standing Vertical Jump'));
    await tester.pump();

    expect(find.text('Your Height'), findsOneWidget);
  });
}
