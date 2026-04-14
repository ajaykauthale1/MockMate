import 'package:flutter/material.dart';
import 'chat/chat_page.dart';
import 'interview/interview_page.dart';
import 'settings/settings_screen.dart';
import 'theme/ske_theme.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(
        title: Text('MockMate',
            style: TextStyle(
                color: c.accent,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
        actions: [
          const ThemeToggleButton(),
          IconButton(
            icon: Icon(Icons.settings_outlined, color: c.textSecondary),
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
                Text(
                  'What would you like to do?',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Practice with your knowledge base or take a coding challenge.',
                  style: TextStyle(color: c.textSecondary, fontSize: 13),
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
    final c = context.appColors;
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
            ? c.sunken(radius: 14)
            : c.raised(
                radius: 14,
                color: widget.accent
                    ? c.accent.withValues(alpha: 0.08)
                    : c.panel,
              ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: widget.accent
                    ? c.accent.withValues(alpha: 0.15)
                    : c.userBubble,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                widget.icon,
                color: widget.accent ? c.accent : c.textPrimary,
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
                      color: widget.accent ? c.accent : c.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    widget.subtitle,
                    style: TextStyle(color: c.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: c.textSecondary, size: 20),
          ],
        ),
      ),
    );
  }
}
