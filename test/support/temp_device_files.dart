import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'file_fakes.dart';

DeviceFilesFake tempDeviceFiles() {
  final dir = Directory.systemTemp.createTempSync('sis_files_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return DeviceFilesFake(onDisk: true, root: dir.path);
}
