"""RigPort — Blender-to-Godot character readiness pipeline (Blender side).

Prepares a humanoid mesh: markers -> rig -> auto-skin -> gameplay sockets ->
VO mouth shape keys -> deformation test poses -> validated GLB export.

Pairs with the RigPort Godot editor add-on, which validates the import and
produces the character readiness report.
"""

bl_info = {
    "name": "RigPort",
    "author": "GabagoolStudios",
    "version": (0, 2, 0),
    "blender": (4, 0, 0),
    "location": "3D Viewport > Sidebar (N) > RigPort",
    "description": "Rig it. Test it. Ship it to Godot. Guided humanoid character prep for Godot.",
    "category": "Rigging",
}

import importlib

from . import contracts, properties, operators, hitreact, hitreact_operators, panel

_MODULES = (contracts, properties, operators, hitreact, hitreact_operators, panel)


def register():
    for mod in _MODULES:
        importlib.reload(mod)
    properties.register()
    operators.register()
    hitreact_operators.register()
    panel.register()


def unregister():
    panel.unregister()
    hitreact_operators.unregister()
    operators.unregister()
    properties.unregister()


if __name__ == "__main__":
    register()
