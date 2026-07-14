# SU <-> Blender save-based sync — Blender side.
#
# Bridge folder ".su_blender_sync" lives next to the .blend (and the .skp).
# Objects to sync go into the "SketchUp Sync" collection (auto-created).
# On every save the collection is exported to from_blender.glb + manifest;
# a background timer watches manifest_sketchup.json and selectively imports
# only the objects whose revision increased. See core.rb for the protocol.

bl_info = {
    "name": "SketchUp Sync (save-based bridge)",
    "author": "Stepan",
    "version": (0, 2, 0),
    "blender": (4, 0, 0),
    "location": "Properties > Scene > SketchUp Sync",
    "description": "Sync geometry+materials with SketchUp via a GLB bridge on save",
    "category": "Import-Export",
}

import bpy
import os
import json
import time
import re
import hashlib
import array
from bpy.app.handlers import persistent

BRIDGE_DIR_NAME = ".su_blender_sync"
OUT_GLB = "from_blender.glb"
OUT_MANIFEST = "manifest_blender.json"
IN_GLB = "from_sketchup.glb"
IN_MANIFEST = "manifest_sketchup.json"
STATE_FILE = "state_blender.json"
COLLECTION = "SketchUp Sync"
POLL_SECONDS = 2.0

_busy = False
_last_in_mtime = None


# --------------------------------------------------------------- helpers ---

def bridge_dir():
    p = bpy.data.filepath
    if not p:
        return None
    return os.path.join(os.path.dirname(p), BRIDGE_DIR_NAME)


def read_state(d):
    path = os.path.join(d, STATE_FILE)
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {"seq": 0, "objects": {}}


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, path)


def get_collection(create=False):
    col = bpy.data.collections.get(COLLECTION)
    if col is None and create:
        col = bpy.data.collections.new(COLLECTION)
        bpy.context.scene.collection.children.link(col)
    return col


def enabled():
    return bpy.context.scene.get("su_sync_enabled", True)


def sync_units(col):
    """[(object, collection_name_or_None), ...] — objects directly in the
    sync collection, plus objects of its direct child collections. A child
    collection becomes a group + tag with its name on the SketchUp side."""
    units = []
    for o in col.objects:
        if o.parent is None:
            units.append((o, None))
    for sub in col.children:
        for o in sub.all_objects:
            if o.parent is None:
                units.append((o, sub.name))
    return units


def ensure_subcollection(col, name):
    sub = bpy.data.collections.get(name)
    if sub is None:
        sub = bpy.data.collections.new(name)
    if all(c.name != name for c in col.children):
        try:
            col.children.link(sub)
        except Exception:
            pass
    return sub


def strip_suffix(name):
    return re.sub(r"[#.]\d+$", "", name)


def log(msg):
    print("[SU⇄Blender]", msg)


def obj_hash(o, h=None):
    """Local change detection only — never compared across apps."""
    top = h is None
    if top:
        h = hashlib.md5()
    for row in o.matrix_world:
        h.update(("%.4f,%.4f,%.4f,%.4f;" % tuple(row)).encode())
    if o.type == "MESH" and o.data:
        me = o.data
        n = len(me.vertices)
        h.update(("v%d,p%d;" % (n, len(me.polygons))).encode())
        if n:
            buf = array.array("f", [0.0]) * (n * 3)
            me.vertices.foreach_get("co", buf)
            rounded = array.array("f", (round(x, 4) for x in buf))
            h.update(rounded.tobytes())
    for slot in o.material_slots:
        h.update((slot.material.name if slot.material else "-").encode())
    for c in o.children:
        obj_hash(c, h)
    return h.hexdigest() if top else None


def hierarchy(o):
    yield o
    for c in o.children:
        yield from hierarchy(c)


def delete_hierarchy(o):
    for c in list(o.children):
        delete_hierarchy(c)
    data = o.data
    bpy.data.objects.remove(o, do_unlink=True)
    try:
        if data and data.users == 0:
            if isinstance(data, bpy.types.Mesh):
                bpy.data.meshes.remove(data)
    except Exception:
        pass


def find_layer_collection(lc, name):
    if lc.collection.name == name:
        return lc
    for c in lc.children:
        r = find_layer_collection(c, name)
        if r:
            return r
    return None


def ensure_object_mode():
    prev = bpy.context.mode
    if prev != "OBJECT":
        try:
            bpy.ops.object.mode_set(mode="OBJECT")
        except Exception:
            pass
    return prev


# ------------------------------------------------------------------ push ---

