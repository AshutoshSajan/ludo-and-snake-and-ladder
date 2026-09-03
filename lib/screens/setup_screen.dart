import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engine/core/player_profiles.dart';
import '../../engine/ludo/ludo_board.dart';
import '../../engine/ludo/ludo_models.dart';
import '../../providers/app_providers.dart';
import '../../controllers/ludo_session.dart';
import '../../services/sound_service.dart';
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
    _seats = [
      _SeatDraft(
        profileId: profiles.isNotEmpty ? profiles.first.id : null,
        name: profiles.isNotEmpty ? profiles.first.name : 'Player 1',
      ),
      _SeatDraft(name: 'Bot 2', isAI: true),
    ];
    _normalizeColors();
  }

  void _setCount(int count) {
    setState(() {
      while (_seats.length < count) {
        _seats.add(_SeatDraft(name: 'Bot ${_seats.length + 1}', isAI: true));
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
      appBar: AppBar(title: Text('$label — New game')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Players at the table',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
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
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _seats.length; i++) _seatCard(i, profiles),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.casino),
              label: const Text('Start game'),
              onPressed: _start,
            ),
            const SizedBox(height: 8),
            const Center(
              child: Text(
                'Hot-seat local play · bots join instantly · '
                'swap seats any time mid-game',
                style: TextStyle(color: Colors.white54, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- seats

  Widget _seatCard(int i, List<PlayerProfile> profiles) {
    final seat = _seats[i];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: _isLudo && seat.color != null
                      ? AppColors.ludo(seat.color!)
                      : i == 0
                          ? AppColors.gold
                          : AppColors.snakesColors[i % 10],
                  child: Text('${i + 1}',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 8),
                Text('Seat ${i + 1}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Human')),
                    ButtonSegment(value: true, label: Text('Bot')),
                  ],
                  selected: {seat.isAI},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) =>
                      setState(() => seat.isAI = v.first),
                ),
              ],
            ),
            if (_isLudo) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Text('Corner',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white54)),
                  const SizedBox(width: 10),
                  for (final c in LudoBoard.colorOrder) ...[
                    const SizedBox(width: 4),
                    _cornerDot(c, seat),
                  ],
                  const Spacer(),
                  if (_seats.length == 2)
                    const Text(
                      'Diagonal seating',
                      style: TextStyle(fontSize: 11, color: Colors.white38),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            if (seat.isAI)
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: seat.name,
                      decoration: const InputDecoration(
                          labelText: 'Bot name', isDense: true),
                      onChanged: (v) => seat.name = v,
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<AIDifficulty>(
                    value: seat.difficulty,
                    items: const [
                      DropdownMenuItem(
                          value: AIDifficulty.easy, child: Text('Easy')),
                      DropdownMenuItem(
                          value: AIDifficulty.medium, child: Text('Medium')),
                      DropdownMenuItem(
                          value: AIDifficulty.hard, child: Text('Hard')),
                    ],
                    onChanged: (v) =>
                        setState(() => seat.difficulty = v ?? seat.difficulty),
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
                          labelText: 'Choose profile', isDense: true),
                      items: [
                        ...profiles.map((p) => DropdownMenuItem(
                            value: p.id, child: Text(p.name))),
                      ],
                      onChanged: (v) => setState(() {
                        seat.profileId = v;
                        if (v != null) {
                          seat.name =
                              profiles.firstWhere((p) => p.id == v).name;
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
          width: 30,
          height: 30,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? AppColors.ivory : Colors.transparent,
              width: 2,
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.ludo(c),
            ),
            child: takenByOther
                ? const Icon(Icons.lock, size: 12, color: Colors.black45)
                : (selected
                    ? const Icon(Icons.check,
                        size: 14, color: Colors.white, weight: 3)
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
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
              child: const Text('Create')),
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

  void _start() {
    for (final s in _seats) {
      if (s.name.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Every seat needs a name')),
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
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => widget.game == GameKind.ludo
          ? LudoGameView(seats: seats)
          : SnakesGameView(seats: seats),
    ));
  }
}
