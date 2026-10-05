#!/usr/bin/env python3
"""Real PTY compatibility checks. All startup/history/tmux files are project-local."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import signal
import statistics
import struct
import subprocess
import termios
import time
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / ".runtime/shell-matrix"
WORK.mkdir(parents=True, exist_ok=True)
BASH5 = os.environ.get("BOZHOU_TEST_BASH", shutil.which("bash") or "/bin/bash")
TMUX = os.environ.get("BOZHOU_TEST_TMUX", shutil.which("tmux"))
assert re.search(r"version (?:[5-9]|[1-9][0-9]+)\.", subprocess.check_output(
    [BASH5, "--version"], env={**os.environ, "LC_ALL": "C"}, text=True)), \
    "Set BOZHOU_TEST_BASH to a Bash 5+ executable"
assert TMUX, "Install tmux or set BOZHOU_TEST_TMUX"
subprocess.run([ROOT / ".build/debug/BozhouCoreTests", "--export-shells", WORK / "shells.json"],
               env={**os.environ, "BOZHOU_TEST_BASH": BASH5}, check=True)
BOOTSTRAPS = json.loads((WORK / "shells.json").read_text())
PROMPT = b"__BZ_PROMPT__ "
MARKER = re.compile(rb"\x1b\]777;bozhou;pty-test;([^\x07]*)\x07")


class Terminal:
    def __init__(self, command, env, home):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(home)
            os.execve("/bin/sh", ["sh", "-c", command], env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 240, 0, 0))
        self.transcript = bytearray()

    def read_until(self, needle=PROMPT, timeout=10):
        output = bytearray()
        deadline = time.monotonic() + timeout
        while needle not in output:
            if time.monotonic() >= deadline:
                raise AssertionError(f"PTY timeout waiting for {needle!r}: {bytes(output)[-2000:]!r}")
            if select.select([self.fd], [], [], 0.1)[0]:
                chunk = os.read(self.fd, 65536)
                if not chunk:
                    raise AssertionError("PTY ended before expected output")
                output.extend(chunk)
        self.transcript.extend(output)
        return bytes(output)

    def send(self, text):
        os.write(self.fd, text.encode() if isinstance(text, str) else text)

    def run(self, text, code=0):
        self.send(text + "\r")
        output = self.read_until()
        fields = [m.decode().split(";") for m in MARKER.findall(output)]
        commands = [unquote(m[2]) for m in fields if m[0] == "command"]
        statuses = [int(m[1]) for m in fields if m[0] == "end"]
        assert all(m[1].startswith("/") for m in fields if m[0] == "command"), fields
        assert commands == [text], (commands, text, output)
        assert statuses == [code], (statuses, code, output)
        return MARKER.sub(b"", output)

    def close(self):
        try:
            os.killpg(self.pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        os.close(self.fd)
        os.waitpid(self.pid, 0)


def environment(home, shell):
    return {
        "HOME": str(home), "ZDOTDIR": str(home), "TMPDIR": str(home / "tmp"),
        "SHELL": shell, "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        "BASH_SILENCE_DEPRECATION_WARNING": "1",
    }


def prepare(name, shell, omz):
    home = WORK / name
    home.mkdir(exist_ok=True)
    (home / "tmp").mkdir(exist_ok=True)
    (home / "completion-target.txt").write_text("completion-ok\n")
    (home / ".zshenv").write_text("export BZ_ENV_LOADED=yes\n")
    common = "HISTFILE=\"$HOME/history\"; HISTSIZE=1000; SAVEHIST=1000\n"
    if shell.endswith("/bash"):
        # Existing hooks must still run, and the original failure status must reach PROMPT_COMMAND.
        config = common + """
PS1='__BZ_PROMPT__ '
PROMPT_COMMAND='BZ_PROMPT_STATUS=$?'
bz_existing_debug() { BZ_DEBUG_SEEN=yes; }
trap 'bz_existing_debug "$_"' DEBUG
"""
        (home / ".bashrc").write_text(config)
    else:
        config = common
        if omz:
            config += f"""
