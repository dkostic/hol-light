#!/usr/bin/env python3
"""Launch HOL Light with hol_server, daemonizing properly."""
import os, subprocess, sys, time

def main():
    hol_dir = sys.argv[1]
    port = int(sys.argv[2])
    server_ml = sys.argv[3]
    log_file = sys.argv[4]
    pid_file = sys.argv[5]
    extra_loads = sys.argv[6:]

    ocaml_hol = os.path.join(hol_dir, "ocaml-hol")

    # Double-fork to daemonize
    if os.fork() > 0:
        sys.exit(0)
    os.setsid()
    if os.fork() > 0:
        sys.exit(0)

    # Redirect stdio
    sys.stdin.close()
    log = open(log_file, "w")
    os.dup2(log.fileno(), 1)
    os.dup2(log.fileno(), 2)

    proc = subprocess.Popen(
        [ocaml_hol, "-I", hol_dir],
        stdin=subprocess.PIPE,
        stdout=log,
        stderr=log,
        env={**os.environ, "HOLLIGHT_DIR": hol_dir},
        cwd=hol_dir,
    )

    # Write PID file (the ocaml-hol process, not us)
    with open(pid_file, "w") as f:
        f.write(str(proc.pid))

    def send(line):
        proc.stdin.write((line + "\n").encode())
        proc.stdin.flush()

    send(f'#use "{os.path.join(hol_dir, "hol.ml")}";;')
    for ml in extra_loads:
        send(f'needs "{ml}";;')
    send('#directory "+unix";;')
    send('#directory "+threads";;')
    send('#load "unix.cma";;')
    send('#load "threads.cma";;')
    send('unset_jrh_lexer;;')
    send(f'#use "{server_ml}";;')
    # Replace stdin with a blocking pipe so server2's select() on stdin blocks forever
    # Must run before set_jrh_lexer since tuple patterns don't work under camlp5
    send('let p = Unix.pipe () in Unix.dup2 (fst p) Unix.stdin; Unix.close (fst p);;')
    send('set_jrh_lexer;;')
    send(f'start ~single_connection:false {port};;')

    # Keep alive — our stdin pipe to ocaml-hol must stay open
    proc.wait()
    sys.exit(proc.returncode or 0)

if __name__ == "__main__":
    main()
