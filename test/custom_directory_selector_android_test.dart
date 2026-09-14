import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/settings/custom_directory_selector_android.dart';

void main() {
  group('custom_directory_selector_android', () {
    testWidgets(
      'onConfirmAndroid returns early for /data/user/ paths and shows no dialog',
      (tester) async {
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        final context = tester.element(find.byType(SizedBox));

        // Paths under /data/user/ are internal app storage; no permission needed.
        await onConfirmAndroid(context, '/data/user/0/com.example.saber/files');

        await tester.pump();
        expect(find.byType(AlertDialog), findsNothing);
      },
    );
  });
}
