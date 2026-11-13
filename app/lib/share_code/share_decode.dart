// Share imports do their CPU work off the UI isolate: the envelope, raw
// DEFLATE, checksums, JSON, entry validation and picture decoding stay together.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';
import 'conversation_share.dart';
import 'share_codec.dart';
import 'share_models.dart';

sealed class DecodedShareImport {
  const DecodedShareImport();
}

final class DecodedSharePayload extends DecodedShareImport {
  const DecodedSharePayload(this.payload);

  final SharePayload payload;
}

final class DecodedShareConversation extends DecodedShareImport {
  const DecodedShareConversation(this.conversation);

  final DecodedConversation conversation;
}

/// Opens a code or file's text, optionally pinned to a Gist link's checksum.
/// Capture the app's fallback title here: worker isolates have their own locale.
Future<DecodedShareImport> decodeShareImport(String text, {String? expectedChecksum}) => compute(
  _decodeShareImport,
  _ShareDecodeRequest(text: text, fallbackTitle: appL10n.pluginsChat, expectedChecksum: expectedChecksum),
);

/// File reads and hosted downloads already yield bytes; decode UTF-8 in the
/// worker too, instead of first allocating the whole file string on the UI.
Future<DecodedShareImport> decodeShareImportBytes(Uint8List bytes) =>
    compute(_decodeShareImport, _ShareDecodeRequest(bytes: bytes, fallbackTitle: appL10n.pluginsChat));

/// Hosted links contain conversations only (not installable profiles/plugins).
Future<DecodedConversation> decodeConversationImportBytes(Uint8List bytes) async {
  final decoded = await compute(
    _decodeShareImport,
    _ShareDecodeRequest(bytes: bytes, fallbackTitle: appL10n.pluginsChat, conversationOnly: true),
  );
  return (decoded as DecodedShareConversation).conversation;
}

// Only data crosses this boundary; never capture a context, provider or client.
final class _ShareDecodeRequest {
  const _ShareDecodeRequest({
    this.text,
    this.bytes,
    required this.fallbackTitle,
    this.expectedChecksum,
    this.conversationOnly = false,
  });

  final String? text;
  final Uint8List? bytes;
  final String fallbackTitle;
  final String? expectedChecksum;
  final bool conversationOnly;
}

DecodedShareImport _decodeShareImport(_ShareDecodeRequest request) {
  final envelope = readShareEnvelope(request.text ?? utf8.decode(request.bytes!));
  if (request.expectedChecksum case final sum?) {
    // Same pin as fetchShareLinkText, including escaped JSON envelope keys.
    if (!RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{8}$').hasMatch(envelope.code) || !envelope.code.endsWith('.$sum')) {
      throw const ShareDecodeException('gist changed');
    }
  }
  final json = decodeShareJson(envelope.code, large: true);
  if (request.conversationOnly || ShareKind.parse(json['kind']) == ShareKind.conversation) {
    final share = ConversationShare.fromJson(json, fallbackTitle: request.fallbackTitle);
    return DecodedShareConversation(
      DecodedConversation(share, readConversationAssets(envelope.assets, share), code: envelope.code),
    );
  }
  return DecodedSharePayload(SharePayload.fromJson(json));
}
