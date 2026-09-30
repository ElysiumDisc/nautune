import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/demo_mode_provider.dart';
import '../providers/session_provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _submitting = false;
  String? _errorMessage;

  late SessionProvider _sessionProvider;
  late DemoModeProvider _demoModeProvider;

  // Demo mode credentials - these are intentional for the built-in demo feature
  // Demo mode runs entirely offline with bundled sample content
  static const _demoUsername = 'tester';
  static const _demoPassword = 'testing';

  bool _looksLikeDemoRequest({String? serverValue}) {
    final server = serverValue ?? _serverController.text;
    return server.trim().isEmpty &&
        _usernameController.text.trim().toLowerCase() == _demoUsername &&
        _passwordController.text == _demoPassword;
  }

  void _fillDemoCredentials() {
    setState(() {
      _serverController.clear();
      _usernameController.text = _demoUsername;
      _passwordController.text = _demoPassword;
    });
  }

  @override
  void initState() {
    super.initState();
    _sessionProvider = Provider.of<SessionProvider>(context, listen: false);
    _demoModeProvider = Provider.of<DemoModeProvider>(context, listen: false);

    final session = _sessionProvider.session;
    if (session != null) {
      _serverController.text = session.serverUrl;
      _usernameController.text = session.username;
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Guards double taps, including the demo path, which awaits asset
    // loading before the session reports it is authenticating.
    if (_submitting) return;
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      if (_looksLikeDemoRequest()) {
        await _demoModeProvider.startDemoMode();
      } else {
        await _sessionProvider.login(
          serverUrl: _serverController.text.trim(),
          username: _usernameController.text.trim(),
          password: _passwordController.text,
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Consumer2<SessionProvider, DemoModeProvider>(
      builder: (context, session, demoMode, child) {
        final isLoading = session.isAuthenticating || _submitting;

        return Scaffold(
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF1E102D), Color(0xFF4B1D77)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            // Scrollable so the form stays reachable above the keyboard on
            // small phones instead of overflowing.
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: Card(
                      elevation: 12,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Welcome aboard',
                                style: theme.textTheme.titleLarge,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Sign in to your Jellyfin server to start the voyage.',
                                style: theme.textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 24),
                              TextFormField(
                                controller: _serverController,
                                decoration: const InputDecoration(
                                  labelText: 'Server URL',
                                  hintText: 'https://your-jellyfin-server.com',
                                ),
                                keyboardType: TextInputType.url,
                                textInputAction: TextInputAction.next,
                                autocorrect: false,
                                enableSuggestions: false,
                                validator: (value) {
                                  final trimmed = value?.trim() ?? '';
                                  if (trimmed.isEmpty) {
                                    if (_looksLikeDemoRequest(
                                      serverValue: value ?? '',
                                    )) {
                                      return null;
                                    }
                                    return 'Enter your server URL';
                                  }
                                  final lower = trimmed.toLowerCase();
                                  if (!lower.startsWith('http://') &&
                                      !lower.startsWith('https://')) {
                                    return 'URL must start with http:// or https://';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _usernameController,
                                decoration: const InputDecoration(
                                  labelText: 'Username',
                                ),
                                textInputAction: TextInputAction.next,
                                autocorrect: false,
                                enableSuggestions: false,
                                autofillHints: const [AutofillHints.username],
                                validator: (value) {
                                  if (value == null || value.trim().isEmpty) {
                                    return 'Enter your username';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _passwordController,
                                decoration: InputDecoration(
                                  labelText: 'Password',
                                  suffixIcon: IconButton(
                                    onPressed: () {
                                      setState(() {
                                        _obscurePassword = !_obscurePassword;
                                      });
                                    },
                                    icon: Icon(
                                      _obscurePassword
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                    ),
                                  ),
                                ),
                                obscureText: _obscurePassword,
                                textInputAction: TextInputAction.go,
                                autofillHints: const [AutofillHints.password],
                                onFieldSubmitted: (_) {
                                  if (!isLoading) _submit();
                                },
                                validator: (value) {
                                  if (value == null || value.isEmpty) {
                                    return 'Enter your password';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 24),
                              if (_errorMessage != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Text(
                                    _errorMessage!,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.error,
                                    ),
                                  ),
                                ),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton(
                                  onPressed: isLoading ? null : _submit,
                                  child: isLoading
                                      ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Text('Sign In'),
                                ),
                              ),
                              _buildDemoHint(theme),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDemoHint(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.explore, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Need a guided demo?', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                const Text(
                  'Leave the server blank and sign in with username tester '
                  'and password testing to explore the full review build.',
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _fillDemoCredentials,
                    child: const Text('Fill credentials'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
