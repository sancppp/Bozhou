#!/usr/bin/env python3
"""Bounded real-PTY regression matrix; only a temporary HOME is modified.

Export with BozhouCoreTests --export-shells first. The same JSON and this script
can be run on a Linux host. --omz uses an existing installation without updates.
"""
import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import resource
import select
import shlex
import shutil
import signal
import struct
import tempfile
import termios
import time
from urllib.parse import unquote

PROMPT = b"__BZ_STABLE__> "
MARKER = re.compile(rb"\x1b\]777;bozhou;pty-test;([^\x07]*)\x07")


class Terminal:
    def __init__(self, command, home, shell):
        self.transcript = bytearray()
        env = {k: v for k, v in os.environ.items() if k in ("PATH", "LANG", "LC_ALL")}
        env.update(HOME=str(home), ZDOTDIR=str(home), TMPDIR=str(home), SHELL=shell,
                   TERM="xterm-256color", BASH_SILENCE_DEPRECATION_WARNING="1")
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            os.chdir(home)
            os.execve("/bin/sh", ["sh", "-c", command], env)
        self.resize(40, 160)

    def resize(self, rows, cols):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def send(self, text):
        data = text.encode() if isinstance(text, str) else text
        while data:
            written = os.write(self.fd, data)
            data = data[written:]

    def read(self, needle=PROMPT, timeout=10, eof=False):
        data = bytearray()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not select.select([self.fd], [], [], .05)[0]:
                if not eof and needle in data:
                    self.transcript.extend(data)
                    return bytes(data)
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                chunk = b""
            if not chunk:
                self.transcript.extend(data)
                assert eof, f"Unexpected EOF: {bytes(data[-800:])!r}"
                return bytes(data)
            data.extend(chunk)
        self.transcript.extend(data)
        raise AssertionError(f"PTY timeout: {bytes(data[-800:])!r}")

    def run(self, command, code=0):
        self.send(command + "\r")
        output = self.read()
        fields = [m.decode().split(";") for m in MARKER.findall(output)]
        commands = [unquote(m[2]) for m in fields if m[0] == "command"]
        statuses = [int(m[1]) for m in fields if m[0] == "end"]
        assert commands == [command], (commands, command, output[-800:])
        assert statuses == [code], (statuses, code, output[-800:])
        for error in (b"bad output format", b"readonly variable", b"maximum nested", b"invalid size"):
            assert error not in output, output[-800:]
        return output

    def close(self):
        os.close(self.fd)
        try:
            os.killpg(self.pid, signal.SIGHUP)
        except (ProcessLookupError, PermissionError):
            pass
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                if os.waitpid(self.pid, os.WNOHANG)[0]:
                    return
            except ChildProcessError:
                return
            time.sleep(.02)
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)


