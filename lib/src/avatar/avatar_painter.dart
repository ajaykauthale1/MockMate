import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Mouth shape parameters per viseme ID.
// IDs follow the Preston Blair set as produced by FftVisemeExtractor:
//   0=silence  4=T/D/N  6=CH/SH  7=S/Z  8=R  11=OW  12=AW  13=AH
// ---------------------------------------------------------------------------

class _Mouth {
  final double openness; // height as fraction of face radius
  final double width; // half-width as fraction of face radius
  final bool roundLips; // true → oval, false → straight/teeth gap

  const _Mouth(
      {required this.openness,
      required this.width,
      required this.roundLips});
}

const _kMouths = <int, _Mouth>{
  0: _Mouth(openness: 0.00, width: 0.30, roundLips: false), // silence
  4: _Mouth(openness: 0.06, width: 0.28, roundLips: false), // T/D/N – tiny gap
  6: _Mouth(openness: 0.18, width: 0.22, roundLips: true), // CH/SH – round
  7: _Mouth(openness: 0.03, width: 0.32, roundLips: false), // S/Z – narrow slit
  8: _Mouth(openness: 0.12, width: 0.28, roundLips: true), // R – relaxed oval
  11: _Mouth(openness: 0.18, width: 0.18, roundLips: true), // OW – small O
  12: _Mouth(openness: 0.25, width: 0.26, roundLips: true), // AW – wide O
  13: _Mouth(openness: 0.35, width: 0.34, roundLips: true), // AH – open
};

_Mouth _mouthFor(int id) => _kMouths[id] ?? _kMouths[0]!;

// ---------------------------------------------------------------------------
// AvatarPainter
// ---------------------------------------------------------------------------

class AvatarPainter extends CustomPainter {
  final int visemeId;
  final bool isDark;

  const AvatarPainter({required this.visemeId, this.isDark = true});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.shortestSide / 2 * 0.88;

    // Colors adapt to theme so the face is never visually "black" in light mode.
    final faceBg   = isDark ? const Color(0xFF2A2848) : const Color(0xFF4E4580);
    final faceRing = isDark ? const Color(0x3FFFFFFF) : const Color(0x3F26251E);
    final feature  = isDark ? const Color(0xFFEDE8D8) : const Color(0xFFF7F4FF);

    // Face
    canvas.drawCircle(Offset(cx, cy), r, Paint()..color = faceBg);
    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..color = faceRing
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final fgPaint = Paint()..color = feature.withValues(alpha: 0.85);

    // Eyes
    final eyeY = cy - r * 0.20;
    final eyeOffX = r * 0.28;
    canvas.drawCircle(Offset(cx - eyeOffX, eyeY), r * 0.085, fgPaint);
    canvas.drawCircle(Offset(cx + eyeOffX, eyeY), r * 0.085, fgPaint);

    // Eyebrows
    final browPaint = Paint()
      ..color = feature.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.045
      ..strokeCap = StrokeCap.round;
    final browY = eyeY - r * 0.17;
    final bHalfW = r * 0.22;
    canvas.drawLine(
      Offset(cx - eyeOffX - bHalfW, browY),
      Offset(cx - eyeOffX + bHalfW, browY - r * 0.03),
      browPaint,
    );
    canvas.drawLine(
      Offset(cx + eyeOffX - bHalfW, browY - r * 0.03),
      Offset(cx + eyeOffX + bHalfW, browY),
      browPaint,
    );

    _drawMouth(canvas, cx, cy + r * 0.28, r);
  }

  void _drawMouth(Canvas canvas, double cx, double my, double r) {
    final m = _mouthFor(visemeId);
    final mW = r * m.width * 2;
    final mH = r * m.openness * 2;

    final feature = isDark ? const Color(0xFFEDE8D8) : const Color(0xFFF7F4FF);
    final cavity  = isDark ? const Color(0xCC000000) : const Color(0xFF2A2040);

    if (mH < r * 0.04) {
      canvas.drawLine(
        Offset(cx - mW / 2, my),
        Offset(cx + mW / 2, my),
        Paint()
          ..color = feature.withValues(alpha: 0.70)
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.05
          ..strokeCap = StrokeCap.round,
      );
      return;
    }

    final rect = Rect.fromCenter(
        center: Offset(cx, my),
        width: mW,
        height: mH.clamp(r * 0.08, double.infinity));

    if (m.roundLips) {
      canvas.drawOval(rect, Paint()..color = cavity.withValues(alpha: 0.88));
      canvas.drawOval(
          rect,
          Paint()
            ..color = feature.withValues(alpha: 0.72)
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * 0.045);
    } else {
      final rr = RRect.fromRectAndRadius(rect, Radius.circular(r * 0.04));
      canvas.drawRRect(rr, Paint()..color = cavity.withValues(alpha: 0.90));
      canvas.drawRRect(
          rr,
          Paint()
            ..color = feature.withValues(alpha: 0.70)
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * 0.04);
      canvas.drawLine(
        Offset(cx - mW / 2 + r * 0.04, my),
        Offset(cx + mW / 2 - r * 0.04, my),
        Paint()
          ..color = feature.withValues(alpha: 0.35)
          ..strokeWidth = r * 0.03
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(AvatarPainter old) =>
      old.visemeId != visemeId || old.isDark != isDark;
}
