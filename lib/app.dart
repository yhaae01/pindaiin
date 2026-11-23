import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/services/app_services.dart';
import 'core/services/file_repository.dart';
import 'core/theme/app_theme.dart';
import 'features/converter/converter_controller.dart';
import 'features/files/files_controller.dart';
import 'features/home/home_shell.dart';

class PindaiinApp extends StatelessWidget {
  const PindaiinApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppServices>.value(value: services),
        ChangeNotifierProvider<FileRepository>.value(value: services.repository),
        ChangeNotifierProvider(create: (_) => FilesController(services: services)),
        ChangeNotifierProvider(
          create: (_) => ConverterController(services: services),
        ),
      ],
      child: MaterialApp(
        title: 'Pindaiin',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: const _StartupFade(child: HomeShell()),
      ),
    );
  }
}

/// Bridges the native splash into the first Flutter frame.
///
/// The first frame paints only the splash color (which matches
/// flutter_native_splash), then the home screen fades in over 240 ms. No logo is
/// drawn twice, so there is no visible "double splash".
class _StartupFade extends StatefulWidget {
  const _StartupFade({required this.child});

  final Widget child;

  @override
  State<_StartupFade> createState() => _StartupFadeState();
}

class _StartupFadeState extends State<_StartupFade>
    with SingleTickerProviderStateMixin {
  // Keep these in sync with the flutter_native_splash colors in pubspec.yaml.
  static const _lightSplash = Color(0xFF0F766E);
  static const _darkSplash = Color(0xFF082F2D);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    // Wait for the first frame: the native splash is removed only after that.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final splashColor = Theme.of(context).brightness == Brightness.dark
        ? _darkSplash
        : _lightSplash;
    return ColoredBox(
      color: splashColor,
      child: FadeTransition(opacity: _opacity, child: widget.child),
    );
  }
}
