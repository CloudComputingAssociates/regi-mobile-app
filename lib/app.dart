import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/chat_screen.dart';
import 'screens/login_screen.dart';
import 'services/auth_service.dart';
import 'state/chat_state.dart';
import 'widgets/mode_slider.dart';

class RegiChatApp extends StatefulWidget {
  const RegiChatApp({super.key});

  @override
  State<RegiChatApp> createState() => _RegiChatAppState();
}

class _RegiChatAppState extends State<RegiChatApp> {
  final AuthService _auth = AuthService();
  final ChatState _chat = ChatState();
  bool _bootstrapped = false;
  String? _bootstrapError;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _auth.initialize();
      final mode = await ModeSlider.loadPersistedMode();
      _chat.setMode(mode);
    } catch (e) {
      _bootstrapError = e.toString();
    }
    if (mounted) setState(() => _bootstrapped = true);
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthService>.value(value: _auth),
        ChangeNotifierProvider<ChatState>.value(value: _chat),
      ],
      child: MaterialApp(
        title: kIsWeb ? 'Mobile App' : 'RegiMenu',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF8B1A2B),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: !_bootstrapped
            ? _Splash(error: _bootstrapError)
            : Consumer<AuthService>(
                builder: (_, auth, __) => auth.isAuthenticated
                    ? const ChatScreen()
                    : const LoginScreen(),
              ),
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash({this.error});
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B1B1B),
      body: Center(
        child: error == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Startup error: $error',
                  style: const TextStyle(color: Colors.redAccent),
                  textAlign: TextAlign.center,
                ),
              ),
      ),
    );
  }
}
