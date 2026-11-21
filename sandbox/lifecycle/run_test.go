package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func wrapperTestConfig(path string) runConfig {
	cfg := defaultRunConfig()
	cfg.socket = path
	cfg.retry = 500 * time.Millisecond
	cfg.interval = 10 * time.Millisecond
	cfg.joinTimeout = 100 * time.Millisecond
	cfg.rejoin = 500 * time.Millisecond
	cfg.hardExit = 100 * time.Millisecond
	return cfg
}

const testGrace = 150 * time.Millisecond

// Run in a separate process so Wait4(-1), signal handling and Pdeathsig
// exercise the wrapper in isolation from the test driver.
func TestHelperWrapper(t *testing.T) {
	if os.Getenv("LIFECYCLE_TEST_WRAPPER") != "1" {
		return
	}
	name := os.Args[3]
	cfg := wrapperTestConfig("broker.sock")
	m := members[name]
	m.grace = testGrace
	if os.Getenv("LIFECYCLE_TEST_NO_KILL") == "1" {
		cfg.signal = func(pid int, sig syscall.Signal) error {
			fmt.Fprintf(os.Stderr, "signal %d %d\n", pid, sig)
			return nil
		}
	}
	if os.Getenv("LIFECYCLE_TEST_STALL_START") == "1" {
		stall := func([]string, bool, chan<- int, chan<- childExit) {
			if err := os.WriteFile("starting", []byte(strconv.Itoa(os.Getpid())), 0600); err != nil {
				panic(err)
			}
			select {}
		}
		os.Exit(runWithStart(context.Background(), cfg, m, name, os.Args[4:], stall))
	}
	os.Exit(run(context.Background(), cfg, m, name, os.Args[4:]))
}

func wrapperCommand(t *testing.T, dir, name string, argv ...string) *exec.Cmd {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	t.Cleanup(cancel)
	cmd := exec.CommandContext(ctx, os.Args[0], append([]string{"-test.run=^TestHelperWrapper$", "--", name}, argv...)...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "LIFECYCLE_TEST_WRAPPER=1", "GORACE=atexit_sleep_ms=0")
	return cmd
}

func startWrapper(t *testing.T, cmd *exec.Cmd) {
	t.Helper()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if cmd.ProcessState == nil {
			cmd.Process.Kill()
			cmd.Wait()
		}
	})
}

func wrapperExit(t *testing.T, cmd *exec.Cmd, want int) {
	t.Helper()
	err := cmd.Wait()
	if cmd.ProcessState == nil || cmd.ProcessState.ExitCode() != want {
		t.Fatalf("wanted wrapper exit %d, got %v (%v)", want, cmd.ProcessState, err)
	}
}

