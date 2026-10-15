import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/store_location.dart';

void main() {
  test('constants', () {
    expect(storeFileName, equals('sis_store.sqlite'));
    expect(storeAppGroup, equals('group.com.esd.sis'));
  });

  test('isIos true with groupContainer returning a path', () async {
    final groupCalls = <String>[];
    Future<String?> groupContainer(String group) async {
      groupCalls.add(group);
      return '/tmp/group-x';
    }

    final supportCalls = <void>[];
    Future<Directory> supportDir() async {
      supportCalls.add(null);
      return Directory('/tmp/support-x');
    }

    final file = await storeFile(
      isIos: true,
      groupContainer: groupContainer,
      supportDir: supportDir,
    );

    expect(file.path, equals(p.join('/tmp/group-x', storeFileName)));
    expect(groupCalls, equals([storeAppGroup]));
    expect(supportCalls, isEmpty);
  });

  test('isIos true with groupContainer returning null', () async {
    final groupCalls = <String>[];
    Future<String?> groupContainer(String group) async {
      groupCalls.add(group);
      return null;
    }

    final supportCalls = <void>[];
    Future<Directory> supportDir() async {
      supportCalls.add(null);
      return Directory('/tmp/support-x');
    }

    final file = await storeFile(
      isIos: true,
      groupContainer: groupContainer,
      supportDir: supportDir,
    );

    expect(file.path, equals(p.join('/tmp/support-x', storeFileName)));
    expect(groupCalls, equals([storeAppGroup]));
    expect(supportCalls, equals([null]));
  });

  test('isIos false', () async {
    final groupCalls = <String>[];
    Future<String?> groupContainer(String group) async {
      groupCalls.add(group);
      return '/tmp/group-x';
    }

    final supportCalls = <void>[];
    Future<Directory> supportDir() async {
      supportCalls.add(null);
      return Directory('/tmp/support-x');
    }

    final file = await storeFile(
      isIos: false,
      groupContainer: groupContainer,
      supportDir: supportDir,
    );

    expect(file.path, equals(p.join('/tmp/support-x', storeFileName)));
    expect(groupCalls, isEmpty);
    expect(supportCalls, equals([null]));
  });
}
