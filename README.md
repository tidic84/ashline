# Ashline

Cooperative first-person train defense and building game built with Godot 4.6.

Defend your train against waves of enemies while building fortifications on your wagons. Inspired by Dead Rails and Railborn.

## Gameplay

- **Build** fortifications on your train wagons (walls, barricades, turrets, workbenches)
- **Defend** against waves of increasingly difficult enemies
- **Cooperate** with up to 4 players in online coop
- **Customize** your train by adding different wagon types

## Controls

| Key | Action |
|-----|--------|
| WASD | Move |
| Mouse | Look |
| Space | Jump |
| E | Interact |
| B | Toggle build mode |
| Left Click | Shoot / Place (build mode) |
| Right Click | Aim / Cycle buildable (build mode) |
| R | Reload / Rotate (build mode) |
| Tab | Inventory |
| Escape | Pause |

## Wagon Types

| Type | HP | Grid | Weight | Description |
|------|----|------|--------|-------------|
| Flatbed | 100 | 4x8 | 20 | Open platform, maximum build space |
| Armored | 200 | 3x7 | 30 | Enclosed box car, high durability |
| Storage | 80 | 3x6 | 15 | Resource storage |
| Workshop | 80 | 4x8 | 25 | Crafting and upgrades |

## Buildables

| Item | Category | HP | Weight |
|------|----------|----|--------|
| Metal Panel | Wall | 80 | 2 |
| Reinforced Wall | Wall | 150 | 3 |
| Fortified Fence | Barricade | 40 | 1 |
| Window Barricade | Barricade | 60 | 2 |
| Auto Turret | Turret | 60 | 4 |
| Barrel | Utility | 30 | 1 |
| Supply Crate | Utility | 25 | 1 |
| Workbench | Utility | 100 | 3 |

## Enemies

| Type | HP | Speed | Damage | Unlocked |
|------|----|-------|--------|----------|
| Basic | 50 | 4 | 10 | Wave 1 |
| Fast | 30 | 7 | 8 | Wave 3 |
| Tank | 150 | 2 | 25 | Wave 5 |
| Ranged | 40 | 3 | 12 | Wave 8 |

## Multiplayer

1. Launch the game — the lobby screen appears
2. **Host**: enter your name, click "Host Game"
3. **Join**: enter host's IP address, click "Join Game"
4. Host clicks "Start Game" when everyone is connected
5. Up to 4 players via ENet (port 27015 by default)

## Project Structure

```
ashline/
├── assets/models/       # Kenney 3D models (train, weapons, survival, etc.)
├── assets/audio/        # Sound effects and music
├── assets/textures/     # Shared textures
├── resources/buildables/# BuildableData .tres files
├── scenes/
│   ├── building/        # Placeable item scenes
│   ├── enemies/         # Enemy type scenes
│   ├── environment/     # Rail path generation
│   ├── main/            # Main game scene
│   ├── player/          # FPS player controller
│   ├── train/           # Locomotive and wagon scenes
│   └── ui/              # Lobby, HUD
├── scripts/
│   ├── autoload/        # GameManager, TrainManager, BuildSystem, WaveManager, NetworkManager
│   ├── building/        # BuildableData, Placeable, Turret
│   ├── enemies/         # EnemyBase + variants (fast, tank, ranged)
│   ├── player/          # FPS controller with multiplayer support
│   ├── train/           # Wagon grid system, Locomotive
│   ├── ui/              # HUD, Lobby
│   └── weapons/         # Weapon base system
└── project.godot
```

## Requirements

- Godot 4.6+
- Jolt Physics plugin

## Assets

3D models, audio, and textures from [Kenney](https://kenney.nl) (CC0 license):
- Train Kit, Weapon Pack, Survival Kit, Building Kit
- Nature Kit, Blocky Characters
- Impact Sounds, UI Audio, Music Loops

## License

Game code: MIT
Assets: CC0 (Kenney)
