import '../ui/page_app_bar.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_router.dart';
import '../app_routes.dart';
import '../../engine/core/player_profiles.dart';
import '../../engine/ludo/ludo_board.dart';
import '../../engine/ludo/ludo_models.dart';
import '../../providers/app_providers.dart';
import '../../services/online_client.dart' show DefaultNames;
import '../../controllers/ludo_session.dart';

import '../../services/sound_service.dart';
import '../../ui/club_widgets.dart';
import '../../ui/ludo/ludo_view.dart';
import '../../ui/snakes/snakes_view.dart';
import '../../ui/theme.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key, required this.game});

  final GameKind game;

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SeatDraft {
  _SeatDraft({this.profileId, required this.name, this.isAI = false});
  String? profileId;
  String name;
  bool isAI;
  AIDifficulty difficulty = AIDifficulty.medium;
  LudoColor? color; // Ludo corner (null = auto)
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  late List<_SeatDraft> _seats;

  int get _minPlayers => 2;
  int get _maxPlayers => widget.game == GameKind.ludo ? 4 : 10;
  bool get _isLudo => widget.game == GameKind.ludo;

  /// Default corner colors for a table of [n] players. Two players sit
  /// diagonally (red bottom-left vs yellow top-right); otherwise seats fill
  /// the classic clockwise circuit.
  static List<LudoColor> _defaultColors(int n) => n == 2
      ? const [LudoColor.red, LudoColor.yellow]
      : LudoBoard.colorOrder.take(n).toList();

  /// Keep each seat's explicit pick (if still unique), then fill the rest
  /// from the defaults for the current seat count.
  void _normalizeColors() {
    if (!_isLudo) return;
    final taken = <LudoColor>{};
    for (final s in _seats) {
      if (s.color != null && taken.add(s.color!)) continue;
      s.color = null;
    }
    final pool = <LudoColor>[
      ..._defaultColors(_seats.length),
      ...LudoBoard.colorOrder,
    ];
    for (final s in _seats) {
      if (s.color != null) continue;
      final c = pool.firstWhere((c) => !taken.contains(c));
      s.color = c;
      taken.add(c);
    }
  }

  @override
  void initState() {
    super.initState();
    final profiles = ref.read(profilesProvider);
    final taken = <String>{};
    _seats = [
      _SeatDraft(
        profileId: profiles.isNotEmpty ? profiles.first.id : null,
        // A saved profile keeps its own name; only a seat with nothing behind
        // it gets a generated one.
        name: profiles.isNotEmpty ? profiles.first.name : _freshSeatName(taken),
      ),
      _SeatDraft(name: _freshSeatName(taken), isAI: true),
    ];
    _normalizeColors();
    // SAVE & RESUME — parked (see the note on _saved / the start section
    // below); the store is untouched and the feature returns when this and
    // the button block are unwrapped with their matching "SAVE & RESUME"
    // markers.
    /*
    // Resume is offered only if there is a game to resume, so a player who
    // never left one in progress never sees the button.
    SavedGameStore().load(widget.game).then((g) {
      if (mounted && g != null) setState(() => _saved = g);
    });
    */
  }

  /// A generated name for a new seat, distinct from the seats already at the
  /// table.
  ///
  /// Uniqueness is the point: two seats both called "Swift Otter" on one board
  /// is the same confusion the online leaderboard had, and here it is worse
  /// because the name is on the pawn you are trying to follow. 256 word pairs
  /// is plenty for a ten-seat table, so the retry loop is a safety net rather
  /// than something that runs in practice.
  String _freshSeatName(Set<String> taken) {
    for (var attempt = 0; attempt < 40; attempt++) {
      final name = DefaultNames.generate();
      if (taken.add(name)) return name;
    }
    return 'Player ${taken.length + 1}';
  }

  void _setCount(int count) {
    setState(() {
      while (_seats.length < count) {
        _seats.add(
          _SeatDraft(
            name: _freshSeatName({for (final s in _seats) s.name}),
            isAI: true,
          ),
        );
      }
      while (_seats.length > count) {
        _seats.removeLast();
      }
      _normalizeColors();
    });
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(profilesProvider);
    final label = widget.game == GameKind.ludo ? 'Ludo' : 'Snakes & Ladders';

    return Scaffold(
      appBar: PageAppBar(title: '$label — New game'),
      body: ClubBackground(
        child: SafeArea(
          // A reading-width column, centred. Unconstrained, every card and
          // button stretched to the full viewport: on a wide desktop a seat row
          // put a short name at the far left and its corner swatches at the far
          // right, with a metre of empty felt between them. The swatch row is
          // what makes it read badly - it is the thing you compare across
          // seats, and it has to sit near the name to be comparable at all.
          child: ContentColumn(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
              children: [
                _tablePreamble(label),
                const SizedBox(height: 14),
                // The first Card on the page is deliberately the table-size
                // sheet: the title bar and every sheet share one left edge.
                ClubCard(
                  padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Players at the table',
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${_seats.length} of $_maxPlayers',
                            style: const TextStyle(
                              fontFamily: AppFonts.body,
                              color: AppColors.textMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 9),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var n = _minPlayers; n <= _maxPlayers; n++)
                            ChoiceChip(
                              label: Text('$n'),
                              selected: _seats.length == n,
                              onSelected: (_) => _setCount(n),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                for (var i = 0; i < _seats.length; i++) _seatCard(i, profiles),
                const SizedBox(height: 12),
                // Offered only when there is something to resume, so a player
                // who never left a game in progress never sees it.
                // SAVE & RESUME — parked; see the note on _saved below.
                /*
                if (_saved != null) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.restore),
                    label: Text(
                      'Resume $_savedSeats saved · ${_age(_saved!.savedAt)}',
                    ),
                    onPressed: _resume,
                  ),
                  const SizedBox(height: 8),
                ],
                */
                SizedBox(
                  height: 54,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.casino, size: 20),
                    label: const Text('Start game'),
                    onPressed: _start,
                  ),
                ),
                const SizedBox(height: 12),
                const Center(
                  child: Text(
                    'Hot-seat local play · bots join instantly · '
                    'swap seats any time mid-game',
                    style: TextStyle(
                      fontFamily: AppFonts.body,
                      color: AppColors.paperDeep,
                      fontSize: 11.5,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The quiet line above the sheets: which game this table is for, and what
  /// the room expects from the player.
  Widget _tablePreamble(String label) {
    return Row(
      children: [
        ClubSeal(
          icon: _isLudo ? Icons.casino_outlined : Icons.grid_on_outlined,
          size: 38,
          onPaper: false,
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'SET THE TABLE',
                style: TextStyle(
                  fontFamily: AppFonts.body,
                  color: AppColors.gold,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.8,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '$label · ${_seats.length} seats',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppColors.paper,
                  fontFamily: AppFonts.display,
                  fontWeight: FontWeight.w600,
                  fontSize: 19,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- seats

  Widget _seatCard(int i, List<PlayerProfile> profiles) {
    final seat = _seats[i];
    final seatColor = _isLudo && seat.color != null
        ? AppColors.ludo(seat.color!)
        : i == 0
        ? AppColors.brass
        : AppColors.snakesColors[i % 10];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ClubCard(
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
        radius: 16,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: seatColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.gold.withValues(alpha: 0.85),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: seatColor.withValues(alpha: 0.28),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Text(
                    '${i + 1}',
                    style: const TextStyle(
                      fontFamily: AppFonts.body,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Seat ${i + 1}',
                        style: const TextStyle(
                          fontFamily: AppFonts.body,
                          color: AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        seat.isAI ? 'House bot' : 'Human player',
                        style: const TextStyle(
                          fontFamily: AppFonts.body,
                          color: AppColors.textMuted,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Human')),
                    ButtonSegment(value: true, label: Text('Bot')),
                  ],
                  selected: {seat.isAI},
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onSelectionChanged: (v) =>
                      setState(() => seat.isAI = v.first),
                ),
              ],
            ),
            if (_isLudo) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text(
                    'CORNER',
                    style: TextStyle(
                      fontFamily: AppFonts.body,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(width: 9),
                  for (final c in LudoBoard.colorOrder) ...[
                    const SizedBox(width: 3),
                    _cornerDot(c, seat),
                  ],
                  const Spacer(),
                  if (_seats.length == 2)
                    const Text(
                      'Diagonal seating',
                      style: TextStyle(
                        fontFamily: AppFonts.body,
                        fontSize: 10.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 9),
            if (seat.isAI)
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: seat.name,
                      decoration: const InputDecoration(
                        labelText: 'Bot name',
                        isDense: true,
                      ),
                      onChanged: (v) => seat.name = v,
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<AIDifficulty>(
                      value: seat.difficulty,
                      borderRadius: BorderRadius.circular(14),
                      style: const TextStyle(
                        fontFamily: AppFonts.body,
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                      icon: const Icon(
                        Icons.keyboard_arrow_down,
                        size: 18,
                        color: AppColors.textSecondary,
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: AIDifficulty.easy,
                          child: Text('Easy'),
                        ),
                        DropdownMenuItem(
                          value: AIDifficulty.medium,
                          child: Text('Medium'),
                        ),
                        DropdownMenuItem(
                          value: AIDifficulty.hard,
                          child: Text('Hard'),
                        ),
                      ],
                      onChanged: (v) => setState(
                        () => seat.difficulty = v ?? seat.difficulty,
                      ),
                    ),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      initialValue: seat.profileId,
                      decoration: const InputDecoration(
                        labelText: 'Choose profile',
                        isDense: true,
                      ),
                      items: [
                        ...profiles.map(
                          (p) => DropdownMenuItem(
                            value: p.id,
                            child: Text(p.name),
                          ),
                        ),
                      ],
                      onChanged: (v) => setState(() {
                        seat.profileId = v;
                        if (v != null) {
                          seat.name = profiles
                              .firstWhere((p) => p.id == v)
                              .name;
                        }
                      }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => _createProfile(i),
                    child: const Text('New'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _cornerDot(LudoColor c, _SeatDraft seat) {
    final takenByOther = _seats.any((s) => s != seat && s.color == c);
    final selected = seat.color == c;
    return Tooltip(
      message: takenByOther ? 'Taken' : c.name,
      child: InkWell(
        onTap: takenByOther ? null : () => setState(() => seat.color = c),
        customBorder: const CircleBorder(),
        child: Container(
          width: 28,
          height: 28,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? AppColors.darkInk : Colors.transparent,
              width: 1.6,
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.ludo(c),
            ),
            child: takenByOther
                ? const Icon(Icons.lock, size: 11, color: Colors.white70)
                : (selected
                      ? const Icon(Icons.check, size: 13, color: Colors.white)
                      : null),
          ),
        ),
      ),
    );
  }

  Future<void> _createProfile(int seatIndex) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New profile'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final profile = ref.read(profilesProvider.notifier).create(name);
    setState(() {
      _seats[seatIndex].profileId = profile.id;
      _seats[seatIndex].name = profile.name;
    });
  }

  // ---------------------------------------------------------------- start

  // ---------------------------------------------------------------- start

  // SAVE & RESUME — PARKED. The feature is intact (SavedGameStore and
  // LudoSession.resume / SnakesSession.resume still pass their tests) but its
  // player-facing surfaces are held out of the build until the gameplay
  // smoothness pass ships; uncomment the blocks marked SAVE & RESUME below to
  // bring the "Resume saved game" button back.
  /*
  /// Reads the save on open. Started in initState and awaited into state
  /// rather than blocking the first frame — the setup screen is usable either
  /// way, and a slow disk should not delay it.
  SavedGame? _saved;

  int get _savedSeats => _saved?.seatNames.length ?? 0;

  /// How long ago the save was written, in words a player would use.
  static String _age(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  void _resume() {
    final saved = _saved;
    if (saved == null) return;
    Haptics.light();
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => widget.game == GameKind.ludo
          ? LudoGameView(savedGame: saved)
          : SnakesGameView(seats: const [], savedGame: saved),
    ));
  }
  */

  void _start() {
    for (final s in _seats) {
      if (s.name.trim().isEmpty) {
        showSnackInColumn(
          context,
          'Every seat needs a name',
          icon: Icons.edit_note,
        );
        return;
      }
    }
    final seats = [
      for (final s in _seats)
        SeatSetup(
          profileId: s.isAI ? null : s.profileId,
          name: s.name.trim(),
          isAI: s.isAI,
          difficulty: s.difficulty,
          color: _isLudo ? s.color : null,
        ),
    ];
    Haptics.light();
    replaceAppScreen<void>(
      context,
      name: widget.game == GameKind.ludo
          ? AppRoutes.gameLudo
          : AppRoutes.gameSnakes,
      builder: (_) => widget.game == GameKind.ludo
          ? LudoGameView(seats: seats)
          : SnakesGameView(seats: seats),
    );
  }
}
