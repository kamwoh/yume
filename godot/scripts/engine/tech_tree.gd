extends Node
class_name TechTreeDirector

## ADR 0033 — Technology-tree primitive.
##
## Holds tech tree definitions (loaded from data/<game>/tech_trees.json OR
## registered directly by tests) and hosts the three new effect verbs:
## try_discover_tech, learn_from_master, pass_to_apprentice. Also exposes
## inherit_to(heir, parent) for ADR 0034 dynasty succession.
##
## Per ADR 0021, this module EXPOSES the existing primitives (state field
## mutation + relation traversal + signal emission) under three declarative
## effects. No semantic effect types named after specific techs — the
## techs themselves are content (`tech_trees.json`). Engine never reads a
## node id by name.
##
## Design contract (ADR 0033 §1-§7):
##   - state.known_techs : Array[String] — node ids the entity has learned.
##                         Append-only during life (heir succession may
##                         reset non-core nodes; rules may explicitly
##                         state_set the array — engine doesn't enforce).
##   - relations.party_member_of : apprentice→master edge (ADR 0026 reuse).
##                                 learn_from_master walks this; pass_to_
##                                 apprentice inverts it.
##   - signals: tech_discovered, tech_learned, tech_inherited.
##
## Wiring: TechTreeDirector expects to be a child of a Node whose script
## is `World`. Sibling of GameShell + ScreenFlow + LightingDirector +
## ScheduleDirector + LifecycleDirector + ClassManager + PartyDirector.
## No per-tick work — discovery cadence is content-driven via tick rules.
##
## Lifecycle:
## 1. Boot: World.start() calls register_trees_from_data_root(root, env).
##    No-op when no tech_trees.json present (existing demos unaffected).
## 2. Effect dispatch: effect_apply.gd's three new arms locate this node
##    via env.parent.get_node_or_null("TechTreeDirector") and call
##    try_discover_tech / learn_from_master / pass_to_apprentice.
## 3. Tests: instantiate directly, call register_trees + the verbs.
##
## Backward-compat: entities WITHOUT state.known_techs auto-init to [] on
## first try_discover_tech call. Existing demos see no behavior change.


# ============================================================
# CONSTANTS
# ============================================================

const SIGNAL_TECH_DISCOVERED: String = "tech_discovered"
const SIGNAL_TECH_LEARNED:    String = "tech_learned"
const SIGNAL_TECH_INHERITED:  String = "tech_inherited"
const STATE_KNOWN_TECHS:      String = "known_techs"
const DEFAULT_PARTY_RELATION: String = "party_member_of"


# ============================================================
# STATE
# ============================================================

var _world: Node = null
# tree_id (String) → {nodes: Array[Dictionary], by_id: Dictionary{node_id: node_dict}}
var _trees: Dictionary = {}


# ============================================================
# LIFECYCLE
# ============================================================

func _ready() -> void:
	_world = get_parent()
	# No World parent → silently no-op (lets test harnesses include the
	# node without crashing). Tests instantiate directly and call
	# register + verb methods without a SceneTree.
	if _world == null or not _world.has_method("_build_env"):
		return


# ============================================================
# REGISTRATION
# ============================================================