def do_push():
    global _busy
    d = bridge_dir()
    if d is None:
        log("push skipped: .blend not saved yet")
        return
    _busy = True
    try:
        os.makedirs(d, exist_ok=True)
        col = get_collection(create=True)
        state = read_state(d)
        rev_new = int(state.get("seq", 0)) + 1
        changed = False
        seen = set()

        for o, cname in sync_units(col):
            seen.add(o.name)
            hh = obj_hash(o)
            st = state["objects"].get(o.name)
            if (st and st.get("local_hash") == hh
                    and st.get("collection") == cname
                    and not st.get("deleted")):
                continue  # unchanged since last apply/export — keep rev
            state["objects"][o.name] = {
                "rev": rev_new, "origin": "blender",
                "local_hash": hh, "collection": cname}
            changed = True

        for name, st in list(state["objects"].items()):
            if name not in seen and not st.get("deleted"):
                state["objects"][name] = {
                    "rev": rev_new, "origin": "blender", "deleted": True}
                changed = True

        if changed:
            state["seq"] = rev_new

        export_glb(os.path.join(d, OUT_GLB), col)
        manifest = {
            "seq": state["seq"], "saved_at": int(time.time()),
            "objects": {n: {"rev": st["rev"],
                            "deleted": bool(st.get("deleted")),
                            "collection": st.get("collection")}
                        for n, st in state["objects"].items()},
        }
        # manifest AFTER glb so SketchUp never reads a half-written file
        write_json(os.path.join(d, OUT_MANIFEST), manifest)
        write_json(os.path.join(d, STATE_FILE), state)
        log("pushed to bridge (seq %s)" % state["seq"])
    except Exception as e:
        log("push failed: %r" % e)
    finally:
        _busy = False


def export_glb(path, col):
    prev_mode = ensure_object_mode()
    prev_sel = list(bpy.context.selected_objects)
    prev_active = bpy.context.view_layer.objects.active
    try:
        bpy.ops.object.select_all(action="DESELECT")
        for o in col.all_objects:
            o.select_set(True)
        bpy.ops.export_scene.gltf(
            filepath=path,
            export_format="GLB",
            use_selection=True,
            export_apply=True,
            export_animations=False,
        )
    finally:
        try:
            bpy.ops.object.select_all(action="DESELECT")
            for o in prev_sel:
                o.select_set(True)
            bpy.context.view_layer.objects.active = prev_active
            if prev_mode == "EDIT_MESH":
                bpy.ops.object.mode_set(mode="EDIT")
        except Exception:
            pass


# ------------------------------------------------------------------ pull ---

def do_pull(force=False):
    global _busy, _last_in_mtime
    if _busy:
        return
    d = bridge_dir()
    if d is None:
        return
    mpath = os.path.join(d, IN_MANIFEST)
    if not os.path.exists(mpath):
        return
    mt = os.path.getmtime(mpath)
    if not force and mt == _last_in_mtime:
        return
    _last_in_mtime = mt

    with open(mpath, "r", encoding="utf-8") as f:
        manifest = json.load(f)
    state = read_state(d)

    to_apply, to_del = [], []
    for name, o in (manifest.get("objects") or {}).items():
        cur = state["objects"].get(name, {}).get("rev", -1)
        if o["rev"] > cur:
            if o.get("deleted"):
                to_del.append((name, o["rev"]))
            else:
                to_apply.append((name, o["rev"], o.get("collection")))
    if not to_apply and not to_del:
        return

    _busy = True
    try:
        col = get_collection(create=True)

        for name, rev in to_del:
            o = bpy.data.objects.get(name)
            if o and o.name in col.all_objects:
                delete_hierarchy(o)
            state["objects"][name] = {
                "rev": rev, "origin": "sketchup", "deleted": True}

        if to_apply:
            apply_imports(d, col, to_apply, state)

        write_json(os.path.join(d, STATE_FILE), state)
        log("applied %d change(s), %d deletion(s) from SketchUp"
            % (len(to_apply), len(to_del)))
    except Exception as e:
        log("pull failed: %r" % e)
    finally:
        _busy = False


