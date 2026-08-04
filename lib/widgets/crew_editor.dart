import 'package:flutter/material.dart';

import '../services/crew_service.dart';
import '../services/favorites_service.dart';
import '../services/profile_service.dart';
import '../services/search_service.dart';
import '../theme.dart';

/// Mutable working state for the crew editor — how many cameras the stream will
/// use, and which people are on the crew. Owned by the parent screen so it can
/// persist on save/continue. Camera/device role assignment happens later, on the
/// Sound Check page — this editor only captures count + crew membership.
class CrewState {
  static const int maxCameras = 5;

  /// Number of cameras for the stream (1..maxCameras).
  int cameraCount;

  /// Chosen crew members, keyed by user id. No slot/device here.
  final Map<String, OperatorPick> operators;

  CrewState({this.cameraCount = 1, Map<String, OperatorPick>? operators})
    : operators = operators ?? {};
}

/// The cameras-count + crew picker, shared by the create flow and the edit
/// screen. Manages its own user search, favorites tab, and "assign myself"
/// affordance; mutates the passed-in [state] and calls [onChanged] so the
/// parent can rebuild dependent UI.
class CrewEditor extends StatefulWidget {
  final CrewState state;
  final VoidCallback? onChanged;

  /// Whether to render the camera-count stepper. False where the count is
  /// captured earlier (create page 1, edit screen) because pricing depends on
  /// it — this editor then covers crew membership only.
  final bool showCameras;

  const CrewEditor({
    super.key,
    required this.state,
    this.onChanged,
    this.showCameras = true,
  });

  @override
  State<CrewEditor> createState() => _CrewEditorState();
}

class _CrewEditorState extends State<CrewEditor> {
  final _searchController = TextEditingController();

  List<UserProfile> _results = [];
  bool _searching = false;

  bool _showFavorites = false;
  List<UserProfile> _favorites = [];
  final Set<String> _favoriteIds = {};
  UserProfile? _me;

  CrewState get _s => widget.state;

