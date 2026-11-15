import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/backend_api.dart';
import 'screens/voice_screen.dart';
import 'app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  runApp(VoiceApp(api: BackendApi(preferences)));
}

class VoiceApp extends StatelessWidget {
  const VoiceApp({super.key, required this.api});
  final BackendApi api;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'GPT Live',
    debugShowCheckedModeBanner: false,
    theme: StudioTheme.light,
    home: VoiceScreen(api: api),
  );
}
