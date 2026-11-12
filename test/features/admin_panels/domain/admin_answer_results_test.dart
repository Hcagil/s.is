import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/domain/admin_answer.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/domain/admin_dashboard.dart';

void main() {
  group('parseAnswerResults', () {
    test('returns empty list for null, Map, String, int', () {
      expect(parseAnswerResults(null), isEmpty);
      expect(parseAnswerResults({}), isEmpty);
      expect(parseAnswerResults(''), isEmpty);
      expect(parseAnswerResults(42), isEmpty);
    });

    test('parses a single ok entry with null code', () {
      final raw = [
        {'up_seq': 3, 'epoch': 2, 'ok': true, 'code': null},
      ];
      final results = parseAnswerResults(raw);
      expect(results, hasLength(1));
      final r = results.first;
      expect(r.ok, isTrue);
      expect(r.upSeq, 3);
      expect(r.epoch, 2);
      expect(r.code, isNull);
    });

    test('ok:true with code "bad_request" keeps code null', () {
      final raw = [
        {'up_seq': 1, 'epoch': 1, 'ok': true, 'code': 'bad_request'},
      ];
      final results = parseAnswerResults(raw);
      expect(results.first.code, isNull);
    });

    test('ok:false maps each known code string to enum', () {
      final codes = {
        'conv_missing': AdminAnswerCode.convMissing,
        'bad_conv': AdminAnswerCode.badConv,
        'not_open': AdminAnswerCode.notOpen,
        'desk_only': AdminAnswerCode.deskOnly,
        'unknown_item': AdminAnswerCode.unknownItem,
        'bad_request': AdminAnswerCode.badRequest,
      };
      codes.forEach((str, enumVal) {
        final raw = [
          {'up_seq': 1, 'epoch': 1, 'ok': false, 'code': str},
        ];
        final results = parseAnswerResults(raw);
        expect(results.first.code, enumVal);
      });
    });

    test('unknown or null code defaults to badRequest', () {
      final rawUnknown = [
        {'up_seq': 1, 'epoch': 1, 'ok': false, 'code': 'weird'},
      ];
      final rawNull = [
        {'up_seq': 1, 'epoch': 1, 'ok': false, 'code': null},
      ];
      expect(
        parseAnswerResults(rawUnknown).first.code,
        AdminAnswerCode.badRequest,
      );
      expect(
        parseAnswerResults(rawNull).first.code,
        AdminAnswerCode.badRequest,
      );
    });

    test('skips bad entries, keeps good ones in order', () {
      final raw = [
        'x',
        5,
        null,
        {'epoch': 1, 'ok': true},
        {'up_seq': 1, 'ok': true},
        {'up_seq': '1', 'epoch': 1, 'ok': true},
        {'up_seq': 9, 'epoch': 1, 'ok': true},
      ];
      final results = parseAnswerResults(raw);
      expect(results, hasLength(1));
      expect(results.first.upSeq, 9);
    });

    test('first ok wins for duplicate epoch & upSeq', () {
      final raw = [
        {'up_seq': 4, 'epoch': 1, 'ok': true},
        {'up_seq': 4, 'epoch': 1, 'ok': false, 'code': 'not_open'},
      ];
      final results = parseAnswerResults(raw);
      expect(results, hasLength(1));
      expect(results.first.ok, isTrue);
    });

    test('same up_seq with different epoch is not duplicate', () {
      final raw = [
        {'up_seq': 4, 'epoch': 1, 'ok': true},
        {'up_seq': 4, 'epoch': 2, 'ok': false, 'code': 'not_open'},
      ];
      final results = parseAnswerResults(raw);
      expect(results, hasLength(2));
    });

    test('ignores unknown extra keys', () {
      final raw = [
        {'up_seq': 1, 'epoch': 1, 'ok': true, 'code': null, 'extra': 'ignore'},
      ];
      final results = parseAnswerResults(raw);
      expect(results.first.upSeq, 1);
      expect(results.first.epoch, 1);
    });
  });

  group('parseDown results', () {
    test('parses items message with results', () {
      final json = '''
      {"t":"items","cursor":7,"items":[],"results":[{"up_seq":1,"epoch":1,"ok":true,"code":null}]}
      ''';
      final down = parseDown(json);
      expect(down, isA<AdminDelta>());
      final delta = down as AdminDelta;
      expect(delta.items, isEmpty);
      expect(delta.results, hasLength(1));
      expect(delta.results.first.upSeq, 1);
      expect(delta.results.first.ok, isTrue);
    });

    test('items message without results key yields empty results', () {
      final json = '''
      {"t":"items","cursor":7,"items":[]}
      ''';
      final down = parseDown(json);
      expect(down, isA<AdminDelta>());
      final delta = down as AdminDelta;
      expect(delta.results, isEmpty);
    });

    test('snapshot part with results', () {
      final json = '''
      {"t":"snapshot","id":"S-1","part":1,"parts":2,"cursor":5,"truncated":false,"items":[],"results":[{"up_seq":2,"epoch":1,"ok":false,"code":"conv_missing"}]}
      ''';
      final down = parseDown(json);
      expect(down, isA<AdminSnapshotPart>());
      final part = down as AdminSnapshotPart;
      expect(part.results, hasLength(1));
      expect(part.results.first.code, AdminAnswerCode.convMissing);
    });

    test('snapshot part without results key yields empty results', () {
      final json = '''
      {"t":"snapshot","id":"S-1","part":2,"parts":2,"cursor":5,"truncated":false,"items":[]}
      ''';
      final down = parseDown(json);
      expect(down, isA<AdminSnapshotPart>());
      final part = down as AdminSnapshotPart;
      expect(part.results, isEmpty);
    });

    test('non-list results treated as empty list', () {
      final json = '''
      {"t":"items","cursor":7,"items":[],"results":"x"}
      ''';
      final down = parseDown(json);
      expect(down, isA<AdminDelta>());
      final delta = down as AdminDelta;
      expect(delta.results, isEmpty);
    });
  });

  group('AdminDashboard.stale', () {
    test('stale true when field is true', () {
      final dash = AdminDashboard.fromFields({
        'working': [],
        'sessions': [],
        'stale': true,
      });
      expect(dash.stale, isTrue);
    });

    test('stale false for false, missing, string, or non-boolean', () {
      final cases = [
        {'working': [], 'sessions': [], 'stale': false},
        {'working': [], 'sessions': []},
        {'working': [], 'sessions': [], 'stale': 'true'},
        {'working': [], 'sessions': [], 'stale': 1},
      ];
      for (var map in cases) {
        final dash = AdminDashboard.fromFields(map);
        expect(dash.stale, isFalse);
      }
    });
  });
}
