extends Node

signal game_state_changed(new_state: GameState)
signal score_updated(score: int)

enum GameState { MENU, LOBBY, PLAYING, PAUSED, GAME_OVER }

var current_state: GameState = GameState.MENU
var score: int = 0
var current_round: int = 0
var players: Dictionary = {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

func change_state(new_state: GameState) -> void:
	current_state = new_state
	game_state_changed.emit(new_state)
	match new_state:
		GameState.PLAYING:
			get_tree().paused = false
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		GameState.PAUSED:
			get_tree().paused = true
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		GameState.GAME_OVER:
			get_tree().paused = true
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		GameState.MENU:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func add_score(amount: int) -> void:
	score += amount
	score_updated.emit(score)

func start_game() -> void:
	score = 0
	current_round = 0
	change_state(GameState.PLAYING)

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if current_state == GameState.PLAYING:
			change_state(GameState.PAUSED)
		elif current_state == GameState.PAUSED:
			change_state(GameState.PLAYING)
