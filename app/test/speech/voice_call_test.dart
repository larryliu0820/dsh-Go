import 'dart:typed_data';

import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:flutter_test/flutter_test.dart';

import 'speech_fakes.dart';

class _Rig {
  _Rig({FakeCloud? cloud, bool noRecognizer = false, CallStart start = CallStart.ok, bool bargeIn = true})
    : audio = FakeAudio(start: start),
      cloud = cloud ?? FakeCloud() {
    call = VoiceCallController(
      audio: audio,
      conversation: conversation,
      recognizer: () async => noRecognizer ? null : this.cloud,
      voice: () {
        final out = FakeOut();
        outs.add(out);
        return out;
      },
      choices: () async => (bargeIn: bargeIn, speaker: true, spokenHint: '（语音通话）'),
    );
  }

  final FakeAudio audio;
  final FakeCloud cloud;
  final conversation = FakeConversation();
  final outs = <FakeOut>[];
  late final VoiceCallController call;

  static final second = Uint8List(44 + 32000);

  Future<void> say() async {
    audio.emit(const SpeechStart(over: false));
    audio.emit(Utterance(second, const Duration(seconds: 1)));
    await pumpEventQueue();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a turn: heard, sent with the hint once, the reply read as it grows', () async {
    final rig = _Rig();
    await rig.call.start();
    expect(rig.call.phase, CallPhase.listening);
    expect(rig.audio.calls, contains('callStart:bargeIn=true'));

    rig.audio.emit(const SpeechStart(over: false));
    expect(rig.call.phase, CallPhase.hearing);
    rig.audio.emit(Utterance(_Rig.second, const Duration(seconds: 1)));
    await pumpEventQueue();
    expect(rig.call.phase, CallPhase.thinking);
    expect(rig.call.heard, '今天天气怎么样');
    expect(rig.conversation.sent, ['（语音通话）\n今天天气怎么样']);

    rig.conversation.reply('北京晴，');
    expect(rig.outs, hasLength(1));
    rig.outs.single.emit(const SpeechOutStarted());
    expect(rig.call.phase, CallPhase.speaking);
    rig.conversation.reply('北京晴，最高二十度。');
    rig.conversation.reply('北京晴，最高二十度。', done: true);
    expect(rig.outs.single.added, ['北京晴，', '最高二十度。']);
    expect(rig.outs.single.finished, isTrue);
    rig.outs.single.emit(const SpeechOutDone());
    expect(rig.call.phase, CallPhase.listening);

    // The next message goes without the hint.
    rig.cloud.text = '那上海呢';
    await rig.say();
    expect(rig.conversation.sent.last, '那上海呢');
  });

  test('speaking over her stops her and the turn', () async {
    final rig = _Rig();
    await rig.call.start();
    await rig.say();
    rig.conversation.reply('好的，我来详细说一说。');
    rig.outs.single.emit(const SpeechOutStarted());
    expect(rig.call.phase, CallPhase.speaking);

    rig.audio.emit(const SpeechStart(over: true));
    expect(rig.outs.single.stopped, isTrue);
    expect(rig.conversation.interrupts, 1);
    expect(rig.call.phase, CallPhase.hearing);

    // What she was still writing is no longer read.
    rig.conversation.reply('好的，我来详细说一说。第一点', done: true);
    expect(rig.outs, hasLength(1));
  });

  test('a knock is not a sentence', () async {
    final rig = _Rig();
    await rig.call.start();
    rig.audio.emit(const SpeechStart(over: false));
    rig.audio.emit(Utterance(_Rig.second, const Duration(milliseconds: 200)));
    await pumpEventQueue();
    expect(rig.cloud.heard, isEmpty);
    expect(rig.call.phase, CallPhase.listening);
  });

  test('nothing recognized: back to listening, nothing sent', () async {
    final rig = _Rig(cloud: FakeCloud(''));
    await rig.call.start();
    await rig.say();
    expect(rig.conversation.sent, isEmpty);
    expect(rig.call.phase, CallPhase.listening);
  });

  test('recognition fails: the call goes on and says why', () async {
    final cloud = FakeCloud()..fail = const DeepSeekSpeechError(DeepSeekSpeechFailure.insufficientBalance);
    final rig = _Rig(cloud: cloud);
    await rig.call.start();
    await rig.say();
    expect(rig.call.phase, CallPhase.listening);
    expect(rig.call.error, isA<DeepSeekSpeechError>());
  });

  test('a reply with nothing to say (tools only) returns to listening', () async {
    final rig = _Rig();
    await rig.call.start();
    await rig.say();
    rig.conversation.reply('', done: true);
    expect(rig.outs, isEmpty);
    expect(rig.call.phase, CallPhase.listening);
  });

  test('no recognizer, no permission: it ends and says so', () async {
    final none = _Rig(noRecognizer: true);
    await none.call.start();
    expect(none.call.phase, CallPhase.ended);
    expect(none.call.ended, CallEnd.noRecognizer);
    expect(none.audio.calls, isNot(contains('callStart:bargeIn=true')));

    final denied = _Rig(start: CallStart.permission);
    await denied.call.start();
    expect(denied.call.ended, CallEnd.permission);
  });

  test('mute, loudspeaker and hang up reach the native side', () async {
    final rig = _Rig(bargeIn: false);
    await rig.call.start();
    expect(rig.audio.calls, contains('callStart:bargeIn=false'));
    rig.call.setMuted(true);
    expect(rig.call.muted, isTrue);
    await rig.call.setSpeaker(false);
    expect(rig.call.speaker, isFalse);
    rig.call.hangUp();
    expect(rig.call.phase, CallPhase.ended);
    expect(rig.audio.calls, containsAllInOrder(['mute:true', 'speaker:false', 'callStop']));
  });

  test('skip: she stops, the call listens again', () async {
    final rig = _Rig();
    await rig.call.start();
    await rig.say();
    rig.conversation.reply('一段很长的回答。');
    rig.outs.single.emit(const SpeechOutStarted());
    rig.call.skip();
    expect(rig.outs.single.stopped, isTrue);
    expect(rig.call.phase, CallPhase.listening);
    expect(rig.conversation.interrupts, 0);
  });
}