## Register a tech-trees blob ({trees: [...]}). Validates DAG structure
## (cycle detection), node-id uniqueness PER TREE. Logs errors via
## EngineError; continues processing other trees on per-tree failures.
##
## Returns Array of structured error records (empty on full success).
## Tests can assert on the return; production callers may also drain
## env.error_buffer afterwards.
func register_trees(trees_data: Dictionary, env: Dictionary = {}) -> Array:
	var errors: Array = []
	if trees_data == null or not (trees_data is Dictionary):
		return errors
	var trees_arr = trees_data.get("trees", null)
	if not (trees_arr is Array):
		return errors
	for entry in (trees_arr as Array):
		if not (entry is Dictionary):
			continue
		var tree: Dictionary = entry
		var tree_id: String = str(tree.get("id", ""))
		if tree_id == "":
			var rec := EngineError.raise(env, EngineError.TECH_NO_TREE,
				"TechTreeDirector: tree definition has no id",
				{"tree": tree},
				"Add an 'id' field naming this tree (e.g. \"id\": \"smithing\").",
				"warning")
			errors.append(rec)
			continue
		var nodes_arr = tree.get("nodes", null)
		if not (nodes_arr is Array):
			continue
		# Build by_id lookup + validate node uniqueness.
		var by_id: Dictionary = {}
		var clean_nodes: Array = []
		for n in (nodes_arr as Array):
			if not (n is Dictionary):
				continue
			var node: Dictionary = n
			var nid: String = str(node.get("id", ""))
			if nid == "":
				continue
			if by_id.has(nid):
				# Duplicate node id within the same tree — last wins, but log.
				push_warning("TechTreeDirector: duplicate node id '%s' in tree '%s' — last wins." % [nid, tree_id])
			by_id[nid] = node
			clean_nodes.append(node)
		# Cycle detection over prereqs (DAG check). Cross-tree prereqs
		# resolve against this tree's own by_id only — cross-tree refs
		# are author intent, not engine-enforced.
		var cycle_path: Array = _detect_cycle(by_id)
		if not cycle_path.is_empty():
			var rec_c := EngineError.raise(env, EngineError.TECH_PREREQ_CYCLE,
				"TechTreeDirector: prereq cycle in tree '%s' — %s" % [tree_id, " → ".join(cycle_path)],
				{"tree": tree_id, "cycle": cycle_path},
				"Remove the prereq edge that closes the cycle, or restructure the tree as a DAG.",
				"error")
			errors.append(rec_c)
			# Skip storing the bad tree.
			continue
		_trees[tree_id] = {
			"id": tree_id,
			"nodes": clean_nodes,
			"by_id": by_id,
		}
	return errors


## Bulk-load from disk: walks <root>/tech_trees.json and registers all
## trees. No-op when the file is absent (most games). Logs structural
## errors via EngineError; continues processing other trees.
func register_trees_from_data_root(root: String, env: Dictionary = {}) -> void:
	if root == "":
		return
	var path: String = root.rstrip("/") + "/tech_trees.json"
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var raw := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(raw) != OK:
		push_warning("TechTreeDirector: invalid JSON at '%s' (%s)" % [path, json.get_error_message()])
		return
	if not (json.data is Dictionary):
		return
	register_trees(json.data, env)


## True iff a tree with this id is registered.
func has_tree(tree_id: String) -> bool:
	return _trees.has(tree_id)


## Returns a node dict for {tree_id, node_id} or {} if absent.
## Renamed from get_node to avoid shadowing Node.get_node(NodePath).
func get_tech_node(tree_id: String, node_id: String) -> Dictionary:
	if not _trees.has(tree_id):
		return {}
	var by_id: Dictionary = (_trees[tree_id] as Dictionary).get("by_id", {})
	var n = by_id.get(node_id, null)
	return n if n is Dictionary else {}


## All registered tree ids (diagnostics).
func known_tree_ids() -> Array:
	return _trees.keys()


# ============================================================
# DISCOVERY
# ============================================================