func listenForWrapper(t *testing.T, dir string) *net.UnixListener {
	t.Helper()
	l, err := net.ListenUnix("unix", &net.UnixAddr{Name: filepath.Join(dir, "broker.sock"), Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	return l
}

func acceptWrapper(t *testing.T, l *net.UnixListener, name string) net.Conn {
	t.Helper()
	l.SetDeadline(time.Now().Add(5 * time.Second))
	c, err := l.Accept()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	c.SetDeadline(time.Now().Add(5 * time.Second))
	line, err := bufio.NewReader(c).ReadString('\n')
	if err != nil || line != formatJoin(name) {
		t.Fatalf("join = %q, %v", line, err)
	}
	return c
}

func sendWrapper(t *testing.T, c net.Conn, msg byte) {
	t.Helper()
	if _, err := c.Write([]byte{msg}); err != nil {
		t.Fatal(err)
	}
}

func requireLeave(t *testing.T, c net.Conn) {
	t.Helper()
	var b [1]byte
	if n, err := c.Read(b[:]); n != 0 || err != io.EOF {
		t.Fatalf("expected EOF, got %q, %v", b[:n], err)
	}
}

func childPID(t *testing.T, dir, file string) int {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		b, err := os.ReadFile(filepath.Join(dir, file))
		if err == nil {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && pid > 0 {
				return pid
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("child did not write %s", file)
	return 0
}

func requireGone(t *testing.T, pid int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
		// A reap before open gives ENOENT. A reap between open and read gives ESRCH.
		if errors.Is(err, os.ErrNotExist) || errors.Is(err, syscall.ESRCH) {
			return
		}
		if err != nil {
			t.Fatal(err)
		}
		end := strings.LastIndexByte(string(b), ')')
		if end >= 0 && bytes.HasPrefix(b[end+1:], []byte(" Z ")) {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("pid %d is still running", pid)
}

func TestWrapperNoListener(t *testing.T) {
	cfg := wrapperTestConfig(filepath.Join(t.TempDir(), "broker.sock"))
	cfg.retry = 40 * time.Millisecond
	start := time.Now()
	code := run(t.Context(), cfg, members["codex"], "codex", []string{"true"})
	if code != 1 || time.Since(start) < cfg.retry {
		t.Fatalf("exit %d after %s", code, time.Since(start))
	}
}

func TestWrapperLateListener(t *testing.T) {
	dir := t.TempDir()
	cfg := wrapperTestConfig(filepath.Join(dir, "broker.sock"))
	result := make(chan int, 1)
	go func() {
		result <- run(t.Context(), cfg, members["publish"], "publish", []string{"sh", "-c", "exit 3"})
	}()
	time.Sleep(3 * cfg.interval)
	l := listenForWrapper(t, dir)
	// Let the first handshake time out after the listener appears.
	requireLeave(t, acceptWrapper(t, l, "publish"))
	c := acceptWrapper(t, l, "publish")
	sendWrapper(t, c, msgAdmit)
	if code := <-result; code != 3 {
		t.Fatalf("exit %d, want 3", code)
	}
	requireLeave(t, c)
}

func TestWrapperScriptWithoutShebang(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "project-script")
	script := `[ "$#" -eq 2 ] && [ "$1" = "two words" ] && [ -z "$2" ] && exit 7
exit 1
`
	if err := os.WriteFile(path, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	l := listenForWrapper(t, dir)
	cmd := wrapperCommand(t, dir, "codex", "project-script", "two words", "")
	cmd.Env = append(cmd.Env, "PATH="+dir)
	startWrapper(t, cmd)
	sendWrapper(t, acceptWrapper(t, l, "codex"), msgAdmit)
	wrapperExit(t, cmd, 7)
}

func TestWrapperRefusal(t *testing.T) {
	dir := t.TempDir()
	l := listenForWrapper(t, dir)
	cmd := wrapperCommand(t, dir, "codex", "touch", "ran")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	startWrapper(t, cmd)
	sendWrapper(t, acceptWrapper(t, l, "codex"), msgRefuse)
	wrapperExit(t, cmd, exitRefused)
	if stderr.String() != "sandbox-lifecycle: the session group is stopping; start the session again.\n" {
		t.Fatalf("stderr = %q", stderr.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "ran")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("checking refusal marker: %v", err)
	}
}

func TestStopDuringAdmission(t *testing.T) {
	for _, tc := range []struct {
		name string
		code int
	}{
		{"publish", 0},
		{"codex", 128 + int(syscall.SIGTERM)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			l := listenForWrapper(t, dir)
			cmd := wrapperCommand(t, dir, tc.name, "touch", "ran")
			startWrapper(t, cmd)
			c := acceptWrapper(t, l, tc.name)
			if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
				t.Fatal(err)
			}
			wrapperExit(t, cmd, tc.code)
			requireLeave(t, c)
			if _, err := os.Stat(filepath.Join(dir, "ran")); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("checking child marker: %v", err)
			}
		})
	}
}

func TestBrokerStopDuringChildStart(t *testing.T) {
	for _, reason := range []string{"stop", "lost"} {
		t.Run(reason, func(t *testing.T) {
			dir := t.TempDir()
			l := listenForWrapper(t, dir)
			cmd := wrapperCommand(t, dir, "publish", "true")
			cmd.Env = append(cmd.Env, "LIFECYCLE_TEST_STALL_START=1", "LIFECYCLE_TEST_NO_KILL=1")
			var stderr bytes.Buffer
			cmd.Stderr = &stderr
			startWrapper(t, cmd)
			c := acceptWrapper(t, l, "publish")
			sendWrapper(t, c, msgAdmit)
			childPID(t, dir, "starting")

			cfg := wrapperTestConfig("")
			limit := testGrace + cfg.hardExit
			want := "sandbox-lifecycle: publish did not stop in time; forcing exit.\n"
			start := time.Now()
			if reason == "lost" {
				l.Close()
				c.Close()
				limit += cfg.rejoin
				want = "sandbox-lifecycle: lost the lifecycle broker\n" + want
			} else {
				sendWrapper(t, c, msgStop)
			}
			wrapperExit(t, cmd, 1)
			if elapsed := time.Since(start); elapsed < limit || elapsed > limit+500*time.Millisecond {
				t.Fatalf("hard exit during start after %s, expected %s", elapsed, limit)
			}
			if got := stderr.String(); got != want {
				t.Fatalf("stderr = %q, want %q", got, want)
			}
		})
	}
}

func TestServiceStop(t *testing.T) {
	dir := t.TempDir()
	l := listenForWrapper(t, dir)
	cmd := wrapperCommand(t, dir, "publish", "sh", "-c", "trap 'touch stopped; exit 0' TERM; sleep 30 & echo $! > grandchild; wait")
	startWrapper(t, cmd)
	c := acceptWrapper(t, l, "publish")
	sendWrapper(t, c, msgAdmit)
	grandchild := childPID(t, dir, "grandchild")
	sendWrapper(t, c, msgStop)
	wrapperExit(t, cmd, 0)
	if _, err := os.Stat(filepath.Join(dir, "stopped")); err != nil {
		t.Fatalf("TERM trap: %v", err)
	}
	requireGone(t, grandchild)
	requireLeave(t, c)
}

func TestServiceGroupKill(t *testing.T) {
	dir := t.TempDir()
	l := listenForWrapper(t, dir)
	cmd := wrapperCommand(t, dir, "publish", "sh", "-c", "trap '' TERM; sleep 30 & echo $! > grandchild; wait")
	startWrapper(t, cmd)
	c := acceptWrapper(t, l, "publish")
	sendWrapper(t, c, msgAdmit)
	grandchild := childPID(t, dir, "grandchild")
	start := time.Now()
	sendWrapper(t, c, msgStop)
	wrapperExit(t, cmd, 0)
	if time.Since(start) < testGrace {
		t.Fatal("wrapper killed the group before grace expired")
	}
	requireGone(t, grandchild)
}

func TestWrapperHardExit(t *testing.T) {
	dir := t.TempDir()
	l := listenForWrapper(t, dir)
	cmd := wrapperCommand(t, dir, "publish", "sh", "-c", "echo $$ > ready; exec sleep 30")
	cmd.Env = append(cmd.Env, "LIFECYCLE_TEST_NO_KILL=1")
	// The child inherits stderr and could keep an os/exec copy pipe open.
	log, err := os.Create(filepath.Join(dir, "log"))
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	cmd.Stderr = log
	startWrapper(t, cmd)
	c := acceptWrapper(t, l, "publish")
	sendWrapper(t, c, msgAdmit)
	pid := childPID(t, dir, "ready")
	defer syscall.Kill(pid, syscall.SIGKILL)
	start := time.Now()
	sendWrapper(t, c, msgStop)
	wrapperExit(t, cmd, 1)
	limit := testGrace + wrapperTestConfig("").hardExit
	if elapsed := time.Since(start); elapsed < limit || elapsed > limit+500*time.Millisecond {
		t.Fatalf("hard exit after %s, expected %s", elapsed, limit)
	}
	stderr, err := os.ReadFile(log.Name())
	if err != nil {
		t.Fatal(err)
	}
	want := fmt.Sprintf("signal %d %d\nsignal %d %d\nsandbox-lifecycle: publish did not stop in time; forcing exit.\n",
		pid, syscall.SIGTERM, -pid, syscall.SIGKILL)
	if string(stderr) != want {
		t.Fatalf("stderr = %q, want %q", stderr, want)
	}
}

func TestWrapperRejoin(t *testing.T) {
	for _, tc := range []struct {
		name    string
		reply   byte
		unknown bool
		code    int
	}{
		{"replacement", msgAdmit, false, 0},
		{"unexpected-byte", msgAdmit, true, 0},
		{"refused", msgRefuse, false, 0},
		{"lost", 0, false, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			l := listenForWrapper(t, dir)
			cmd := wrapperCommand(t, dir, "publish", "sh", "-c", "echo $$ >> children; exec sleep 30")
			var stderr bytes.Buffer
			cmd.Stderr = &stderr
			startWrapper(t, cmd)
			c := acceptWrapper(t, l, "publish")
			sendWrapper(t, c, msgAdmit)
			pid := childPID(t, dir, "children")
			l.Close()
			if tc.unknown {
				sendWrapper(t, c, '?')
			} else {
				c.Close()
			}
			if tc.reply != 0 {
				next := acceptWrapper(t, listenForWrapper(t, dir), "publish")
				sendWrapper(t, next, tc.reply)
				if tc.reply == msgAdmit {
					if err := syscall.Kill(pid, 0); err != nil {
						t.Fatalf("original child: %v", err)
					}
					sendWrapper(t, next, msgStop)
				}
			}
			wrapperExit(t, cmd, tc.code)
			if tc.reply == 0 && stderr.String() != "sandbox-lifecycle: lost the lifecycle broker\n" {
				t.Fatalf("stderr = %q", stderr.String())
			}
			b, err := os.ReadFile(filepath.Join(dir, "children"))
			if err != nil || string(b) != fmt.Sprintf("%d\n", pid) {
				t.Fatalf("child launches = %q, %v", b, err)
			}
			requireGone(t, pid)
		})
	}
}

func TestAgentSignals(t *testing.T) {
	dir := t.TempDir()
	l := listenForWrapper(t, dir)
	cmd := wrapperCommand(t, dir, "codex", "sh", "-c", `
		trap 'trap "exit 9" TERM; echo $$ > term' TERM
		trap 'echo $$ > hup' HUP
		echo $$ > ready
		while :; do sleep 0.02; done
	`)
	startWrapper(t, cmd)
	c := acceptWrapper(t, l, "codex")
	sendWrapper(t, c, msgAdmit)
	pid := childPID(t, dir, "ready")
	for _, sig := range []syscall.Signal{syscall.SIGINT, syscall.SIGHUP} {
		if err := cmd.Process.Signal(sig); err != nil {
			t.Fatal(err)
		}
	}
	if childPID(t, dir, "hup") != pid {
		t.Fatal("HUP did not reach original child")
	}
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	if childPID(t, dir, "term") != pid {
		t.Fatal("first TERM did not reach original child")
	}
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	wrapperExit(t, cmd, 9)
}

func TestParentDeath(t *testing.T) {
	dir := t.TempDir()
	l := listenForWrapper(t, dir)
	cmd := wrapperCommand(t, dir, "codex", "sh", "-c", "echo $$ > ready; exec sleep 30")
	startWrapper(t, cmd)
	c := acceptWrapper(t, l, "codex")
	sendWrapper(t, c, msgAdmit)
	pid := childPID(t, dir, "ready")
	defer syscall.Kill(pid, syscall.SIGKILL)
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	wrapperExit(t, cmd, -1)
	requireGone(t, pid)
}
