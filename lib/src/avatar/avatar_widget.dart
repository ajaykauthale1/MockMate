import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/audio_provider.dart';
import '../theme/ske_theme.dart';
import 'avatar_painter.dart';

class AvatarWidget extends ConsumerStatefulWidget {
  final double size;
  const AvatarWidget({super.key, this.size = 180});

  @override
  ConsumerState<AvatarWidget> createState() => _AvatarWidgetState();
}

class _AvatarWidgetState extends ConsumerState<AvatarWidget> {
  Timer? _visemeTimer;

  @override
  void initState() {
    super.initState();
    // React to new viseme sequences emitted by the conversation pipeline.
    ref.listenManual(pendingVisemesProvider, (_, json) {
      if (json != '[]') _playVisemes(json);
    });
  }

  void _playVisemes(String json) {
    _visemeTimer?.cancel();
    ref.read(currentVisemeIdProvider.notifier).state = 0;

    final List<dynamic> raw;
    try {
      raw = jsonDecode(json) as List<dynamic>;
    } catch (_) {
      return;
    }
    if (raw.isEmpty) {
      ref.read(audioStateProvider.notifier).state = AudioState.idle;
      return;
    }

    final ids = raw.map((e) => (e['id'] as num).toInt()).toList();
    int i = 0;

    _visemeTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (!mounted || i >= ids.length) {
        t.cancel();
        if (mounted) {
          ref.read(currentVisemeIdProvider.notifier).state = 0;
          ref.read(audioStateProvider.notifier).state = AudioState.idle;
        }
        return;
      }
      ref.read(currentVisemeIdProvider.notifier).state = ids[i++];
    });
  }

  @override
  void dispose() {
    _visemeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visemeId = ref.watch(currentVisemeIdProvider);
    final audioState = ref.watch(audioStateProvider);
    final s = widget.size;

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
            decoration: skeRaised(radius: s / 2, color: SkeColors.panel),
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
    final color = switch (audioState) {
      AudioState.idle => SkeColors.textSecondary,
      AudioState.listening => Colors.greenAccent,
      AudioState.speaking => SkeColors.accent,
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
      builder: (_, __) {
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
