// 语音通话: talking with a conversation, hands free. The microphone is cut into
// utterances on the phone (speech/call capture: echo cancellation, a speech
// gate, 300 ms kept before each start); each utterance is recognized whole
// (DeepSeek's recognizer by default) and sent as an ordinary message; the reply
// is read aloud while it is still being written. Speaking over the reply stops
// it, and the turn with it (插话打断, on by default).
//
// The controller knows nothing of widgets or of where messages go: a
// [CallConversation] sends and reports the reply, a [VoiceCloud] recognizes,
// [voice] makes a fresh [SpeechOut] for each reply.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../speech_audio.dart';
import '../speech_out.dart';
import '../voice_cloud.dart';

enum CallPhase {
  /// Getting the microphone.
  starting,

  /// Waiting for the person to speak.
  listening,

  /// The person is speaking.
  hearing,

  /// Recognizing what was said, then waiting for the reply's first words.
  thinking,

  /// The reply is being read aloud.
  speaking,

  ended,
}

enum CallEnd { hungUp, permission, microphone, noRecognizer, background, failed }

/// The reply to what was last sent, so far.
class CallReply {
  const CallReply(this.text, {required this.done});

  /// Everything said so far (it only grows while [done] is false).
  final String text;

  /// The turn ended.
  final bool done;
}

/// Where a call's messages go and its replies come from.
abstract class CallConversation {
  /// Sends what the person said; false when it could not go.
  Future<bool> send(String text);

  /// The reply to the last [send], as it grows.
  Stream<CallReply> get replies;

  /// Stops the turn under way (the person spoke over it).
  Future<void> interrupt();

  /// Waiting on the person (an approval, a question): the call page shows it.
  bool get waiting;

  void dispose();
}

/// The person's choices for a call: speaking over her stops her; the
/// loudspeaker or the earpiece; [spokenHint] goes before the first message.
typedef CallChoices = ({bool bargeIn, bool speaker, String? spokenHint});

class VoiceCallController extends ChangeNotifier {
  VoiceCallController({
    required this.audio,
    required this.conversation,
    required this.recognizer,
    required this.voice,
    required this.choices,
    this.permission,
  });

  final SpeechAudio audio;
  final CallConversation conversation;

  /// The recognizer for this call; null when none can be had (the call ends).
  final Future<VoiceCloud?> Function() recognizer;

  /// A voice for one reply.
  final SpeechOut Function() voice;

  /// The saved choices, read as the call starts (they may still be loading
  /// when the page opens).
  final Future<CallChoices> Function() choices;
  bool _bargeIn = true;

  /// Put before the call's first message: asks for short spoken answers.
  String? _spokenHint;

  /// Asks for the microphone (the system dialog); false when refused.
  final Future<bool> Function()? permission;

  /// The microphone is being asked for: the dialog may pause the app.
  bool get asking => _asking;
  bool _asking = false;

  CallPhase _phase = CallPhase.starting;
  CallEnd? _ended;
  bool _muted = false;
  bool _speaker = true;
  double _micLevel = 0;
  double _voiceLevel = 0;
  String _heard = '';
  String _reply = '';
  Object? _error;
  bool _hinted = false;

  VoiceCloud? _cloud;
  StreamSubscription<SpeechAudioEvent>? _audioSub;
  StreamSubscription<CallReply>? _replySub;
  SpeechOut? _out;
  StreamSubscription<SpeechOutEvent>? _outSub;
  int _spoken = 0;
  bool _replyDone = true;
  int _turn = 0;
  int _recognizing = 0;
  bool _disposed = false;

  CallPhase get phase => _phase;
  CallEnd? get ended => _ended;
  bool get muted => _muted;
  bool get speaker => _speaker;
  double get micLevel => _micLevel;
  double get voiceLevel => _voiceLevel;

  /// What the person said last (recognized).
  String get heard => _heard;

  /// The reply being read (so far).
  String get reply => _reply;

  /// The last thing that went wrong without ending the call (recognition,
  /// sending, the voice); cleared when the next turn starts.
  Object? get error => _error;

  Future<void> start() async {
    _replySub = conversation.replies.listen(_onReply);
    _audioSub = audio.events.listen(_onAudio);
    final chosen = await choices();
    if (_disposed || _phase == CallPhase.ended) return;
    _bargeIn = chosen.bargeIn;
    _speaker = chosen.speaker;
    _spokenHint = chosen.spokenHint;
    notifyListeners();
    final cloud = await recognizer();
    if (_disposed || _phase == CallPhase.ended) return;
    if (cloud == null) {
      _end(CallEnd.noRecognizer);
      return;
    }
    _cloud = cloud;
    final ask = permission;
    if (ask != null) {
      _asking = true;
      final granted = await ask().catchError((Object _) => false);
      _asking = false;
      if (_disposed || _phase == CallPhase.ended) return;
      if (!granted) {
        _end(CallEnd.permission);
        return;
      }
    }
    final started = await audio.startCall(bargeIn: _bargeIn);
    if (_disposed || _phase == CallPhase.ended) {
      if (started == CallStart.ok) unawaited(audio.stopCall());
      return;
    }
    switch (started) {
      case CallStart.ok:
        _speaker = await audio.speaker(_speaker);
        _set(CallPhase.listening);
      case CallStart.permission:
        _end(CallEnd.permission);
      case CallStart.microphone || CallStart.unavailable:
        _end(CallEnd.microphone);
    }
  }

