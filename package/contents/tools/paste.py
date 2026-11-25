#!/usr/bin/env python3
"""Sends a paste shortcut to the focused window.

Used by the Rephraser widget to put a rewrite in place of the selected text:
the widget copies the result to the clipboard, closes its popup so the
original window has focus again, then runs this script.

  X11      -> xdotool
  Wayland  -> the RemoteDesktop portal (the desktop asks for permission the
              first time; the grant is remembered through a restore token)

Exit codes: 0 sent, 2 permission denied, 3 not available, 4 timed out.
A one-line reason is printed on stdout for the widget to show.
"""
import argparse
import os
import shutil
import subprocess
import sys

# Linux evdev key codes: layout independent for the keys used here on
# QWERTY and AZERTY keyboards.
KEY = {"ctrl": 29, "shift": 42, "v": 47, "insert": 110}
COMBOS = {
    "ctrl+v": ["ctrl", "v"],
    "ctrl+shift+v": ["ctrl", "shift", "v"],
    "shift+insert": ["shift", "insert"],
}
XDOTOOL = {"ctrl+v": "ctrl+v", "ctrl+shift+v": "ctrl+shift+v", "shift+insert": "shift+Insert"}

PORTAL = "org.freedesktop.portal.Desktop"
PORTAL_PATH = "/org/freedesktop/portal/desktop"
RD_IFACE = "org.freedesktop.portal.RemoteDesktop"
KEYBOARD = 1
PERSIST_UNTIL_REVOKED = 2


def token_file():
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(base, "rephraser", "portal-restore-token")


def read_token():
    try:
        with open(token_file(), encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def write_token(token):
    path = token_file()
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(token)
    except OSError:
        pass  # the user is simply asked again next time


def paste_x11(combo):
    if not shutil.which("xdotool"):
        print("Install xdotool to let Rephraser paste for you.")
        return 3
    result = subprocess.run(
        ["xdotool", "key", "--clearmodifiers", XDOTOOL[combo]], capture_output=True, timeout=10
    )
    if result.returncode != 0:
        print("xdotool could not send the paste shortcut.")
        return 3
    return 0


def paste_portal(combo, timeout_s):
    try:
        import dbus
        from dbus.mainloop.glib import DBusGMainLoop
        from gi.repository import GLib
    except ImportError:
        print("Install python3-dbus and python3-gi to let Rephraser paste for you.")
        return 3

    DBusGMainLoop(set_as_default=True)
    try:
        bus = dbus.SessionBus()
        remote = dbus.Interface(bus.get_object(PORTAL, PORTAL_PATH), RD_IFACE)
    except dbus.DBusException:
        print("The desktop portal is not running.")
        return 3

    loop = GLib.MainLoop()
    sender = bus.get_unique_name()[1:].replace(".", "_")
    state = {"code": 3, "session": None, "counter": 0}

    def finish(code, message=""):
        state["code"] = code
        if message:
            print(message)
        loop.quit()

    def call(method, args, options, on_ok):
        """Calls a portal method and waits for its Request.Response signal."""
        state["counter"] += 1
        handle = "rephraser%d_%d" % (os.getpid(), state["counter"])
        path = "%s/request/%s/%s" % (PORTAL_PATH, sender, handle)
        options = dict(options)
        options["handle_token"] = handle

        def on_response(code, results):
            match.remove()
            if code == 0:
                on_ok(results)
            elif code == 1:
                finish(2, "Permission to send the paste shortcut was not given.")
            else:
                finish(3, "The desktop portal refused the request.")

        match = bus.add_signal_receiver(
            on_response, "Response", "org.freedesktop.portal.Request", PORTAL, path
        )
        try:
            getattr(remote, method)(*args, dbus.Dictionary(options, signature="sv"))
        except dbus.DBusException as exc:
            match.remove()
            finish(3, "The desktop portal refused the request (%s)." % exc.get_dbus_name())

    def created(results):
        state["session"] = str(results["session_handle"])
        options = {"types": dbus.UInt32(KEYBOARD), "persist_mode": dbus.UInt32(PERSIST_UNTIL_REVOKED)}
        token = read_token()
        if token:
            options["restore_token"] = token
        call("SelectDevices", [dbus.ObjectPath(state["session"])], options, selected)

    def selected(_results):
        call("Start", [dbus.ObjectPath(state["session"]), ""], {}, started)

    def started(results):
        if not int(results.get("devices", 0)) & KEYBOARD:
            return finish(2, "Keyboard access was not granted.")
        token = results.get("restore_token")
        if token:
            write_token(str(token))
        # Give focus time to return to the target window if a permission
        # dialog was just shown.
        GLib.timeout_add(250, send_keys)

    def send_keys():
        session = dbus.ObjectPath(state["session"])
        empty = dbus.Dictionary({}, signature="sv")
        keys = [KEY[name] for name in COMBOS[combo]]
        try:
            for code in keys:
                remote.NotifyKeyboardKeycode(session, empty, dbus.Int32(code), dbus.UInt32(1))
            for code in reversed(keys):
                remote.NotifyKeyboardKeycode(session, empty, dbus.Int32(code), dbus.UInt32(0))
        except dbus.DBusException:
            finish(3, "The desktop refused the paste shortcut.")
            return False
        GLib.timeout_add(120, lambda: finish(0) or False)
        return False

    def timed_out():
        finish(4, "Timed out waiting for permission to paste.")
        return False

    GLib.timeout_add_seconds(timeout_s, timed_out)
    session_token = "rephraser%d" % os.getpid()
    call("CreateSession", [], {"session_handle_token": session_token}, created)
    loop.run()

    if state["session"]:
        try:
            session = dbus.Interface(
                bus.get_object(PORTAL, state["session"]), "org.freedesktop.portal.Session"
            )
            session.Close()
        except dbus.DBusException:
            pass
    return state["code"]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--keys", choices=sorted(COMBOS), default="ctrl+v")
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument(
        "--check", action="store_true", help="only report whether pasting can work, send nothing"
    )
    args = parser.parse_args()

    wayland = os.environ.get("XDG_SESSION_TYPE") == "wayland" or bool(os.environ.get("WAYLAND_DISPLAY"))
    if args.check:
        if wayland:
            try:
                import dbus  # noqa: F401
                from gi.repository import GLib  # noqa: F401
            except ImportError:
                print("python3-dbus and python3-gi are required")
                return 3
            print("wayland: portal")
            return 0
        if shutil.which("xdotool"):
            print("x11: xdotool")
            return 0
        print("xdotool is required")
        return 3
    return paste_portal(args.keys, args.timeout) if wayland else paste_x11(args.keys)


if __name__ == "__main__":
    sys.exit(main())
