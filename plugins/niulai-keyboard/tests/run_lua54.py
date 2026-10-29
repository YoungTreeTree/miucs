#!/usr/bin/env python3
"""Run tests using system liblua5.4, not Miucs's production worker/renderer."""
import ctypes,ctypes.util,os,sys
from pathlib import Path
lib=ctypes.CDLL(ctypes.util.find_library('lua5.4') or 'liblua5.4.so.0')
lib.luaL_newstate.restype=ctypes.c_void_p
L=lib.luaL_newstate()
lib.luaL_openlibs.argtypes=[ctypes.c_void_p];lib.luaL_openlibs(L)
lib.luaL_loadfilex.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p]
lib.lua_pcallk.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_ssize_t,ctypes.c_void_p]
lib.lua_tolstring.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.POINTER(ctypes.c_size_t)];lib.lua_tolstring.restype=ctypes.c_char_p
lib.lua_close.argtypes=[ctypes.c_void_p]
os.chdir(Path(__file__).resolve().parents[1])
status=0
for script in [b'tests/test_motion.lua',b'tests/test_keyboard.lua']:
 status=lib.luaL_loadfilex(L,script,None)
 if not status:status=lib.lua_pcallk(L,0,-1,0,0,None)
 if status:break
if status:print(lib.lua_tolstring(L,-1,None).decode(),file=sys.stderr)
lib.lua_close(L)
sys.exit(bool(status))
