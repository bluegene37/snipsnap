import 'package:flutter/material.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
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
      title: 'SnipSnap',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}
