import 'package:flutter/material.dart';

import 'features/home/home_screen.dart';

void main() {
  runApp(const AkisApp());
}

class AkisApp extends StatelessWidget {
  const AkisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Akış',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.redAccent,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
