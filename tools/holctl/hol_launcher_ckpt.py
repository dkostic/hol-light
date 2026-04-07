#!/usr/bin/env python3
"""Launch HOL Light from a DMTCP checkpoint with hol_server, daemonizing properly."""
import os, pty, subprocess, sys, time, socket

def find_new_ocaml_hol_pid(exclude_pids):
    """Find the PID of the restored ocaml-hol process, excluding known PIDs."""
    try:
        result = subprocess.run(
            ["pgrep", "-f", "ocaml-hol"],
            capture_output=True, text=True, timeout=5
        )
        for p in result.stdout.strip().split():
            if p and int(p) not in exclude_pids:
                return int(p)
    except Exception:
        pass
    return None

def main():
    hol_dir = sys.argv[1]
    port = int(sys.argv[2])
    server_ml = sys.argv[3]
    log_file = sys.argv[4]
    pid_file = sys.argv[5]
    ckpt_dir = sys.argv[6]
    hotfix_ml = sys.argv[7] if len(sys.argv) > 7 else None

    restart_script = os.path.join(ckpt_dir, "dmtcp_restart_script.sh")

    # Double-fork to daemonize
    if os.fork() > 0:
        sys.exit(0)
    os.setsid()
    if os.fork() > 0:
        sys.exit(0)

    sys.stdin.close()
    log = open(log_file, "w")
    os.dup2(log.fileno(), 1)
    os.dup2(log.fileno(), 2)

    # Note pre-existing ocaml-hol PIDs
    existing = set()
    try:
        result = subprocess.run(["pgrep", "-f", "ocaml-hol"],
                                capture_output=True, text=True, timeout=5)
        existing = {int(p) for p in result.stdout.strip().split() if p}
    except Exception:
        pass

    # Get a free DMTCP coordinator port
    s = socket.socket(); s.bind(('', 0)); coord_port = s.getsockname()[1]; s.close()
    env = os.environ.copy()
    env["DMTCP_COORD_PORT"] = str(coord_port)

    # Use a pty so ledit doesn't fail on tcsetattr
    master_fd, slave_fd = pty.openpty()

    subprocess.Popen(
        ["bash", restart_script],
        stdin=slave_fd,
        stdout=log,
        stderr=log,
        env=env,
        cwd=hol_dir,
    )
    os.close(slave_fd)

    # Poll for the restored ocaml-hol process
    ocaml_pid = None
    for _ in range(30):
        time.sleep(1)
        ocaml_pid = find_new_ocaml_hol_pid(existing)
        if ocaml_pid:
            break

    if not ocaml_pid:
        print("ERROR: Could not find restored ocaml-hol process", file=sys.stderr)
        sys.exit(1)

    with open(pid_file, "w") as f:
        f.write(str(ocaml_pid))

    time.sleep(2)

    def send(line):
        os.write(master_fd, (line + "\n").encode())
        time.sleep(0.3)

    # Load hol_server. Note: ledit is in the path (bash->ledit->ocaml-hol).
    # We do NOT replace stdin here because that would disconnect the pty.
    # Instead, we keep the pty open and the server will use select() on stdin
    # which will just block (pty stays open as long as master_fd is open).
    send('#directory "+unix";;')
    send('#directory "+threads";;')
    send('#load "unix.cma";;')
    send('#load "threads.cma";;')
    send('unset_jrh_lexer;;')
    send(f'#use "{server_ml}";;')
    send('set_jrh_lexer;;')
    send(f'start ~single_connection:false {port};;')

    # Keep master_fd open so the pty stays alive and server doesn't exit.
    while True:
        try:
            os.kill(ocaml_pid, 0)
            time.sleep(5)
        except (OSError, ProcessLookupError):
            break

    os.close(master_fd)
    sys.exit(0)

if __name__ == "__main__":
    main()
