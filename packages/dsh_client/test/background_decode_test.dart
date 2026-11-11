import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_client/src/json.dart';
import 'package:test/test.dart';

void main() {
  test('small and worker JSON readers keep tolerant decoding semantics', () async {
    for (final text in ['{"n":1}', '[true,null,"你好"]', 'not json', 'null']) {
      expect(await tryDecodeJsonAsync(text), tryDecodeJson(text));
      expect(await tryDecodeJsonBytesAsync(utf8.encode(text)), tryDecodeJson(text));
    }
    final text = jsonEncode({'text': '长对话😀' * 100000});
    expect(await tryDecodeJsonAsync(text), jsonDecode(text));
    expect(await tryDecodeJsonBytesAsync(utf8.encode(text)), jsonDecode(text));
    expect(await tryDecodeJsonAsync('${' ' * (256 * 1024)}bad'), isNull);
    // HTTP has always accepted malformed UTF-8 by substituting U+FFFD.
    final malformed = Uint8List.fromList([...utf8.encode('{"text":"${'x' * (256 * 1024)}'), 255, 34, 125]);
    expect((await tryDecodeJsonBytesAsync(malformed) as Map)['text'], endsWith('\uFFFD'));
  });

  test('worker snapshot matches synchronous parsing and carries no epoch', () async {
    final frame = {
      'type': 'snapshot',
      'cursor': 1000,
      'hasMore': true,
      'records': [
        for (var seq = 1; seq <= 1000; seq++)
          {
            'event': {'type': 'session/title', 'seq': seq, 'title': '标题 $seq'},
          },
      ],
      'projections': <String, Object?>{},
    };
    final expected = parseFollowFrame('s', frame, isResync: true) as SessionSnapshotEvent;
    final actual = await parseFollowFrameAsync('s', frame, isResync: true) as SessionSnapshotEvent;
    expect(actual.sessionId, expected.sessionId);
    expect(actual.cursor, expected.cursor);
    expect(actual.hasMore, expected.hasMore);
    expect(actual.isResync, isTrue);
    expect(actual.followEpoch, isNull, reason: 'ownership is attached only after the worker returns');
    expect(actual.events.map((e) => (e.seq, e.type)), expected.events.map((e) => (e.seq, e.type)));
    expect(
      actual.events.whereType<TitleChangedEvent>().map((e) => e.title),
      expected.events.whereType<TitleChangedEvent>().map((e) => e.title),
    );
    expect((await parseFollowFrameAsync('s', {'type': 'future-frame'})), isA<UnknownFrameEvent>());
  });

  test('compact active reply without durable records is parsed on a worker', () async {
    final frame = {
      'type': 'snapshot',
      'records': <Object?>[],
      'assistantStream': {
        'revision': 1000,
        'activeAttempt': {
          'attemptId': 'a',
          'nextIndex': 1000,
          'stream': [
            {'type': 'text-chunks', 'index': 0, 'texts': List.filled(1000, '文字😀'), 'time0': 0},
          ],
        },
      },
    };
    var finished = false;
    final pending = parseFollowFrameAsync('s', frame).then((value) {
      finished = true;
      return value as SessionSnapshotEvent;
    });
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse, reason: 'compact active reply parsing yields to the event loop');
    final snapshot = await pending;
    expect(snapshot.activeAttempt!.nextIndex, 1000);
    expect(snapshot.activeAttempt!.chunks, hasLength(1000));
  });

  test('large WebSocket frame cannot be overtaken by a delta or end', () async {
    final host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final text = 'large baseline 😀' * 100000;
    WebSocket? peer;
    host.listen((request) async {
      final socket = peer = await WebSocketTransformer.upgrade(request);
      socket.add(jsonEncode({'type': 'item', 'streamId': 's', 'value': text}));
      socket.add(jsonEncode({'type': 'item', 'streamId': 's', 'value': 'delta'}));
      socket.add(jsonEncode({'type': 'end', 'streamId': 's'}));
    });
    final carrier = DshHttpCarrier(DshConnection(Uri.parse('http://127.0.0.1:${host.port}')));
    final link = await carrier.openLink(const MuxOptions());
    addTearDown(() async {
      await link.close(1000, 'test complete');
      await peer?.close();
      await carrier.close();
      await host.close(force: true);
    });
    final frames = <Map<String, Object?>>[];
    final done = Completer<void>();
    link.start(
      onFrame: (frame) {
        frames.add(frame);
        if (frame['type'] == 'end') done.complete();
      },
      onLost: (failure, cause) => done.completeError(cause ?? failure),
    );
    await done.future.timeout(const Duration(seconds: 10));
    expect(frames.map((f) => f['type']), ['item', 'item', 'end']);
    expect(frames.map((f) => f['value']), [text, 'delta', null]);
  });

  for (final binary in [false, true]) {
    test('invalid ${binary ? 'binary' : 'JSON'} mux frame retains protocol failure', () async {
      final host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      WebSocket? peer;
      host.listen((request) async {
        final socket = peer = await WebSocketTransformer.upgrade(request);
        socket.add(binary ? <int>[1, 2, 3] : 'invalid json');
      });
      final carrier = DshHttpCarrier(DshConnection(Uri.parse('http://127.0.0.1:${host.port}')));
      final link = await carrier.openLink(const MuxOptions());
      addTearDown(() async {
        await link.close(1000, 'test complete');
        await peer?.close();
        await carrier.close();
        await host.close(force: true);
      });
      final lost = Completer<Object?>();
      link.start(onFrame: (_) => fail('invalid frame was delivered'), onLost: (_, cause) => lost.complete(cause));
      expect(await lost.future.timeout(const Duration(seconds: 5)), isA<DshProtocolException>());
    });
  }
}
