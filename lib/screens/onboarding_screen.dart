import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import 'auth/login_screen.dart';

class OnboardingData {
  final String title;
  final String subtitle;
  final Widget illustration;

  const OnboardingData({
    required this.title,
    required this.subtitle,
    required this.illustration,
  });
}

class OnboardingScreen extends StatefulWidget {
  final AuthService auth;

  const OnboardingScreen({super.key, required this.auth});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _controller = PageController();
  int _index = 0;

  late final List<OnboardingData> _pages = const [
    OnboardingData(
      title: 'Your campus, one app.',
      subtitle:
          'Chat with friends, reach your faculty, and never miss an official notice — all inside your college\u2019s own app.',
      illustration: CampusIllustration(),
    ),
    OnboardingData(
      title: 'Private by design.',
      subtitle:
          'No phone numbers, ever. Your PRN is your identity.',
      illustration: PrivateIllustration(),
    ),
    OnboardingData(
      title: 'Built for college life.',
      subtitle:
          'Class broadcasts, QR friend-adding, voice notes, notices with receipts.',
      illustration: CollegeLifeIllustration(),
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_index < _pages.length - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => LoginScreen(auth: widget.auth)),
      );
    }
  }

  void _skip() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => LoginScreen(auth: widget.auth)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _index == _pages.length - 1;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar with Skip (top-right).
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  const SizedBox(width: 72), // balances Skip for centering feel
                  Expanded(
                    child: Text(
                      'MERIDiAN',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2,
                          ),
                    ),
                  ),
                  SizedBox(
                    width: 72,
                    child: TextButton(
                      onPressed: _skip,
                      child: const Text('Skip'),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) {
                  final page = _pages[i];
                  return OnboardingPageBody(
                    title: page.title,
                    subtitle: page.subtitle,
                    illustration: page.illustration,
                  );
                },
              ),
            ),
            // Dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pages.length, (i) {
                final active = i == _index;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  height: 8,
                  width: active ? 24 : 8,
                  decoration: BoxDecoration(
                    color: active
                        ? AppColors.primary
                        : AppColors.dotInactive,
                    borderRadius: BorderRadius.circular(99),
                  ),
                );
              }),
            ),
            const SizedBox(height: 24),
            // Primary button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: FilledButton(
                onPressed: _next,
                child: Text(isLast ? 'Get Started' : 'Next'),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Page ${_index + 1} of ${_pages.length}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.subtext),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class OnboardingPageBody extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget illustration;

  const OnboardingPageBody({
    super.key,
    required this.title,
    required this.subtitle,
    required this.illustration,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const SizedBox(height: 16),
          Expanded(child: Center(child: illustration)),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: AppColors.ink,
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                ),
          ),
          const SizedBox(height: 12),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: AppColors.subtext,
                  height: 1.5,
                ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Page 1: diverse students chatting, floating chat bubbles, shield behind.
class CampusIllustration extends StatelessWidget {
  const CampusIllustration({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 280,
      width: 300,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Shield behind
          Container(
            height: 220,
            width: 220,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
          ),
          Container(
            height: 175,
            width: 175,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: const Icon(
              Icons.shield_rounded,
              size: 88,
              color: AppColors.primary,
            ),
          ),
          // Students row
          Positioned(
            bottom: 18,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                StudentAvatar(
                  initials: 'AR',
                  bg: Color(0xFFF59E0B),
                  offset: Offset(-14, 0),
                ),
                StudentAvatar(
                  initials: 'PK',
                  bg: Color(0xFF4F46E5),
                  big: true,
                ),
                StudentAvatar(
                  initials: 'SN',
                  bg: Color(0xFF10B981),
                  offset: Offset(14, 0),
                ),
              ],
            ),
          ),
          // Floating chat bubbles
          const Positioned(
            left: 8,
            top: 36,
            child: ChatBubble(text: 'Hey! 👋', mine: false),
          ),
          const Positioned(
            right: 6,
            top: 78,
            child: ChatBubble(text: 'Notice 📌', mine: true),
          ),
          const Positioned(
            left: 22,
            bottom: 78,
            child: ChatBubble(text: 'Faculty ✓✓', mine: false, small: true),
          ),
        ],
      ),
    );
  }
}

/// Page 2: private by design — shield + PRN identity card.
class PrivateIllustration extends StatelessWidget {
  const PrivateIllustration({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 280,
      width: 300,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            height: 220,
            width: 220,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
          ),
          Container(
            width: 210,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      height: 48,
                      width: 48,
                      decoration: const BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.person_rounded,
                          color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Student ID',
                              style: TextStyle(
                                  fontSize: 12, color: AppColors.subtext)),
                          Text('PRN: 2024XXXX',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.ink)),
                        ],
                      ),
                    ),
                    const Icon(Icons.verified_rounded,
                        color: AppColors.primary),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock_rounded,
                          size: 16, color: AppColors.primary),
                      SizedBox(width: 6),
                      Text('No phone number needed',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.ink)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Positioned(
            right: 12,
            top: 34,
            child: ChatBubble(text: 'PRN ✓', mine: true, small: true),
          ),
          const Positioned(
            left: 12,
            bottom: 40,
            child: ChatBubble(text: '🔒 Private', mine: false, small: true),
          ),
        ],
      ),
    );
  }
}

/// Page 3: built for college life — broadcasts, QR, voice, notices.
class CollegeLifeIllustration extends StatelessWidget {
  const CollegeLifeIllustration({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 280,
      width: 300,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            height: 220,
            width: 220,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _FeatureTile(
                  icon: Icons.campaign_rounded, label: 'Broadcast'),
              const SizedBox(width: 12),
              _FeatureTile(icon: Icons.qr_code_2_rounded, label: 'QR Add'),
              const SizedBox(width: 12),
              _FeatureTile(icon: Icons.mic_rounded, label: 'Voice'),
            ],
          ),
          const Positioned(
            top: 30,
            child: ChatBubble(text: '📢 Class at 10!', mine: true),
          ),
          const Positioned(
            bottom: 26,
            child: ChatBubble(
                text: 'Notice received ✓✓', mine: false, small: true),
          ),
        ],
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  final IconData icon;
  final String label;

  const _FeatureTile({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 84,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppColors.primary, size: 30),
          const SizedBox(height: 8),
          Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.ink)),
        ],
      ),
    );
  }
}

class StudentAvatar extends StatelessWidget {
  final String initials;
  final Color bg;
  final bool big;
  final Offset offset;

  const StudentAvatar({
    super.key,
    required this.initials,
    required this.bg,
    this.big = false,
    this.offset = Offset.zero,
  });

  @override
  Widget build(BuildContext context) {
    final size = big ? 72.0 : 60.0;
    return Transform.translate(
      offset: offset,
      child: Container(
        height: size,
        width: size,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Text(
          initials,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 16,
          ),
        ),
      ),
    );
  }
}

class ChatBubble extends StatelessWidget {
  final String text;
  final bool mine;
  final bool small;

  const ChatBubble({
    super.key,
    required this.text,
    this.mine = false,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? 10 : 14,
        vertical: small ? 6 : 10,
      ),
      decoration: BoxDecoration(
        color: mine ? AppColors.primary : Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(mine ? 16 : 4),
          bottomRight: Radius.circular(mine ? 4 : 16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        text,
        style: TextStyle(
          color: mine ? Colors.white : AppColors.ink,
          fontWeight: FontWeight.w600,
          fontSize: small ? 12 : 13,
        ),
      ),
    );
  }
}
