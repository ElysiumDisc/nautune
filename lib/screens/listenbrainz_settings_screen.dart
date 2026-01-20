import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/listenbrainz_service.dart';

/// Settings screen for ListenBrainz integration
class ListenBrainzSettingsScreen extends StatefulWidget {
  const ListenBrainzSettingsScreen({super.key});

  @override
  State<ListenBrainzSettingsScreen> createState() => _ListenBrainzSettingsScreenState();
}

class _ListenBrainzSettingsScreenState extends State<ListenBrainzSettingsScreen> {
  final _service = ListenBrainzService();
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _service.initialize();
    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _connectAccount() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => const _ConnectAccountDialog(),
    );

    if (result != null && mounted) {
      setState(() => _isLoading = true);

      final success = await _service.saveCredentials(
        result['username']!,
        result['token']!,
      );

      if (mounted) {
        setState(() => _isLoading = false);

        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Connected as ${result['username']}'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Invalid token. Please check and try again.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
  }

  Future<void> _disconnect() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect ListenBrainz?'),
        content: const Text(
          'This will stop scrobbling and remove your credentials. '
          'Your listening history on ListenBrainz will not be affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      await _service.disconnect();
      setState(() {});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Disconnected from ListenBrainz'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _retryPending() async {
    setState(() => _isLoading = true);

    final count = await _service.retryPendingScrobbles();

    if (mounted) {
      setState(() => _isLoading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(count > 0
              ? 'Synced $count pending scrobbles'
              : 'No pending scrobbles to sync'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = _service.config;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ListenBrainz'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Info card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.music_note,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'ListenBrainz',
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    'Open source music listening statistics',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'ListenBrainz tracks your listening history and provides '
                          'personalized music recommendations based on your taste.',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 12),
                        TextButton.icon(
                          onPressed: () => launchUrl(
                            Uri.parse('https://listenbrainz.org'),
                            mode: LaunchMode.externalApplication,
                          ),
                          icon: const Icon(Icons.open_in_new, size: 18),
                          label: const Text('Learn more at listenbrainz.org'),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                if (config == null) ...[
                  // Not connected - show setup guide
                  _buildSetupGuide(context),
                ] else ...[
                  // Connected - show account info
                  _buildAccountCard(context, config),

                  const SizedBox(height: 16),

                  // Scrobbling toggle
                  _buildScrobblingCard(context, config),

                  const SizedBox(height: 16),

                  // Stats card
                  _buildStatsCard(context, config),

                  const SizedBox(height: 16),

                  // Pending scrobbles
                  if (_service.pendingScrobblesCount > 0)
                    _buildPendingCard(context),
                ],
              ],
            ),
    );
  }

  Widget _buildSetupGuide(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Connect Your Account',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),

            // Step by step guide
            _StepTile(
              number: 1,
              title: 'Create a ListenBrainz Account',
              description: 'If you don\'t have one, create a free account at listenbrainz.org',
              action: TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('https://listenbrainz.org/login/'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open ListenBrainz'),
              ),
            ),

            const Divider(height: 24),

            _StepTile(
              number: 2,
              title: 'Get Your User Token',
              description: 'Go to your ListenBrainz profile settings and copy your User Token',
              action: TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('https://listenbrainz.org/settings/'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open Settings'),
              ),
            ),

            const Divider(height: 24),

            _StepTile(
              number: 3,
              title: 'Enter Your Credentials',
              description: 'Enter your username and token below to connect',
              action: null,
            ),

            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _connectAccount,
                icon: const Icon(Icons.link),
                label: const Text('Connect Account'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountCard(BuildContext context, dynamic config) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, color: Colors.green, size: 20),
                ),
                const SizedBox(width: 12),
                Text(
                  'Connected',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.green,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(config.username),
              subtitle: const Text('ListenBrainz Username'),
              trailing: TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('https://listenbrainz.org/user/${config.username}'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('View Profile'),
              ),
            ),
            const Divider(),
            TextButton.icon(
              onPressed: _disconnect,
              icon: const Icon(Icons.link_off),
              label: const Text('Disconnect Account'),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScrobblingCard(BuildContext context, dynamic config) {
    final theme = Theme.of(context);

    return Card(
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('Enable Scrobbling'),
            subtitle: Text(
              config.scrobblingEnabled
                  ? 'Your listens are being recorded'
                  : 'Scrobbling is paused',
            ),
            value: config.scrobblingEnabled,
            onChanged: (value) async {
              await _service.setScrobblingEnabled(value);
              setState(() {});
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              'When enabled, tracks you listen to will be automatically '
              'submitted to ListenBrainz after playing for 50% or 4 minutes.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _syncCount() async {
    setState(() => _isLoading = true);

    final localBefore = _service.config?.totalScrobbles ?? 0;
    final serverCount = await _service.syncScrobbleCount();
    final localAfter = _service.config?.totalScrobbles ?? 0;

    if (mounted) {
      setState(() => _isLoading = false);

      String message;
      if (serverCount < 0) {
        message = 'Failed to sync with server';
      } else if (serverCount < localBefore) {
        // Server count is lower (cached/delayed)
        message = 'Server reports $serverCount (may be delayed). Keeping local count: $localAfter';
      } else {
        message = 'Synced! Total scrobbles: $serverCount';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Widget _buildStatsCard(BuildContext context, dynamic config) {
    final theme = Theme.of(context);
    final lastScrobble = config.lastScrobbleTime;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Statistics',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _syncCount,
                  icon: const Icon(Icons.sync, size: 18),
                  label: const Text('Sync'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _StatItem(
                    icon: Icons.music_note,
                    label: 'Total Scrobbles',
                    value: config.totalScrobbles.toString(),
                  ),
                ),
                Expanded(
                  child: _StatItem(
                    icon: Icons.access_time,
                    label: 'Last Scrobble',
                    value: lastScrobble != null
                        ? _formatRelativeTime(lastScrobble)
                        : 'Never',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingCard(BuildContext context) {
    final theme = Theme.of(context);
    final count = _service.pendingScrobblesCount;

    return Card(
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
      child: ListTile(
        leading: Icon(
          Icons.cloud_off,
          color: theme.colorScheme.error,
        ),
        title: Text('$count pending scrobbles'),
        subtitle: const Text('These will sync when you\'re online'),
        trailing: TextButton(
          onPressed: _retryPending,
          child: const Text('Retry Now'),
        ),
      ),
    );
  }

  String _formatRelativeTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${time.month}/${time.day}';
  }
}

class _StepTile extends StatelessWidget {
  final int number;
  final String title;
  final String description;
  final Widget? action;

  const _StepTile({
    required this.number,
    required this.title,
    required this.description,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              '$number',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: 8),
                action!,
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Icon(icon, color: theme.colorScheme.primary),
        const SizedBox(height: 8),
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Dialog for connecting ListenBrainz account
class _ConnectAccountDialog extends StatefulWidget {
  const _ConnectAccountDialog();

  @override
  State<_ConnectAccountDialog> createState() => _ConnectAccountDialogState();
}

class _ConnectAccountDialogState extends State<_ConnectAccountDialog> {
  final _usernameController = TextEditingController();
  final _tokenController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _showToken = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Connect to ListenBrainz'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter your ListenBrainz credentials:',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Username',
                hintText: 'Your ListenBrainz username',
                prefixIcon: Icon(Icons.person),
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter your username';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _tokenController,
              obscureText: !_showToken,
              decoration: InputDecoration(
                labelText: 'User Token',
                hintText: 'Paste your token here',
                prefixIcon: const Icon(Icons.key),
                border: const OutlineInputBorder(),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _showToken = !_showToken),
                    ),
                    IconButton(
                      icon: const Icon(Icons.paste),
                      onPressed: () async {
                        final data = await Clipboard.getData('text/plain');
                        if (data?.text != null) {
                          _tokenController.text = data!.text!;
                        }
                      },
                    ),
                  ],
                ),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter your token';
                }
                if (value.length < 20) {
                  return 'Token seems too short';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            Text(
              'Find your token at listenbrainz.org/settings/',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.pop(context, {
                'username': _usernameController.text.trim(),
                'token': _tokenController.text.trim(),
              });
            }
          },
          child: const Text('Connect'),
        ),
      ],
    );
  }
}
