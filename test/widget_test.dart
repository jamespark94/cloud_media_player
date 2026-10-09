import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_media_player/main.dart';
import 'package:cloud_media_player/services/account_manager.dart';
import 'package:cloud_media_player/services/folder_shortcut_manager.dart';
import 'package:cloud_media_player/services/playback_history_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AccountManager()),
          ChangeNotifierProvider(create: (_) => FolderShortcutManager()),
          ChangeNotifierProvider.value(value: PlaybackHistoryService.instance),
        ],
        child: const CloudMediaPlayerApp(),
      ),
    );
    expect(find.byType(CloudMediaPlayerApp), findsOneWidget);
  });
}
