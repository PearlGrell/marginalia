import 'package:flutter/services.dart';

/// Reader conveniences handled by the activity (see `DeviceChannel.kt`).
class DeviceControls {
  DeviceControls({required void Function(bool forward) onVolumeKey}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onVolumeKey') {
        onVolumeKey((call.arguments as Map)['forward'] == true);
      }
      return null;
    });
  }

  static const _channel = MethodChannel('marginalia/device');

  Future<void> setKeepScreenOn(bool on) => _channel.invokeMethod('setKeepScreenOn', {'on': on});

  /// While on, volume down turns forward and volume up turns back.
  Future<void> setVolumeKeysTurnPages(bool on) =>
      _channel.invokeMethod('setVolumeKeysTurnPages', {'on': on});

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await setKeepScreenOn(false);
    await setVolumeKeysTurnPages(false);
  }
}
