import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../bridge/bridge.dart';

enum AudioState { idle, listening, speaking }

/// Tracks microphone / pipeline state.
final audioStateProvider = StateProvider<AudioState>((ref) => AudioState.idle);

/// Current viseme mouth-shape ID being displayed on the avatar.
final currentVisemeIdProvider = StateProvider<int>((ref) => 0);

/// Latest viseme JSON emitted by the conversation pipeline.
/// Kept for backwards-compat with any consumers still reading the raw JSON.
final pendingVisemesProvider = StateProvider<String>((ref) => '[]');

/// Subscribes to the Rust avatar state stream and exposes it as a Riverpod
/// stream provider.  The avatar widget watches this instead of driving a
/// Flutter-side timer.
final avatarStateStreamProvider = StreamProvider<AvatarState>((ref) {
  return avatarStateStream();
});