  @override
  void initState() {
    super.initState();
    _loadFavorites();
    _loadMe();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _bubble() {
    setState(() {});
    widget.onChanged?.call();
  }

  Future<void> _loadMe() async {
    final me = await ProfileService.fetchCurrentProfile();
    if (mounted) setState(() => _me = me);
  }

  Future<void> _loadFavorites() async {
    try {
      final favs = await FavoritesService.list();
      if (!mounted) return;
      setState(() {
        _favorites = favs;
        _favoriteIds
          ..clear()
          ..addAll(favs.map((f) => f.id));
      });
    } catch (_) {
      /* best-effort */
    }
  }

  Future<void> _toggleFavorite(UserProfile u) async {
    final wasFav = _favoriteIds.contains(u.id);
    setState(() {
      if (wasFav) {
        _favoriteIds.remove(u.id);
        _favorites.removeWhere((f) => f.id == u.id);
      } else {
        _favoriteIds.add(u.id);
        if (!_favorites.any((f) => f.id == u.id)) _favorites.insert(0, u);
      }
    });
    try {
      wasFav
          ? await FavoritesService.remove(u.id)
          : await FavoritesService.add(u.id);
    } catch (_) {
      if (mounted) _loadFavorites();
    }
  }

  void _addCamera() {
    if (_s.cameraCount >= CrewState.maxCameras) return;
    _s.cameraCount++;
    _bubble();
  }

  void _removeCamera() {
    if (_s.cameraCount <= 1) return;
    _s.cameraCount--;
    _bubble();
  }

  Future<void> _search(String q) async {
    final query = q.trim();
    if (query.isEmpty) {
      setState(() {
        _results = [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final page = await SearchService.searchUsers(query);
      if (!mounted) return;
      setState(() {
        _results = page.items;
        _searching = false;
      });
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _toggleOperator(UserProfile u) {
    if (_s.operators.containsKey(u.id)) {
      _s.operators.remove(u.id);
    } else {
      _s.operators[u.id] = OperatorPick(u);
    }
    _bubble();
  }

  List<Widget> _favoritesList() {
    final visible = _favorites.where((f) => f.id != _me?.id).toList();
    if (visible.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
          child: Text(
            'No favorites yet. Tap the star next to anyone in Search to add '
            'them here for quick assignment next time.',
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
        ),
      ];
    }
    return [
      for (final u in visible)
        _OperatorResultTile(
          user: u,
          selected: _s.operators.containsKey(u.id),
          favorited: true,
          onTap: () => _toggleOperator(u),
          onToggleFavorite: () => _toggleFavorite(u),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showCameras) ...[
          _StepHeader(
            number: 1,
            title: 'Cameras',
            subtitle: 'How many cameras will this stream use?',
          ),
          const SizedBox(height: 12),
          CameraStepper(
            count: _s.cameraCount,
            max: CrewState.maxCameras,
            onAdd: _addCamera,
            onRemove: _removeCamera,
          ),
          const SizedBox(height: 16),
          Divider(color: NileColors.border),
          const SizedBox(height: 16),
        ],
        _StepHeader(
          number: widget.showCameras ? 2 : 1,
          title: 'Choose Your Crew',
          subtitle:
              'Crew members get free access and a notification. '
              'You\'ll assign cameras and devices during Sound Check.',
        ),
        const SizedBox(height: 12),
        if (_me != null && !_s.operators.containsKey(_me!.id))
          _AssignMyselfTile(me: _me!, onTap: () => _toggleOperator(_me!)),
        if (_s.operators.isNotEmpty) ...[
          const SizedBox(height: 4),
          for (final pick in _s.operators.values)
            _OperatorAssignedRow(
              pick: pick,
              isMe: pick.profile.id == _me?.id,
              onRemove: () => _toggleOperator(pick.profile),
            ),
          const SizedBox(height: 4),
        ],
        _PickerTabs(
          showFavorites: _showFavorites,
          favoriteCount: _favorites.length,
          onChanged: (fav) => setState(() => _showFavorites = fav),
        ),
        const SizedBox(height: 10),
        if (_showFavorites)
          ..._favoritesList()
        else ...[
          TextField(
            controller: _searchController,
            onChanged: _search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: 'Search people by name or @username',
              suffixIcon: _searching
                  ? Padding(
                      padding: EdgeInsets.all(NileSpacing.s12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: NileColors.volt,
                        ),
                      ),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          for (final u in _results)
            if (u.id != _me?.id)
              _OperatorResultTile(
                user: u,
                selected: _s.operators.containsKey(u.id),
                favorited: _favoriteIds.contains(u.id),
                onTap: () => _toggleOperator(u),
                onToggleFavorite: () => _toggleFavorite(u),
              ),
        ],
      ],
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _StepHeader extends StatelessWidget {
  final int number;
  final String title;
  final String subtitle;

  const _StepHeader({
    required this.number,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: NileColors.volt,
            shape: BoxShape.circle,
          ),
          child: Text(
            '$number',
            style: NileTextStyles.labelMd().copyWith(
              color: NileColors.onVolt,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: NileTextStyles.headingSm()),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: NileTextStyles.bodySm().copyWith(
                  color: NileColors.txtSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Minus / count / plus control for the number of cameras. Public so the
/// create flow and edit screen can host it next to the price field, where the
/// count drives the ticket floor.
class CameraStepper extends StatelessWidget {
  final int count;
  final int max;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  const CameraStepper({
    super.key,
    required this.count,
    required this.max,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8, vertical: NileSpacing.s4),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        border: Border.all(color: NileColors.border),
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            onPressed: count > 1 ? onRemove : null,
            icon: const Icon(Icons.remove),
            color: NileColors.txtPrimary,
            disabledColor: NileColors.txtTertiary,
          ),
          Text(
            '$count',
            style: NileTextStyles.headingSm().copyWith(letterSpacing: 0.5),
          ),
          IconButton(
            onPressed: count < max ? onAdd : null,
            icon: const Icon(Icons.add),
            color: NileColors.txtPrimary,
            disabledColor: NileColors.txtTertiary,
          ),
        ],
      ),
    );
  }
}

class _OperatorResultTile extends StatelessWidget {
  final UserProfile user;
  final bool selected;
  final bool favorited;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;

  const _OperatorResultTile({
    required this.user,
    required this.selected,
    required this.favorited,
    required this.onTap,
    required this.onToggleFavorite,
  });

  @override
  Widget build(BuildContext context) {
    final url = user.avatarUrl;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12, vertical: NileSpacing.s8),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: NileColors.bgRaised,
              backgroundImage: (url != null && url.isNotEmpty)
                  ? nileAvatarImage(url, 18)
                  : null,
              child: (url == null || url.isEmpty)
                  ? Icon(
                      Icons.person,
                      size: 18,
                      color: NileColors.txtTertiary,
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '@${user.username}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NileTextStyles.labelMd(),
                  ),
                  if (user.displayName.isNotEmpty)
                    Text(
                      user.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NileTextStyles.caption().copyWith(
                        color: NileColors.txtTertiary,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(favorited ? Icons.star : Icons.star_border, size: 20),
              color: favorited ? NileColors.volt : NileColors.txtTertiary,
              tooltip: favorited ? 'Remove favorite' : 'Add favorite',
              onPressed: onToggleFavorite,
            ),
            Icon(
              selected ? Icons.check_circle : Icons.add_circle_outline,
              color: selected ? NileColors.volt : NileColors.txtSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

class _AssignMyselfTile extends StatelessWidget {
  final UserProfile me;
  final VoidCallback onTap;
  const _AssignMyselfTile({required this.me, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final url = me.avatarUrl;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Container(
        margin: const EdgeInsets.only(bottom: NileSpacing.s8),
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12, vertical: NileSpacing.s8),
        decoration: BoxDecoration(
          color: NileColors.volt.withValues(alpha: 0.08),
          border: Border.all(color: NileColors.volt.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(NileRadius.sm),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: NileColors.bgRaised,
              backgroundImage: (url != null && url.isNotEmpty)
                  ? nileAvatarImage(url, 16)
                  : null,
              child: (url == null || url.isEmpty)
                  ? Icon(
                      Icons.person,
                      size: 16,
                      color: NileColors.txtTertiary,
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Assign myself (@${me.username})',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NileTextStyles.labelMd(),
              ),
            ),
            Icon(Icons.add_circle_outline, color: NileColors.volt),
          ],
        ),
      ),
    );
  }
}

class _PickerTabs extends StatelessWidget {
  final bool showFavorites;
  final int favoriteCount;
  final ValueChanged<bool> onChanged;

  const _PickerTabs({
    required this.showFavorites,
    required this.favoriteCount,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        border: Border.all(color: NileColors.border),
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      child: Row(
        children: [
          Expanded(
            child: _seg('Search', !showFavorites, () => onChanged(false)),
          ),
          Expanded(
            child: _seg(
              favoriteCount > 0 ? 'Favorites ($favoriteCount)' : 'Favorites',
              showFavorites,
              () => onChanged(true),
            ),
          ),
        ],
      ),
    );
  }

  Widget _seg(String label, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: NileSpacing.s12),
        decoration: BoxDecoration(
          color: selected ? NileColors.volt : Colors.transparent,
          borderRadius: BorderRadius.circular(NileRadius.sm),
        ),
        child: Text(
          label,
          style: NileTextStyles.labelMd().copyWith(
            color: selected ? NileColors.onVolt : NileColors.txtSecondary,
          ),
        ),
      ),
    );
  }
}

class _OperatorAssignedRow extends StatelessWidget {
  final OperatorPick pick;
  final bool isMe;
  final VoidCallback onRemove;

  const _OperatorAssignedRow({
    required this.pick,
    this.isMe = false,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: NileSpacing.s8),
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12, vertical: NileSpacing.s8),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        border: Border.all(color: NileColors.border),
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              isMe
                  ? '@${pick.profile.username} (you)'
                  : '@${pick.profile.username}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NileTextStyles.labelMd(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: NileColors.txtTertiary,
            onPressed: onRemove,
            tooltip: 'Remove',
          ),
        ],
      ),
    );
  }
}
