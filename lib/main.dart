import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'utils/constants.dart';
import 'views/main_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await hotKeyManager.unregisterAll();
  } catch (e) {
    debugPrint('hotKeyManager init notice: $e');
  }
  runApp(const SnipSnapApp());
}

class SnipSnapApp extends StatelessWidget {
  const SnipSnapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SnipSnap - Screen Capture & Markup',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.canvasBg,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.accent,
          surface: AppColors.darkSurface,
        ),
        textTheme: GoogleFonts.interTextTheme(
          ThemeData.dark().textTheme,
        ),
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}