def apply_imports(d, col, to_apply, state):
    ensure_object_mode()

    # free the target names so the importer doesn't get ".001" suffixes
    renamed = []
    for name, _rev, _c in to_apply:
        o = bpy.data.objects.get(name)
        if o:
            o.name = name + ".__old"
            renamed.append((name, o))

    tmp = bpy.data.collections.new("__su_import_tmp")
    bpy.context.scene.collection.children.link(tmp)
    prev_lc = bpy.context.view_layer.active_layer_collection
    lc = find_layer_collection(bpy.context.view_layer.layer_collection,
                               "__su_import_tmp")
    if lc:
        bpy.context.view_layer.active_layer_collection = lc
    try:
        bpy.ops.import_scene.gltf(filepath=os.path.join(d, IN_GLB))
    finally:
        try:
            bpy.context.view_layer.active_layer_collection = prev_lc
        except Exception:
            pass

    imported_tops = [o for o in tmp.objects if o.parent is None]
    by_name = {}
    for o in imported_tops:
        by_name.setdefault(strip_suffix(o.name), o)
        by_name.setdefault(o.name, o)
    # one level deeper: children of collection-group wrappers from SketchUp
    for o in imported_tops:
        for c in o.children:
            by_name.setdefault(strip_suffix(c.name), c)
            by_name.setdefault(c.name, c)

    applied_names = set()
    for name, rev, cname in to_apply:
        src = by_name.get(name)
        if src is None:
            log("object '%s' not found in incoming GLB" % name)
            continue
        if src.parent is not None:  # unwrap from a collection-group node
            mw = src.matrix_world.copy()
            src.parent = None
            src.matrix_world = mw
        # move the whole hierarchy into the right collection
        target = ensure_subcollection(col, cname) if cname else col
        for ob in hierarchy(src):
            for c in list(ob.users_collection):
                c.objects.unlink(ob)
            target.objects.link(ob)
        # remove the old version
        old = bpy.data.objects.get(name + ".__old")
        if old:
            delete_hierarchy(old)
        src.name = name
        applied_names.add(name)
        state["objects"][name] = {
            "rev": rev, "origin": "sketchup",
            "local_hash": obj_hash(src), "collection": cname}

    # restore names of holders whose replacement never arrived
    for name, o in renamed:
        if name not in applied_names:
            try:
                o.name = name
            except Exception:
                pass

    # drop everything else that came with the GLB
    for o in list(tmp.objects):
        delete_hierarchy(o)
    bpy.data.collections.remove(tmp)

    # prune empty sub-collections after moves/deletions
    for sub in list(col.children):
        if not sub.all_objects:
            try:
                bpy.data.collections.remove(sub)
            except Exception:
                pass


# -------------------------------------------------------- handlers/timer ---

@persistent
def _on_save_post(_dummy):
    if enabled():
        # run slightly later, outside the handler, where operators are safe
        bpy.app.timers.register(_push_once, first_interval=0.2)


def _push_once():
    do_push()
    return None


@persistent
def _on_load_post(_dummy):
    global _last_in_mtime
    _last_in_mtime = None  # new file — allow first pull


def _poll():
    try:
        if enabled():
            do_pull(False)
    except Exception as e:
        log("poll error: %r" % e)
    return POLL_SECONDS


# ---------------------------------------------------------------------- UI ---

class SUSYNC_OT_pull(bpy.types.Operator):
    bl_idname = "susync.pull"
    bl_label = "Pull from SketchUp now"

    def execute(self, context):
        do_pull(True)
        return {"FINISHED"}


class SUSYNC_OT_push(bpy.types.Operator):
    bl_idname = "susync.push"
    bl_label = "Push to SketchUp now"

    def execute(self, context):
        do_push()
        return {"FINISHED"}


class SUSYNC_PT_panel(bpy.types.Panel):
    bl_label = "SketchUp Sync"
    bl_space_type = "PROPERTIES"
    bl_region_type = "WINDOW"
    bl_context = "scene"

    def draw(self, context):
        lay = self.layout
        d = bridge_dir()
        lay.prop(context.scene, "su_sync_enabled", text="Sync on save")
        lay.label(text="Bridge: %s" % (d if d else "— save the .blend first"))
        lay.label(text="Objects go in the '%s' collection" % COLLECTION)
        row = lay.row()
        row.operator("susync.push")
        row.operator("susync.pull")


CLASSES = (SUSYNC_OT_pull, SUSYNC_OT_push, SUSYNC_PT_panel)


def register():
    for c in CLASSES:
        bpy.utils.register_class(c)
    bpy.types.Scene.su_sync_enabled = bpy.props.BoolProperty(
        name="Sync on save", default=True)
    if _on_save_post not in bpy.app.handlers.save_post:
        bpy.app.handlers.save_post.append(_on_save_post)
    if _on_load_post not in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.append(_on_load_post)
    if not bpy.app.timers.is_registered(_poll):
        bpy.app.timers.register(_poll, first_interval=POLL_SECONDS,
                                persistent=True)


def unregister():
    if _on_save_post in bpy.app.handlers.save_post:
        bpy.app.handlers.save_post.remove(_on_save_post)
    if _on_load_post in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.remove(_on_load_post)
    if bpy.app.timers.is_registered(_poll):
        bpy.app.timers.unregister(_poll)
    del bpy.types.Scene.su_sync_enabled
    for c in reversed(CLASSES):
        bpy.utils.unregister_class(c)


if __name__ == "__main__":
    register()
