import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/listen/listen_controller.dart';
import 'package:marginalia/storage/local_store.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ProviderContainer container;
  late List<MethodCall> calls;

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    final store = await LocalStore.open();
    calls = [];
    messenger.setMockMethodCallHandler(const MethodChannel('marginalia/listen'), (call) async {
      calls.add(call);
      return call.method == 'start' ? true : null;
    });
    container = ProviderContainer(overrides: [localStoreProvider.overrideWithValue(store)]);
    await pumpEventQueue();
  });

  tearDown(() {
    container.dispose();
    messenger.setMockMethodCallHandler(const MethodChannel('marginalia/listen'), null);
  });

  test('turning a page by hand stops following the voice; a tapped line follows again', () async {
    final listen = container.read(listenProvider.notifier);
    // Not listening: nothing to follow.
    listen.stopFollowing();
    expect(container.read(listenProvider).following, isTrue);

    expect(await listen.start('pub', '{"href":"c1.xhtml"}', language: 'en'), isNull);
    expect(container.read(listenProvider).active, isTrue);

    listen.stopFollowing();
    expect(container.read(listenProvider).following, isFalse);

    await listen.readFrom('{"href":"c1.xhtml","text":{"highlight":"A line."}}');
    expect(container.read(listenProvider).following, isTrue);
    expect(calls.last.method, 'goTo');

    listen.stopFollowing();
    listen.follow();
    expect(container.read(listenProvider).following, isTrue);
  });

  test('stopping forgets that the page stopped following', () async {
    final listen = container.read(listenProvider.notifier);
    await listen.start('pub', null, language: 'en');
    listen.stopFollowing();
    await listen.stop();
    expect(container.read(listenProvider).following, isTrue);
    expect(container.read(listenProvider).active, isFalse);
  });
}
