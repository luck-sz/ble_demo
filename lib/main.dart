import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme/app_theme.dart';
import 'pages/scan_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 设置状态栏为透明
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '蓝牙健身设备',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const ScanPage(),
    );
  }
}