  void _onAudio(SpeechAudioEvent event) {
    if (_phase == CallPhase.ended) return;
    switch (event) {
      case MicLevel(:final value):
        _micLevel = value;
        notifyListeners();
      case SpeechStart(:final over):
        if (over || _phase == CallPhase.speaking) {
          // Spoken over her: she stops (the native side already cut its own
          // stream), and so does the turn behind her.
          _stopVoice();
          if (!_replyDone) unawaited(conversation.interrupt());
          _replyDone = true;
        }
        _set(CallPhase.hearing);
      case Utterance(:final wav, :final duration):
        unawaited(_recognize(wav, duration));
      case CallError():
        _end(CallEnd.failed);
      case PlayEvent() || PlayLevel():
        break;
    }
  }

  Future<void> _recognize(Uint8List wav, Duration duration) async {
    final cloud = _cloud;
    if (cloud == null || _muted) return;
    // Too short to be words (a cough, a knock).
    if (duration < const Duration(milliseconds: 350)) {
      if (_phase == CallPhase.hearing) _set(CallPhase.listening);
      return;
    }
    final mine = ++_recognizing;
    _error = null;
    _set(CallPhase.thinking);
    String text;
    try {
      text = await cloud.transcribe(wav);
    } catch (error) {
      if (_phase == CallPhase.ended || mine != _recognizing) return;
      _error = error;
      _set(CallPhase.listening);
      return;
    }
    if (_phase == CallPhase.ended || mine != _recognizing) return;
    if (text.trim().isEmpty) {
      _set(_out == null ? CallPhase.listening : CallPhase.speaking);
      return;
    }
    _heard = text.trim();
    _reply = '';
    _spoken = 0;
    _turn++;
    _replyDone = false;
    final hint = _spokenHint;
    final message = !_hinted && hint != null ? '$hint\n$_heard' : _heard;
    _hinted = true;
    notifyListeners();
    final sent = await conversation.send(message);
    if (_phase == CallPhase.ended) return;
    if (!sent) {
      _replyDone = true;
      _error = const CallSendFailed();
      _set(CallPhase.listening);
    }
  }

  void _onReply(CallReply reply) {
    if (_phase == CallPhase.ended || _replyDone) return;
    final text = reply.text;
    if (text.length > _spoken) {
      final out = _out ??= _newVoice();
      out.add(text.substring(_spoken));
      _spoken = text.length;
      _reply = text;
      notifyListeners();
    }
    if (reply.done) {
      _replyDone = true;
      final out = _out;
      if (out == null) {
        // Nothing to say (the turn only ran tools, or was stopped).
        if (_phase == CallPhase.thinking) _set(CallPhase.listening);
      } else {
        out.finish();
      }
    }
  }

  SpeechOut _newVoice() {
    final out = voice();
    final turn = _turn;
    _outSub = out.events.listen((event) {
      if (!identical(_out, out) || _phase == CallPhase.ended) return;
      switch (event) {
        case SpeechOutStarted():
          if (_phase == CallPhase.thinking || _phase == CallPhase.listening) _set(CallPhase.speaking);
        case SpeechOutLevel(:final value):
          _voiceLevel = value;
          notifyListeners();
        case SpeechOutDone():
          _clearVoice(out);
          if (_phase == CallPhase.speaking || (_phase == CallPhase.thinking && turn == _turn && _replyDone)) {
            _set(CallPhase.listening);
          }
        case SpeechOutFailed(:final error):
          _clearVoice(out);
          _error = error;
          if (_phase == CallPhase.speaking || _phase == CallPhase.thinking) _set(CallPhase.listening);
      }
    });
    return out;
  }

  void _clearVoice(SpeechOut out) {
    if (!identical(_out, out)) return;
    _out = null;
    unawaited(_outSub?.cancel());
    _outSub = null;
    _voiceLevel = 0;
  }

  void _stopVoice() {
    final out = _out;
    if (out == null) return;
    _clearVoice(out);
    out.stop();
  }

  /// The microphone hears nothing (and nothing is recorded) while muted.
  void setMuted(bool on) {
    if (_phase == CallPhase.ended) return;
    _muted = on;
    _micLevel = 0;
    unawaited(audio.mute(on));
    if (on && _phase == CallPhase.hearing) _set(CallPhase.listening);
    notifyListeners();
  }

  Future<void> setSpeaker(bool on) async {
    if (_phase == CallPhase.ended) return;
    _speaker = await audio.speaker(on);
    notifyListeners();
  }

  /// Tapped while she speaks: she stops, the reply goes on in the conversation.
  void skip() {
    if (_phase != CallPhase.speaking) return;
    _stopVoice();
    _replyDone = true;
    _set(CallPhase.listening);
  }

  void hangUp() => _end(CallEnd.hungUp);

  /// The app went to the background: Android gives a backgrounded app no
  /// microphone, so the call ends rather than listen to silence.
  void backgrounded() {
    if (!_asking) _end(CallEnd.background);
  }

  void _end(CallEnd why) {
    if (_phase == CallPhase.ended) return;
    _ended = why;
    _stopVoice();
    unawaited(audio.stopCall());
    unawaited(_replySub?.cancel());
    unawaited(_audioSub?.cancel());
    _set(CallPhase.ended);
  }

  void _set(CallPhase phase) {
    _phase = phase;
    if (!_disposed) notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    // Quiet first: the page is going away and listens no more.
    _disposed = true;
    _end(CallEnd.hungUp);
    conversation.dispose();
    super.dispose();
  }
}

/// What was said could not be sent (no engine, the conversation is busy elsewhere).
class CallSendFailed implements Exception {
  const CallSendFailed();
}
