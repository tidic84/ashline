extends Node

## Tracks all RailPath nodes and their endpoint connections.
## Each RailPath can connect its start (end=0) or end (end=1) to another
## RailPath's start or end. A RailSwitch controls which connection is active.

# Connection entry: { "path": RailPath, "end": int (0=start, 1=end) }
# Key: instance_id of RailPath + "_" + end index
# Value: Array of connection entries
var _connections: Dictionary = {}

# Active route per junction key (same key format). Index into _connections[key].
var _active_routes: Dictionary = {}

# All registered paths
var _paths: Array[Node] = []


func register_path(path: Node) -> void:
	if path not in _paths:
		_paths.append(path)


func unregister_path(path: Node) -> void:
	_paths.erase(path)
	# Clean up connections referencing this path
	var to_remove: Array[String] = []
	for key in _connections:
		var conns: Array = _connections[key]
		conns = conns.filter(func(c): return c.path != path)
		if conns.size() == 0:
			to_remove.append(key)
		else:
			_connections[key] = conns
	for key in to_remove:
		_connections.erase(key)
		_active_routes.erase(key)


func _make_key(path: Node, end: int) -> String:
	return "%d_%d" % [path.get_instance_id(), end]


func add_connection(from_path: Node, from_end: int, to_path: Node, to_end: int) -> void:
	var key := _make_key(from_path, from_end)
	if not _connections.has(key):
		_connections[key] = []
	# Avoid duplicates
	for entry in _connections[key]:
		if entry.path == to_path and entry.end == to_end:
			return
	_connections[key].append({ "path": to_path, "end": to_end })
	if not _active_routes.has(key):
		_active_routes[key] = 0

	# Bidirectional: also register the reverse
	var rev_key := _make_key(to_path, to_end)
	if not _connections.has(rev_key):
		_connections[rev_key] = []
	var has_reverse := false
	for entry in _connections[rev_key]:
		if entry.path == from_path and entry.end == from_end:
			has_reverse = true
			break
	if not has_reverse:
		_connections[rev_key].append({ "path": from_path, "end": from_end })
		if not _active_routes.has(rev_key):
			_active_routes[rev_key] = 0


func get_connections_at(path: Node, end: int) -> Array:
	var key := _make_key(path, end)
	if _connections.has(key):
		return _connections[key]
	return []


func get_active_route(path: Node, end: int) -> Dictionary:
	var key := _make_key(path, end)
	if not _connections.has(key) or _connections[key].size() == 0:
		return {}
	var idx: int = _active_routes.get(key, 0)
	idx = clampi(idx, 0, _connections[key].size() - 1)
	return _connections[key][idx]


func cycle_switch(path: Node, end: int) -> int:
	var key := _make_key(path, end)
	if not _connections.has(key) or _connections[key].size() <= 1:
		return 0
	var idx: int = _active_routes.get(key, 0)
	idx = (idx + 1) % _connections[key].size()
	_active_routes[key] = idx
	return idx


func get_active_index(path: Node, end: int) -> int:
	var key := _make_key(path, end)
	return _active_routes.get(key, 0)
