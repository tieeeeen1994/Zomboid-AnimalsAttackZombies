#!/usr/bin/env python3
"""Run the offline fight tests.

Needs `lupa` (Lua 5.1): `python tests/run_tests.py`

Each test gets a fresh Lua state with fake_pz.lua, the real vanilla animal definitions from
the installed game, and the mod's own Lua loaded the way the game does: shared, then client,
then server, each folder in alphabetical order, with `require` resolving across all three.
"""
import glob
import os
import re
import sys

import lupa.lua51 as lua51

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MOD = os.path.join(ROOT, "Contents", "mods", "AnimalsAttackZombies", "42", "media", "lua")
GAME = r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\media\lua"
OPTIONS = os.path.join(ROOT, "Contents", "mods", "AnimalsAttackZombies", "42", "media", "sandbox-options.txt")
DEFINITIONS = ["CowDefinitions", "PigDefinitions", "SheepDefinitions", "ChickenDefinitions", "TurkeyDefinitions"]


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def sandbox_defaults():
    """name -> default, straight from sandbox-options.txt."""
    values = {}
    for name, body in re.findall(r"option AnimalsAttackZombies\.(\w+)\s*\{([^}]*)\}", read(OPTIONS)):
        kind = re.search(r"type\s*=\s*(\w+)", body).group(1)
        raw = re.search(r"default\s*=\s*([^,\s]+)", body).group(1)
        values[name] = raw == "true" if kind == "boolean" else float(raw)
    return values


def mod_files(side):
    return sorted(glob.glob(os.path.join(MOD, side, "**", "*.lua"), recursive=True),
                  key=lambda p: os.path.relpath(p, MOD).replace("\\", "/").lower())


def new_state(mode):
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g.MODE = mode
    lua.execute("math.randomseed(1)")
    lua.execute(read(os.path.join(HERE, "fake_pz.lua")))
    options = g.SandboxVars.AnimalsAttackZombies
    for name, value in sandbox_defaults().items():
        options[name] = value

    modules = {}
    for side in ("shared", "client", "server"):
        for path in mod_files(side):
            modules[os.path.splitext(os.path.basename(path))[0]] = path
    loaded = set()

    def load(path):
        if path in loaded:
            return
        loaded.add(path)
        lua.execute(read(path))

    def require(name):
        path = modules.get(name)
        if path is None:
            raise RuntimeError("require: no module " + name)
        load(path)

    g.require = require

    for name in DEFINITIONS:
        lua.execute(read(os.path.join(GAME, "shared", "Definitions", "animal", name + ".lua")))
    for side in ("shared", "client", "server"):
        for path in mod_files(side):
            load(path)

    lua.execute(read(os.path.join(HERE, "test_fight.lua")))
    return lua


def main():
    probe = new_state("sp")
    names = sorted(probe.globals().Tests.keys())
    modes = probe.globals().TestModes
    failed = 0
    for name in names:
        mode = modes[name] or "sp"
        lua = new_state(mode)
        try:
            lua.globals().Tests[name]()
            print(f"ok    {name} ({mode})")
        except lua51.LuaError as e:
            failed += 1
            print(f"FAIL  {name} ({mode}): {e}")
    print(f"\n{len(names) - failed}/{len(names)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
