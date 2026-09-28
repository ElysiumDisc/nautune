import 'package:flutter/material.dart';

import '../services/lastfm_service.dart';
import '../theme/nautune_theme.dart';
import '../widgets/ios/grouped_section.dart';

/// Connect Last.fm scrobbling with the user's own API account.
class LastFmSettingsScreen extends StatefulWidget {
  const LastFmSettingsScreen({super.key});

  @override
  State<LastFmSettingsScreen> createState() => _LastFmSettingsScreenState();
}

class _LastFmSettingsScreenState extends State<LastFmSettingsScreen> {
  final _apiKey = TextEditingController();
  final _secret = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _connecting = false;
  String? _error;

  LastFmService get _service => LastFmService.instance;

  @override
  void dispose() {
    _apiKey.dispose();
    _secret.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await _service.connect(
        apiKey: _apiKey.text.trim(),
        secret: _secret.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
      );
      _password.clear();
    } catch (e) {
      _error = e is LastFmException && (e.code == 4 || e.code == 10 || e.code == 26)
          ? 'Check your username, password, API key and secret.'
          : 'Could not connect: $e';
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Last.fm')),
      body: ListenableBuilder(
        listenable: _service,
        builder: (context, _) {
          if (_service.isConfigured) {
            return ListView(
              children: [
                GroupedSection(
                  header: 'Account',
                  children: [
                    GroupedTile(
                      icon: Icons.person,
                      title: _service.username ?? 'Connected',
                      subtitle: 'Connected to Last.fm',
                    ),
                    GroupedTile(
                      icon: Icons.graphic_eq,
                      title: 'Scrobbling',
                      subtitle: 'After half the song or 4 minutes of listening',
                      trailing: Switch.adaptive(
                        value: _service.isScrobblingEnabled,
                        onChanged: _service.setEnabled,
                      ),
                    ),
                  ],
                ),
                GroupedSection(
                  header: 'Queue',
                  footer: 'Plays made offline are sent when you reconnect.',
                  children: [
                    GroupedTile(
                      icon: Icons.schedule_send,
                      title: '${_service.pendingCount} waiting to send',
                      trailing: TextButton(
                        onPressed: _service.pendingCount == 0 ? null : _service.flush,
                        child: const Text('Retry Now'),
                      ),
                    ),
                  ],
                ),
                GroupedSection(
                  children: [
                    GroupedTile(
                      icon: Icons.logout,
                      iconColor: theme.colorScheme.error,
                      title: 'Disconnect',
                      destructive: true,
                      onTap: _service.disconnect,
                      showChevron: false,
                    ),
                  ],
                ),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              GroupedSection(
                header: 'Your Last.fm API account',
                footer: 'Last.fm needs an API account per app. Create one (free) at '
                    'last.fm/api/account/create, then paste its API key and shared secret here.',
                children: [
                  _field(_apiKey, 'API key'),
                  _field(_secret, 'Shared secret', obscure: true),
                ],
              ),
              GroupedSection(
                header: 'Sign in',
                footer: 'Your password is only used to sign in and is not stored.',
                children: [
                  _field(_username, 'Username'),
                  _field(_password, 'Password', obscure: true),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(_error!, style: theme.textTheme.footnote.copyWith(color: theme.colorScheme.error)),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: _connecting ? null : _connect,
                  child: _connecting
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Connect'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _field(TextEditingController controller, String label, {bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: label,
          filled: false,
          border: InputBorder.none,
        ),
      ),
    );
  }
}
