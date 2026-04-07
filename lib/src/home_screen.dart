import 'package:flutter/material.dart';
import 'chat/chat_page.dart';
import 'interview/interview_page.dart';
import 'settings/settings_screen.dart';
import 'theme/ske_theme.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SkeColors.background,
      appBar: AppBar(
        title: const Text('MockMate',
            style: TextStyle(
                color: SkeColors.accent,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined,
                color: SkeColors.textSecondary),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'What would you like to do?',
                  style: TextStyle(
                    color: SkeColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Practice with your knowledge base or take a coding challenge.',
                  style: TextStyle(
                      color: SkeColors.textSecondary, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
                _ModeCard(
                  icon: Icons.chat_outlined,
                  title: 'General Interview',
                  subtitle: 'Q&A from your knowledge base.\nGuide or Test mode.',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ChatPage()),
                  ),
                ),
                const SizedBox(height: 16),
                _ModeCard(
                  icon: Icons.code,
                  title: 'Coding Interview',
                  subtitle:
                      'Solve a LeetCode-style problem.\nAI conducts the interview.',
                  accent: true,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const InterviewPage()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool accent;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.accent = false,
    required this.onTap,
  });

  @override
  State<_ModeCard> createState() => _ModeCardState();
}

class _ModeCardState extends State<_ModeCard> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) {
        setState(() => _down = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _down = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: _down
            ? skeSunken(radius: 14)
            : skeRaised(
                radius: 14,
                color: widget.accent
                    ? SkeColors.accent.withValues(alpha: 0.08)
                    : SkeColors.panel,
              ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: widget.accent
                    ? SkeColors.accent.withValues(alpha: 0.15)
                    : SkeColors.userBubble,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                widget.icon,
                color: widget.accent ? SkeColors.accent : SkeColors.textPrimary,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: TextStyle(
                      color: widget.accent
                          ? SkeColors.accent
                          : SkeColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    widget.subtitle,
                    style: const TextStyle(
                        color: SkeColors.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                color: SkeColors.textSecondary, size: 20),
          ],
        ),
      ),
    );
  }
}
