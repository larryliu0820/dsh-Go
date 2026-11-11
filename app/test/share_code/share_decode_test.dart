import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/share_code/share_code_state.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_decode.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine.dart' show FakeShareNet;

const _plugin = PluginShare(
  SharedPlugin(name: 'notes', source: PluginSourceKind.npm, spec: 'notes@1.2.3', version: '1.2.3'),
);

Map<String, Object?> _conversation({List<Object?> entries = const [], Object? title = '回放'}) => {
  'v': conversationBodyVersion,
  'kind': 'conversation',
  'schema': conversationSchema,
  'title': title,
  'start': '2026-11-01T00:00:00.000Z',
  'entries': entries,
};

void main() {
  // runAsync exercises Flutter's real compute worker, not FakeAsync timers.
  testWidgets('native import decodes plugin, profile and file bytes on a worker', (tester) async {
    await tester.runAsync(() async {
      final plugin = await decodeShareImport(encodeShareCode(_plugin)) as DecodedSharePayload;
      expect(plugin.payload.toJson(), _plugin.toJson());
      const profile = ProfileShare(
        name: 'reader',
        settings: {
          'subagent': {'maxDepth': 2},
        },
        skills: [
          SharedSkill(name: 'outline', files: {'SKILL.md': 'Outline first.'}),
        ],
      );
      final decoded = await decodeShareImportBytes(utf8.encode(encodeShareFile(profile))) as DecodedSharePayload;
      expect(decoded.payload.toJson(), profile.toJson());
    });
  });

  testWidgets('conversation worker preserves entries, Unicode limits and checked picture bytes', (tester) async {
    await tester.runAsync(() async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final asset = ConversationAsset.of(bytes, mediaType: 'image/png', width: 2, height: 2);
      final share = ConversationShare(
        title: '带图😀',
        start: DateTime.utc(2026, 11),
        entries: [
          const TurnEntry(t: 0, d: 1000, steps: 2),
          UserEntry(
            t: 1,
            text: '${'a' * 399999}😀',
            images: [ImageRef(id: asset.id, width: 2, height: 2)],
          ),
          const ReplyEntry(t: 2, d: 200, text: '回答😀', thinking: '思考'),
          const ToolEntry(t: 3, name: 'read', args: {'path': 'sample'}, result: 'ok'),
        ],
      );
      final text = encodeConversationFile(share, [asset]);
      final decoded = (await decodeShareImport(text) as DecodedShareConversation).conversation;
      expect(decoded.share.toJson(), decodeConversationFile(text).share.toJson());
      expect(decoded.share.entries.whereType<UserEntry>().single.text, '${'a' * 399999}…');
      expect(decoded.assets[asset.id]!.bytes, bytes);
      expect(decoded.code, readShareEnvelope(text).code);
      final hosted = await decodeConversationImportBytes(utf8.encode(text));
      expect(hosted.share.toJson(), decoded.share.toJson());
      expect(hosted.assets[asset.id]!.bytes, bytes);

      final envelope = jsonDecode(text) as Map<String, dynamic>;
      (envelope['assets'] as Map)[asset.id]['data'] = base64.encode([9, 9]);
      final changed = await decodeShareImport(jsonEncode(envelope)) as DecodedShareConversation;
      expect(changed.conversation.assets, isEmpty, reason: 'a substituted picture is still dropped');
    });
  });

  testWidgets('Gist worker keeps escaped envelopes and checksum pins', (tester) async {
    await tester.runAsync(() async {
      const id = 'aa5a315d61ae9438b18d';
      final code = encodeShareCode(_plugin);
      final link = ShareLink.gist(id, code.split('.').last);
      final net = FakeShareNet()
        ..gists[id] = encodeShareFile(_plugin, code: code).replaceFirst('"code"', r'"\u0063ode"');
      final decoded = await resolveShareImport(link, net) as DecodedSharePayload;
      expect(decoded.payload.toJson(), _plugin.toJson());
      await expectLater(
        resolveShareImport(const ShareLink.gist(id, 'AAAAAAAA'), net),
        throwsA(isA<ShareDecodeException>().having((e) => e.reason, 'reason', 'gist changed')),
      );
      expect(net.created, isEmpty);
    });
  });

  testWidgets('worker keeps the app language for missing conversation titles', (tester) async {
    final previous = AppLocale.current;
    addTearDown(() => AppLocale.use(previous));
    AppLocale.use(AppLocale.en);
    final fallback = appL10n.pluginsChat;
    await tester.runAsync(() async {
      final decoded = await decodeShareImport(encodeShareJson(_conversation(title: null))) as DecodedShareConversation;
      expect(decoded.conversation.share.title, fallback);
    });
  });

  testWidgets('worker retains format, body budget and install security validation', (tester) async {
    await tester.runAsync(() async {
      await expectLater(decodeShareImport('not a code'), throwsA(isA<ShareDecodeException>()));
      await expectLater(
        decodeShareImport(encodeShareJson({..._conversation(), 'schema': conversationSchema + 1})),
        throwsA(isA<ShareFormatException>().having((e) => e.reason, 'reason', 'newer format')),
      );
      await expectLater(
        decodeShareImport(encodeShareJson({'v': 1, 'kind': 'profile', 'name': 'x' * (maxShareBodyBytes + 100)})),
        throwsA(isA<ShareDecodeException>().having((e) => e.reason, 'reason', 'body too large')),
      );
      await expectLater(
        decodeShareImport(
          encodeShareJson({
            'v': 1,
            'kind': 'plugin',
            'plugin': {'name': 'notes', 'source': 'npm', 'spec': 'notes@latest', 'version': '1.2.3'},
          }),
        ),
        throwsA(isA<ShareFormatException>()),
      );
      await expectLater(
        decodeConversationImportBytes(utf8.encode(encodeShareFile(_plugin))),
        throwsA(isA<ShareFormatException>()),
        reason: 'hosted conversation links must not open installable payloads',
      );
      await expectLater(decodeShareImportBytes(Uint8List.fromList([0xff])), throwsA(isA<FormatException>()));
      final safe = await decodeShareImport(
        encodeShareJson({
          'v': 1,
          'kind': 'profile',
          'settings': {
            'webserver': {'port': 9000},
            'subagent': {'maxDepth': 2},
          },
        }),
      ) as DecodedSharePayload;
      expect((safe.payload as ProfileShare).settings.keys, ['subagent']);
    });
  });

  testWidgets('a compressed large import yields the UI event loop before finishing', (tester) async {
    // This tiny encoded file expands to several MiB. Do not use compressed
    // length as a reason to fall back to synchronous decoding.
    final code = encodeShareJson(
      _conversation(
        entries: [
          for (var i = 0; i < 24; i++) {'type': 'reply', 't': i, 'text': '字😀' * 80000},
        ],
      ),
    );
    expect(code.length, lessThan(100000));
    await tester.runAsync(() async {
      var finished = false;
      final pending = decodeShareImport(code).then((value) {
        finished = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse, reason: 'the UI event loop can run while the worker parses the body');
      final decoded = await pending as DecodedShareConversation;
      expect(decoded.conversation.share.entries, hasLength(24));
    });
  });
}
