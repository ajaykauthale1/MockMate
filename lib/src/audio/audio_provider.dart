import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AudioState { idle, listening, speaking }

/// Tracks microphone / pipeline state.
final audioStateProvider = StateProvider<AudioState>((ref) => AudioState.idle);

/// Current viseme mouth-shape ID being displayed on the avatar.
final currentVisemeIdProvider = StateProvider<int>((ref) => 0);

/// Latest viseme JSON emitted by the conversation pipeline.
/// AvatarWidget listens to this and drives the animation timer.
final pendingVisemesProvider = StateProvider<String>((ref) => '[]');