## Roll discovery_chance for one or more eligible-and-ready nodes on the
## target's tree. Returns the awarded node id (String) on success, or ""
## on no-op (no eligible nodes / all rolls missed / target absent).
##
## ADR 0033 §3.1 semantics:
##   1. Look up target.state.known_techs (init to [] if absent).
##   2. Enumerate nodes whose: (a) prereqs all in known_techs, (b) the
##      node itself NOT in known_techs, (c) target's tags pass
##      eligibility_tags (tags_all filter).
##   3. For up to max_rolls_per_call candidates (declaration order),
##      roll randf() < discovery_chance. ON FIRST HIT: append, emit
##      tech_discovered, return the node id.
func try_discover_tech(env: Dictionary, entity_id: String, tree_id: String,
                       max_rolls_per_call: int = 1) -> String:
	var ent := _resolve_entity(env, entity_id)
	if ent == null:
		return ""
	if not _trees.has(tree_id):
		EngineError.raise(env, EngineError.TECH_NO_TREE,
			"try_discover_tech: unknown tree '%s'" % tree_id,
			{"target": entity_id, "tree": tree_id, "known_trees": _trees.keys()},
			"Register the tree via register_trees or add data/<game>/tech_trees.json.",
			"warning")
		return ""
	var known: Array = _ensure_known_techs(ent)
	var tree: Dictionary = _trees[tree_id]
	var nodes: Array = tree.get("nodes", [])
	var rolls: int = 0
	for n in nodes:
		if rolls >= max_rolls_per_call:
			break
		if not (n is Dictionary):
			continue
		var node: Dictionary = n
		var nid: String = str(node.get("id", ""))
		if nid == "" or known.has(nid):
			continue
		# Prereq gate.
		if not _prereqs_satisfied(node, known):
			continue
		# Eligibility-tag gate.
		if not _eligibility_ok(ent, node):
			continue
		# Roll.
		rolls += 1
		var chance: float = float(node.get("discovery_chance", 0.0))
		if randf() < chance:
			known.append(nid)
			ent.set_state(STATE_KNOWN_TECHS, known)
			_emit_signal(env, SIGNAL_TECH_DISCOVERED, {
				"entity": ent.instance_id,
				"tree": tree_id,
				"node": nid,
				"source": "discovery",
			})
			return nid
	return ""


# ============================================================
# MASTER → APPRENTICE TRANSFER
# ============================================================

## Transfer one node from a related master to the target apprentice.
## Resolves master via the named relation (ADR 0026 default:
## party_member_of). Returns the awarded node id ("" on no-op).
##
## ADR 0033 §3.2 semantics:
##   1. Resolve master via apprentice's outgoing party_member_of edge.
##      Caller may override via master_id.
##   2. Compute master.known_techs minus apprentice.known_techs,
##      filtered by tree (if given).
##   3. Filter to nodes whose prereqs the apprentice already has.
##   4. Award up to max_per_call (lowest-id first for determinism).
func learn_from_master(env: Dictionary, apprentice_id: String, tree_id: String = "",
                       master_id: String = "", relation: String = DEFAULT_PARTY_RELATION,
                       max_per_call: int = 1) -> String:
	var apprentice := _resolve_entity(env, apprentice_id)
	if apprentice == null:
		return ""
	# Resolve master.
	var resolved_master_id: String = master_id
	if resolved_master_id == "":
		var store: RelationStore = env.get("relations", null)
		if store == null:
			# No relation store — treat as missing-master no-op.
			return ""
		var leaders: Array = store.targets(relation, apprentice_id)
		if leaders.is_empty():
			# Master-missing no-op (per ADR 0033 §3.2 — graceful, no error).
			return ""
		resolved_master_id = str(leaders[0])
	var master := _resolve_entity(env, resolved_master_id)
	if master == null:
		return ""
	var apprentice_known: Array = _ensure_known_techs(apprentice)
	var master_known: Array = _ensure_known_techs(master)
	# Candidates: master knows + apprentice doesn't.
	var candidates: Array = []
	for nid in master_known:
		if apprentice_known.has(str(nid)):
			continue
		candidates.append(str(nid))
	# Filter by tree (if specified) AND by prereq satisfiability.
	var filtered: Array = []
	for nid in candidates:
		# Find which tree contains this node (when tree_id supplied,
		# restrict; else allow any).
		if tree_id != "":
			var node: Dictionary = get_tech_node(tree_id, nid)
			if node.is_empty():
				continue
			if not _prereqs_satisfied(node, apprentice_known):
				continue
			filtered.append(nid)
		else:
			# Search all trees for this node id; first match wins.
			var found: bool = false
			for tid in _trees.keys():
				var node2: Dictionary = get_tech_node(str(tid), nid)
				if not node2.is_empty():
					if _prereqs_satisfied(node2, apprentice_known):
						filtered.append(nid)
					found = true
					break
			if not found:
				# Node not in any registered tree (master had a phantom).
				# Skip silently.
				pass
	# Sort lowest-id first for determinism.
	filtered.sort()
	# Award up to max_per_call.
	if filtered.is_empty():
		return ""
	var awarded: String = ""
	var awards: int = 0
	for nid in filtered:
		if awards >= max_per_call:
			break
		apprentice_known.append(nid)
		# Determine tree for the signal payload.
		var sig_tree: String = tree_id if tree_id != "" else _find_tree_for_node(nid)
		_emit_signal(env, SIGNAL_TECH_LEARNED, {
			"entity": apprentice.instance_id,
			"tree": sig_tree,
			"node": nid,
			"source": "master",
			"master_id": master.instance_id,
		})
		awards += 1
		if awarded == "":
			awarded = nid
	apprentice.set_state(STATE_KNOWN_TECHS, apprentice_known)
	return awarded


