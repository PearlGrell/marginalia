import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:workmanager/workmanager.dart';

import 'app.dart';
import 'cloud/background_sync.dart';
import 'cloud/cloud_config.dart';
import 'storage/local_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw behind the status and navigation bars; screens pad themselves with SafeArea.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final store = await LocalStore.open();
  if (CloudConfig.isConfigured) await Workmanager().initialize(backgroundSyncDispatcher);
  runApp(
    ProviderScope(
      overrides: [localStoreProvider.overrideWithValue(store)],
      child: const MarginaliaApp(),
    ),
  );
}