def run_profile(shell, bootstrap, omz, output_dir):
    name = shell.strip("/").replace("/", "-") + ("-omz" if omz else "")
    result = {"profile": name, "shell": shell, "omz": bool(omz), "passed": False}
    with tempfile.TemporaryDirectory(prefix="bozhou-stability-") as tmp:
        home = Path(tmp)
        zsh = shell.endswith("zsh")
        config = "HISTFILE=/dev/null\n"
        if omz:
            config += f"""
export ZSH={shlex.quote(str(omz))}
ZSH_CACHE_DIR="$HOME/cache"
ZSH_COMPDUMP="$HOME/.zcompdump"
zstyle ':omz:update' mode disabled
DISABLE_AUTO_UPDATE=true
ZSH_THEME=robbyrussell
plugins=(git)
source "$ZSH/oh-my-zsh.sh"
"""
        elif zsh:
            config += 'autoload -Uz compinit; compinit -d "$HOME/.zcompdump"\n'
        config += "PS1='__BZ_STABLE__> '\n"
        config += ("precmd() { BZ_USER_STATUS=$?; }\n" if zsh else
                   "PROMPT_COMMAND='BZ_USER_STATUS=$?'\n")
        (home / (".zshrc" if zsh else ".bashrc")).write_text(config)
        (home / "completion-target.txt").write_text("completion-ok\n")
        term = Terminal(bootstrap, home, shell)
        try:
            startup = term.read()
            assert b";ready;" in startup
            term.run("false", 1)
            assert b"status=1 user=1" in term.run('printf "status=%s user=%s\\n" "$?" "$BZ_USER_STATUS"')
            term.run(": previous_argument")
            assert b"last=previous_argument" in term.run('printf "last=%s\\n" "$_"')
            term.run("printf '中文 English %% ;\\n'")
            term.run("printf '%s\\n' \"$(printf substitution)\"")
            term.run("eval 'printf eval-ok'")
            term.run("false | true")
            term.run("set -o pipefail")
            term.run("false | true", 1)
            term.run("set +o pipefail")
            term.run("bz_test_fn() { for i in {1..1000}; do :; done; }; bz_test_fn")
            term.run("readonly cmd=reserved code=reserved")
            term.run("false", 1)
            if zsh:
                for _ in range(3):
                    term.run("source ~/.zshrc")
                    term.run("false", 1)
            term.run("set -u")
            term.run("false", 1)
            term.run("set +u")
            if zsh and not omz:
                term.run("setopt ksharrays shwordsplit")
                term.run("false", 1)
                term.run("unsetopt ksharrays shwordsplit")
            term.run("echo history-token")
            term.send(b"\x1b[A\r")
            assert b"command;" in term.read()
            term.send("cat completion-t\t\r")
            assert b"completion-ok" in term.read()
            # Bracketed paste and literal multiline input are processed by the real line editor.
            term.send(b"\x1b[200~printf 'paste-one\\npaste-two\\n'\x1b[201~\r")
            assert b"paste-two" in term.read()
            term.send("sleep 30\r")
            # Wait for exec, not just the preexec marker, before interrupting the foreground job.
            term.read(b"command;")
            time.sleep(.1)
            term.send(b"\x03")
            assert b"end;130\x07" in term.read()
            term.run("printf after-interrupt")
            term.run("sleep 0.1 & wait")
            term.run("/bin/bash --noprofile --norc -c 'printf nested-bash'")
            term.run("/bin/zsh -f -c 'printf nested-zsh'")
            for nested in ["/bin/bash --noprofile --norc -i", "/bin/zsh -dfi"]:
                term.send("PS1='__BZ_NESTED__> ' " + nested + "\r")
                term.read(b"__BZ_NESTED__> ")
                term.send("printf 'nested-interactive-alive\\n'\r")
                assert b"nested-interactive-alive" in term.read(b"__BZ_NESTED__> ")
                term.send("exit\r")
                assert b";end;0\x07" in term.read()
            if shutil.which("vim"):
                term.send("vim -Nu NONE -i NONE -n completion-target.txt\r")
                term.read(b"completion-ok")
                term.send(b"iinserted-text\x1b:q!\r")
                assert b";end;0\x07" in term.read()
                result["vim"] = True
            term.run("set -o vi")
            term.run("printf vi-editing-alive")
            term.run("set -o emacs")
            # Resize while printing enough data to cross several PTY read chunks.
            term.send("for i in {1..4000}; do printf '012345678901234567890123456789\\n'; done\r")
            for rows, cols in [(1, 1), (24, 80), (40, 160), (5, 12), (50, 200)] * 4:
                term.resize(rows, cols)
            out = term.read()
            assert b"end;0\x07" in out
            for _ in range(100):
                term.run(":")
            term.run("printf final-alive")
            if not zsh:
                # Explicitly replacing PROMPT_COMMAND removes optional recording. It
                # must leave the user's interactive shell and exit statuses working.
                for _ in range(3):
                    term.send("source ~/.bashrc\r")
                    term.read()
                    term.send("false\r")
                    term.read()
                    term.send('printf "reload-alive=%s\\n" "$?"\r')
                    out = term.read()
                    assert b"reload-alive=1" in out
                result["recording_after_rc_reload"] = b";end;" in out
            term.send(b"\x04")
            assert b";exit;0\x07" in term.read(eof=True)
            assert not list(home.glob("bozhou.*")), "Bootstrap files leaked"
            result["passed"] = True
        except Exception as error:
            result["error"] = str(error)
        finally:
            term.close()
            (output_dir / f"{name}.pty").write_bytes(term.transcript)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--shells", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--omz", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    bootstraps = json.loads(args.shells.read_text())
    results = []
    for shell, bootstrap in sorted(bootstraps.items()):
        if not shell.startswith("/") or not Path(shell).is_file():
            continue
        for omz in [None] + ([args.omz] if shell.endswith("zsh") and args.omz else []):
            result = run_profile(shell, bootstrap, omz, args.output)
            results.append(result)
            print(json.dumps(result, ensure_ascii=False), flush=True)
    (args.output / "results.json").write_text(json.dumps(results, indent=2, ensure_ascii=False))
    return 0 if results and all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
