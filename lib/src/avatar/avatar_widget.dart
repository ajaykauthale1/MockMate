import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/audio_provider.dart';
import '../theme/ske_theme.dart';
import 'avatar_painter.dart';

class AvatarWidget extends ConsumerWidget {
  final double size;
  const AvatarWidget({super.key, this.size = 180});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Drive viseme + audio state directly from the Rust stream.
    ref.listen(avatarStateStreamProvider, (_, next) {
      final s = next.valueOrNull;
      if (s == null) return;
      ref.read(currentVisemeIdProvider.notifier).state = s.visemeId;
      if (s.isListening) {
        ref.read(audioStateProvider.notifier).state = AudioState.listening;
      } else if (s.isSpeaking) {
        ref.read(audioStateProvider.notifier).state = AudioState.speaking;
      } else {
        ref.read(audioStateProvider.notifier).state = AudioState.idle;
      }
    });

    final visemeId = ref.watch(currentVisemeIdProvider);
    final audioState = ref.watch(audioStateProvider);
    final s = size;

    final c = context.appColors;
    return SizedBox(
      width: s + 20,
      height: s + 20,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (audioState == AudioState.listening) _PulsingRing(size: s),
          Container(
            width: s,
            height: s,
            decoration: c.raised(radius: s / 2, color: c.panel),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 80),
              child: CustomPaint(
                key: ValueKey(visemeId),
                size: Size(s * 0.88, s * 0.88),
                painter: AvatarPainter(visemeId: visemeId),
              ),
            ),
          ),
          Positioned(
            bottom: 12,
            right: 12,
            child: _StateDot(audioState: audioState),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// State indicator dot
// ---------------------------------------------------------------------------

class _StateDot extends StatelessWidget {
  final AudioState audioState;
  const _StateDot({required this.audioState});

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    final color = switch (audioState) {
      AudioState.idle => c.textSecondary,
      AudioState.listening => Colors.greenAccent,
      AudioState.speaking => c.accent,
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 4),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pulsing ring shown while listening
// ---------------------------------------------------------------------------

class _PulsingRing extends StatefulWidget {
  final double size;
  const _PulsingRing({required this.size});

  @override
  State<_PulsingRing> createState() => _PulsingRingState();
}

class _PulsingRingState extends State<_PulsingRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = _ctrl.value;
        return Container(
          width: widget.size + 8 + t * 14,
          height: widget.size + 8 + t * 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.greenAccent.withValues(alpha: 0.6 - t * 0.4),
              width: 2,
            ),
          ),
        );
      },
    );
  }
}
