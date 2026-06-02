import 'package:flutter/material.dart';
import '../services/block_service.dart';
import '../theme.dart';
import 'profile_screen.dart';

/// Lists the accounts the current user has blocked, with an unblock action.
class BlockedAccountsScreen extends StatefulWidget {
  const BlockedAccountsScreen({super.key});

  @override
  State<BlockedAccountsScreen> createState() => _BlockedAccountsScreenState();
}

class _BlockedAccountsScreenState extends State<BlockedAccountsScreen> {
  List<BlockedProfile>? _accounts;
  String? _error;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _accounts = null;
      _error = null;
    });
    try {
      final rows = await BlockService.blockedProfiles();
      if (mounted) setState(() => _accounts = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _unblock(BlockedProfile p) async {
    setState(() => _busy.add(p.id));
    try {
      await BlockService.unblock(p.id);
      if (mounted) {
        setState(() => _accounts?.removeWhere((x) => x.id == p.id));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Couldn\'t unblock: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(p.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(title: const Text('Blocked accounts')),
      body: NileMaxWidth(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                style:
                    NileTextStyles.bodyMd().copyWith(color: NileColors.error)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    final accounts = _accounts;
    if (accounts == null) {
      return const Center(
          child: CircularProgressIndicator(color: NileColors.volt));
    }
    if (accounts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.block, size: 48, color: NileColors.border),
            const SizedBox(height: 12),
            Text('No blocked accounts', style: NileTextStyles.headingSm()),
            const SizedBox(height: 4),
            Text('Accounts you block will appear here.',
                style: NileTextStyles.bodySm()),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: accounts.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _BlockedTile(
        profile: accounts[i],
        busy: _busy.contains(accounts[i].id),
        onUnblock: () => _unblock(accounts[i]),
      ),
    );
  }
}

class _BlockedTile extends StatelessWidget {
  final BlockedProfile profile;
  final bool busy;
  final VoidCallback onUnblock;
  const _BlockedTile({
    required this.profile,
    required this.busy,
    required this.onUnblock,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.md),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => ProfileScreen(userId: profile.id)),
            ),
            child: CircleAvatar(
              radius: 20,
              backgroundColor: NileColors.bgRaised,
              backgroundImage: profile.avatarUrl != null
                  ? NetworkImage(profile.avatarUrl!)
                  : null,
              child: profile.avatarUrl == null
                  ? Text(profile.username[0].toUpperCase(),
                      style:
                          NileTextStyles.labelMd().copyWith(letterSpacing: 0))
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(profile.displayName,
                    style: NileTextStyles.labelMd(),
                    overflow: TextOverflow.ellipsis),
                Text('@${profile.username}',
                    style: NileTextStyles.bodySm(),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: busy ? null : onUnblock,
            child: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: NileColors.txtPrimary),
                  )
                : const Text('Unblock'),
          ),
        ],
      ),
    );
  }
}