## Mirror of learn_from_master fired from the master's perspective.
## Resolves apprentices via the inverse of relation (sources of the
## edge type pointing TO the master), iterates them, calls
## learn_from_master per apprentice. Returns total award count.
func pass_to_apprentice(env: Dictionary, master_id: String, tree_id: String = "",
                        relation: String = DEFAULT_PARTY_RELATION,
                        max_apprentices_per_call: int = 4,
                        max_per_apprentice: int = 1) -> int:
	var master := _resolve_entity(env, master_id)
	if master == null:
		return 0
	var store: RelationStore = env.get("relations", null)
	if store == null:
		return 0
	# Apprentices are entities whose outgoing edge of `relation` points
	# AT the master — i.e. sources of (relation, master).
	var apprentices: Array = store.sources(relation, master_id)
	var total: int = 0
	var processed: int = 0
	for ap_id in apprentices:
		if processed >= max_apprentices_per_call:
			break
		processed += 1
		var awarded: String = learn_from_master(env, str(ap_id), tree_id, master_id,
		                                       relation, max_per_apprentice)
		if awarded != "":
			total += 1
	return total


# ============================================================
# DYNASTY INHERITANCE (ADR 0034 hook)
# ============================================================

## Inherit techs from source entity to heir, filtered by `core` flag.
## Returns the list of node ids actually transferred (skips ones the
## heir already has, skips non-core when filter="core_only").
##
## ADR 0033 §7 semantics:
##   - filter="core_only" (default): only nodes with core=true transferred.
##   - filter="all": every known node transferred.
##   - heir's existing known_techs preserved; duplicates skipped.
##   - Emits tech_inherited signal per node transferred.
func inherit_to(env: Dictionary, source_id: String, heir_id: String,
                filter: String = "core_only") -> Array:
	var inherited: Array = []
	var source := _resolve_entity(env, source_id)
	var heir := _resolve_entity(env, heir_id)
	if source == null or heir == null:
		return inherited
	var source_known: Array = _ensure_known_techs(source)
	var heir_known: Array = _ensure_known_techs(heir)
	for nid_v in source_known:
		var nid: String = str(nid_v)
		if heir_known.has(nid):
			continue
		# Locate the node across registered trees.
		var node_dict: Dictionary = {}
		var found_tree: String = ""
		for tid in _trees.keys():
			var n: Dictionary = get_tech_node(str(tid), nid)
			if not n.is_empty():
				node_dict = n
				found_tree = str(tid)
				break
		if node_dict.is_empty():
			# Phantom node — source knew something not in current trees.
			# Skip (matches ADR 0010 §9 fail-soft policy).
			continue
		if filter == "core_only" and not bool(node_dict.get("core", false)):
			continue
		heir_known.append(nid)
		inherited.append(nid)
		_emit_signal(env, SIGNAL_TECH_INHERITED, {
			"entity": heir.instance_id,
			"tree": found_tree,
			"node": nid,
			"source": "heir",
			"parent_id": source.instance_id,
		})
	heir.set_state(STATE_KNOWN_TECHS, heir_known)
	return inherited


