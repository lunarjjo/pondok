import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

/// Pondok — Bedrock Mobile Server Manager.
///
/// Material 3 with DayNight: the theme follows the device preference
/// (dark/light) automatically, as the project brief requires.
class PondokApp extends StatelessWidget {
  const PondokApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3E8914), // bedrock-green
    );
    final schemeDark = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3E8914),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'Pondok',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: scheme.surface,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: schemeDark,
        scaffoldBackgroundColor: schemeDark.surface,
      ),
      // Mengikuti preferensi perangkat — tidak ada mode manual di v0.1.
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
