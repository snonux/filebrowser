import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/device_files.dart';

/// Overridden in tests with a fake that needs no system dialogs.
final deviceFilesProvider =
    Provider<DeviceFiles>((ref) => PlatformDeviceFiles());