export ZSH={shlex.quote(str(ROOT / ".runtime/ohmyzsh"))}
export ZSH_CACHE_DIR="$HOME/cache"
ZSH_COMPDUMP="$HOME/.zcompdump"
zstyle ':omz:update' mode disabled
ZSH_THEME="robbyrussell"
plugins=(git)
source "$ZSH/oh-my-zsh.sh"
"""
        else:
            config += "autoload -Uz compinit; compinit -d \"$HOME/.zcompdump\"\n"
        config += """
PROMPT='__BZ_PROMPT__ '
precmd() { BZ_PROMPT_STATUS=$?; }
"""
        (home / ".zshrc").write_text(config)
    return home


results = []
for name, shell, omz in [
    ("bash3", "/bin/bash", False),
    ("bash5", BASH5, False),
    ("zsh", "/bin/zsh", False),
    ("ohmyzsh", "/bin/zsh", True),
]:
    assert Path(shell).exists(), f"Missing {shell}"
    if omz:
        assert (ROOT / ".runtime/ohmyzsh/oh-my-zsh.sh").exists(), "Clone Oh My Zsh before this optional matrix"
    home = prepare(name, shell, omz)
    term = Terminal(BOOTSTRAPS[shell], environment(home, shell), home)
    try:
        term.read_until()
        term.run("false", 1)
        assert b"status=1 prompt=1" in term.run("printf 'status=%s prompt=%s\\n' \"$?\" \"$BZ_PROMPT_STATUS\"")
        term.run(": preserved_argument")
        assert b"last=preserved_argument" in term.run("printf 'last=%s\\n' \"$_\"")
        assert "中文 English % ;".encode() in term.run("printf '中文 English %% ;\\n'")
        term.run("false | true")
        term.run("set -o pipefail")
        term.run("false | true", 1)
        term.run("echo history-token")
        term.send(b"\x1b[A\r")
        assert b"command;" in term.read_until()  # Up-arrow must execute the previous command.
        term.send("cat completion-t\t\r")
        assert b"completion-ok" in term.read_until()
        term.send("sleep 30\r")
        term.read_until(b"command;")
        # The marker precedes exec; wait for the foreground process to start before signalling it.
        deadline = time.monotonic() + 3
        while not subprocess.run(["pgrep", "-P", str(term.pid), "-x", "sleep"], capture_output=True).stdout:
            assert time.monotonic() < deadline, "sleep did not start"
            time.sleep(0.01)
        term.send(b"\x03")
        interrupted = term.read_until()
        assert b"end;130\x07" in interrupted, interrupted
        term.run("echo after-interrupt")
        if shell.endswith("/bash"):
            assert b"debug=yes" in term.run("printf 'debug=%s\\n' \"$BZ_DEBUG_SEEN\"")
        else:
            assert b"env=yes" in term.run("printf 'env=%s\\n' \"$BZ_ENV_LOADED\"")
            assert not list((home / "tmp").glob("bozhou.*")), "Temporary startup files leaked"
        samples = []
        for _ in range(100):
            start = time.perf_counter()
            term.run(":")
            samples.append((time.perf_counter() - start) * 1000)
        # A shell loop is one interaction and must not record each iteration.
        start = time.perf_counter()
        term.run("for i in {1..10000}; do :; done")
        result = {"profile": name, "median_roundtrip_ms": round(statistics.median(samples), 3),
                  "loop_10000_ms": round((time.perf_counter() - start) * 1000, 3)}
    finally:
        (WORK / f"{name}.pty").write_bytes(term.transcript)
        term.close()
    baseline = Terminal(f"exec {shlex.quote(shell)} -i", environment(home, shell), home)
    try:
        baseline.read_until()
        samples = []
        for _ in range(100):
            start = time.perf_counter()
            baseline.send(":\r")
            baseline.read_until()
            samples.append((time.perf_counter() - start) * 1000)
        result["baseline_roundtrip_ms"] = round(statistics.median(samples), 3)
        result["added_roundtrip_ms"] = round(result["median_roundtrip_ms"] - result["baseline_roundtrip_ms"], 3)
        start = time.perf_counter()
        baseline.send("for i in {1..10000}; do :; done\r")
        baseline.read_until()
        result["baseline_loop_10000_ms"] = round((time.perf_counter() - start) * 1000, 3)
    finally:
        baseline.close()
    results.append(result)
    print(f"PASS {name}: status/prompt/$_/unicode/pipeline/history/completion/Ctrl-C/hooks/loop; {result}", flush=True)

# Exercise the exact local-terminal bootstrap with existing, fallback and absent OMZ.
for mode in ["loaded", "fallback", "absent"]:
    home = prepare("local-zsh-" + mode, "/bin/zsh", mode == "loaded")
    if mode == "fallback":
        install = home / ".oh-my-zsh"
        if not install.exists():
            install.symlink_to(ROOT / ".runtime/ohmyzsh", target_is_directory=True)
    elif mode == "absent":
        with (home / ".zshrc").open("a") as config:
            config.write('export ZSH="$HOME/no-oh-my-zsh"\n')
    term = Terminal(BOOTSTRAPS["local-zsh"], environment(home, "/bin/bash"), home)
    try:
        startup = term.read_until()
        assert b"ready;zsh\x07" in startup, startup
        assert b";system;" not in startup, "Local terminal unexpectedly ran the remote probe"
        expected = b"omz=0" if mode == "absent" else b"omz=1"
        output = term.run("printf 'shell=%s omz=%s local=%s env=%s\\n' \"$BOZHOU_SHELL\" \"$+functions[omz]\" \"${BOZHOU_LOCAL-unset}\" \"$BZ_ENV_LOADED\"")
        assert b"shell=/bin/zsh" in output and expected in output, output
        assert b"local=unset env=yes" in output, output
        term.run("false", 1)
        assert not list((home / "tmp").glob("bozhou.*")), "Local startup files leaked"
        results.append({"profile": "local-zsh-" + mode, "passed": True})
        print(f"PASS local zsh ({mode}): explicit zsh/default OMZ fallback/user config/recording/cleanup", flush=True)
    finally:
        (WORK / f"local-zsh-{mode}.pty").write_bytes(term.transcript)
        term.close()

# Oh My Tmux runs with its own socket/config/HOME; no existing tmux server is contacted.
home = prepare("ohmytmux", "/bin/bash", False)
shutil.copyfile(ROOT / ".runtime/ohmytmux/.tmux.conf", home / ".tmux.conf")
(home / ".tmux.conf.local").write_text("""
tmux_conf_update_plugins_on_launch=false
tmux_conf_update_plugins_on_reload=false
tmux_conf_uninstall_plugins_on_reload=false
set -g default-shell /bin/bash
set -g default-command '/bin/bash --noprofile --rcfile ~/.bashrc -i'
""")
env = environment(home, "/bin/bash")
socket = home / "tmux.sock"
tmux = [TMUX, "-S", str(socket)]
term = Terminal(BOOTSTRAPS["/bin/bash"], env, home)
try:
    term.read_until()
    term.send(shlex.join(tmux + ["-f", str(home / ".tmux.conf"), "new-session", "-s", "bozhou-test"]) + "\r")
    term.read_until(PROMPT)
    term.send("printf 'tmux-中文-ok\\n'\r")
    term.read_until("tmux-中文-ok".encode())
    captured = subprocess.check_output(tmux + ["capture-pane", "-p"], env=env).decode()
    assert "tmux-中文-ok" in captured
    subprocess.run(tmux + ["split-window", "-h"], env=env, check=True)
    panes = subprocess.check_output(tmux + ["list-panes", "-F", "#{pane_id}"], env=env).splitlines()
    assert len(panes) == 2
    subprocess.run(tmux + ["detach-client"], env=env, check=True)
    detached = term.read_until(b"[detached (from session bozhou-test)]")
    if PROMPT not in detached.split(b"[detached (from session bozhou-test)]", 1)[1]:
        term.read_until()
    term.run("echo outer-shell-recording-ok")
    print("PASS Oh My Tmux: attach/UTF-8/split/detach/outer recording; inner shells retain their own configuration", flush=True)
finally:
    subprocess.run(tmux + ["kill-server"], env=env, capture_output=True)
    (WORK / "ohmytmux.pty").write_bytes(term.transcript)
    term.close()

(WORK / "results.json").write_text(json.dumps(results, indent=2))
print("Shell matrix complete", flush=True)