# ============================================================
# INTERNAL HELPERS
# ============================================================

static func _resolve_entity(env: Dictionary, entity_id: String) -> Entity:
	if entity_id == "":
		return null
	var entities = env.get("entities", null)
	if not (entities is Dictionary):
		return null
	if not (entities as Dictionary).has(entity_id):
		return null
	var ent = (entities as Dictionary)[entity_id]
	return ent if ent is Entity else null


## Initialize state.known_techs as Array[String] if absent. Returns the
## live array reference (mutations affect entity state). After mutation,
## call set_state(STATE_KNOWN_TECHS, arr) to persist (Entity stores by
## reference, but this keeps the contract explicit and survives any
## future copy-on-write change).
static func _ensure_known_techs(ent: Entity) -> Array:
	var v = ent.get_state(STATE_KNOWN_TECHS, null)
	if v is Array:
		return v
	var arr: Array = []
	ent.set_state(STATE_KNOWN_TECHS, arr)
	return arr


static func _prereqs_satisfied(node: Dictionary, known: Array) -> bool:
	var prereqs = node.get("prereqs", [])
	if not (prereqs is Array):
		return true
	for p in (prereqs as Array):
		if not known.has(str(p)):
			return false
	return true


static func _eligibility_ok(ent: Entity, node: Dictionary) -> bool:
	var tags = node.get("eligibility_tags", null)
	if not (tags is Array) or (tags as Array).is_empty():
		return true
	for t in (tags as Array):
		if not ent.has_tag(str(t)):
			return false
	return true


func _find_tree_for_node(node_id: String) -> String:
	for tid in _trees.keys():
		var by_id: Dictionary = (_trees[tid] as Dictionary).get("by_id", {})
		if by_id.has(node_id):
			return str(tid)
	return ""


static func _emit_signal(env: Dictionary, name: String, payload: Dictionary) -> void:
	var buf = env.get("signal_buffer", null)
	if buf is Array:
		(buf as Array).append({"name": name, "payload": payload})
	# else: no signal_buffer (test harness without scheduler) — state
	# mutations still applied; signal silently dropped. Tests that check
	# the signal must provide their own buffer.


## DFS cycle detection over prereq graph. Returns the cycle path (the
## first cycle found) or [] when graph is a DAG. Visits every node;
## each node uses three colors: white (unvisited), gray (on stack),
## black (done).
static func _detect_cycle(by_id: Dictionary) -> Array:
	# Three-color DFS: 0=WHITE (unvisited), 1=GRAY (on stack), 2=BLACK (done).
	var color: Dictionary = {}
	for nid in by_id.keys():
		color[nid] = 0
	for nid in by_id.keys():
		if color[nid] == 0:
			var stack: Array = []
			var found := _dfs_cycle(str(nid), by_id, color, stack)
			if not found.is_empty():
				return found
	return []


static func _dfs_cycle(nid: String, by_id: Dictionary, color: Dictionary, stack: Array) -> Array:
	color[nid] = 1  # GRAY
	stack.append(nid)
	var node: Dictionary = by_id.get(nid, {})
	var prereqs = node.get("prereqs", [])
	if prereqs is Array:
		for p_v in (prereqs as Array):
			var p: String = str(p_v)
			if not by_id.has(p):
				# Cross-tree prereq or phantom — engine doesn't follow
				# (per ADR §1: cross-tree prereqs allowed but lookup is
				# per-tree at registration). No cycle possible through
				# an absent edge.
				continue
			if not color.has(p) or color[p] == 0:  # WHITE
				var sub := _dfs_cycle(p, by_id, color, stack)
				if not sub.is_empty():
					return sub
			elif color[p] == 1:  # GRAY — back edge = cycle
				var cycle: Array = []
				var i: int = stack.find(p)
				if i >= 0:
					for j in range(i, stack.size()):
						cycle.append(stack[j])
					cycle.append(p)
				return cycle
	stack.pop_back()
	color[nid] = 2  # BLACK
	return []
