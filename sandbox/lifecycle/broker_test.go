package main

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testBrokerConfig(t *testing.T) brokerConfig {
	dir := t.TempDir()
	return brokerConfig{
		dir:     dir,
		control: filepath.Join(dir, "control.sock"),
		startup: 96 * time.Millisecond,
		idle:    80 * time.Millisecond,
		margin:  40 * time.Millisecond,
		drain:   90 * time.Millisecond,
	}
}

func rolePath(cfg brokerConfig, subdir string) string {
	return filepath.Join(cfg.dir, subdir, "lifecycle.sock")
}

func startBroker(t *testing.T, cfg brokerConfig) (context.CancelFunc, <-chan struct{}) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		if err := serve(ctx, cfg); err != nil {
			t.Errorf("serve: %v", err)
		}
	}()
	t.Cleanup(func() {
		cancel()
		waitBroker(t, done)
	})
	end := time.Now().Add(time.Second)
	for time.Now().Before(end) {
		if reply, err := requestControl(cfg.control, controlReady); err == nil && reply == "ok\n" {
			return cancel, done
		}
		select {
		case <-done:
			t.Fatal("broker exited before ready")
		case <-time.After(time.Millisecond):
		}
	}
	t.Fatal("broker never became ready")
	return nil, nil
}

func waitBroker(t *testing.T, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("broker did not exit")
	}
}

func wireJoin(t *testing.T, path, wire string) (net.Conn, byte) {
	t.Helper()
	conn, err := net.DialTimeout("unix", path, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	conn.SetDeadline(time.Now().Add(time.Second))
	if _, err := io.WriteString(conn, wire); err != nil {
		t.Fatal(err)
	}
	var reply [1]byte
	if _, err := io.ReadFull(conn, reply[:]); err != nil {
		t.Fatal(err)
	}
	return conn, reply[0]
}

func join(t *testing.T, path, name string) (net.Conn, byte) {
	t.Helper()
	return wireJoin(t, path, formatJoin(name))
}

func admitted(t *testing.T, cfg brokerConfig, subdir, name string) net.Conn {
	t.Helper()
	conn, reply := join(t, rolePath(cfg, subdir), name)
	if reply != msgAdmit {
		t.Fatalf("%s joining %s: got %q, want A", name, subdir, reply)
	}
	return conn
}

func wantStop(t *testing.T, conn net.Conn) {
	t.Helper()
	var msg [1]byte
	if _, err := io.ReadFull(conn, msg[:]); err != nil || msg[0] != msgStop {
		t.Fatalf("reading stop: got %q, %v", msg, err)
	}
}

func wantEOF(t *testing.T, conn net.Conn) {
	t.Helper()
	var msg [1]byte
	if n, err := conn.Read(msg[:]); n != 0 || err != io.EOF {
		t.Fatalf("want EOF, got %q, %v", msg[:n], err)
	}
}

func controlReply(t *testing.T, cfg brokerConfig, command string) string {
	t.Helper()
	reply, err := requestControl(cfg.control, command)
	if err != nil {
		t.Fatal(err)
	}
	return reply
}

func waitStatus(t *testing.T, cfg brokerConfig, want string) {
	t.Helper()
	end := time.Now().Add(time.Second)
	for {
		got := controlReply(t, cfg, controlStatus)
		if strings.Contains(got, want) {
			return
		}
		if time.Now().After(end) {
			t.Fatalf("waiting for %q in status, got %q", want, got)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestBrokerStartup(t *testing.T) {
	cfg := testBrokerConfig(t)
	_, done := startBroker(t, cfg)
	service := admitted(t, cfg, "services", "publish")
	wantStop(t, service)
	if got := controlReply(t, cfg, controlReady); got != "draining\n" {
		t.Fatalf("ready during drain = %q", got)
	}
	service.Close()
	select {
	case <-done:
	case <-time.After(cfg.drain / 2):
		t.Fatal("broker kept draining after the last member disconnected")
	}
}

func TestBrokerStartupExtension(t *testing.T) {
	for _, tt := range []struct {
		subdir, name string
		extends      bool
	}{
		{"services", "ssh-agent", true},
		{"daemon", "docker", false},
	} {
		t.Run(tt.subdir, func(t *testing.T) {
			cfg := testBrokerConfig(t)
			_, done := startBroker(t, cfg)
			waitStatus(t, cfg, "state=starting\njoinable=yes\n")
			waitStatus(t, cfg, "state=starting\njoinable=no\n")
			beforeJoin := time.Now()
			m := admitted(t, cfg, tt.subdir, tt.name)
			afterJoin := time.Now()
			if tt.extends {
				waitStatus(t, cfg, "state=starting\njoinable=yes\n")
			} else {
				waitStatus(t, cfg, "state=starting\njoinable=no\n")
			}
			wantStop(t, m)
			stopped := time.Now()
			if tt.extends && stopped.Before(beforeJoin.Add(cfg.startup)) {
				t.Error("service did not extend the startup window")
			}
			if !tt.extends && !stopped.Before(afterJoin.Add(cfg.startup)) {
				t.Error("daemon extended the startup window")
			}
			m.Close()
			waitBroker(t, done)
		})
	}
}

func TestBrokerAgentLifetime(t *testing.T) {
	cfg := testBrokerConfig(t)
	_, done := startBroker(t, cfg)
	observer := admitted(t, cfg, "daemon", "docker")
	first := admitted(t, cfg, "agents", "codex")
	time.Sleep(cfg.startup)
	waitStatus(t, cfg, "state=active\njoinable=yes\n")
	first.Close()
	waitStatus(t, cfg, "state=idle\njoinable=no\n")
	if got := controlReply(t, cfg, controlReady); got != "ok\n" {
		t.Errorf("idle ready = %q", got)
	}
	second := admitted(t, cfg, "agents", "claude")
	time.Sleep(cfg.idle)
	waitStatus(t, cfg, "state=active\njoinable=yes\n")
	second.Close()
	waitStatus(t, cfg, "state=idle\njoinable=no\n")
	time.Sleep(cfg.idle / 2)
	service := admitted(t, cfg, "services", "egress-proxy")
	joined := time.Now()
	wantStop(t, service)
	if time.Since(joined) >= cfg.idle {
		t.Error("service extended the idle window")
	}
	wantStop(t, observer)
	service.Close()
	observer.Close()
	waitBroker(t, done)
}

func TestBrokerControl(t *testing.T) {
	cfg := testBrokerConfig(t)
	_, done := startBroker(t, cfg)
	first := admitted(t, cfg, "agents", "codex")
	proxy := admitted(t, cfg, "services", "egress-proxy")
	second := admitted(t, cfg, "agents", "claude")
	daemon := admitted(t, cfg, "daemon", "docker")
	third := admitted(t, cfg, "agents", "codex")
	const names = "agents=codex claude codex\nservices=egress-proxy docker\n"
	if got := controlReply(t, cfg, controlStatus); got != "state=active\njoinable=yes\nremaining=0\n"+names {
		t.Errorf("active status = %q", got)
	}
	if got := controlReply(t, cfg, controlReady); got != "ok\n" {
		t.Errorf("active ready = %q", got)
	}
	if got := controlReply(t, cfg, "stop "); got != "" {
		t.Errorf("unknown command replied %q", got)
	}
	for range 2 {
		if got := controlReply(t, cfg, controlStop); got != "ok\n" {
			t.Errorf("stop = %q", got)
		}
	}
	if got := controlReply(t, cfg, controlStatus); got != "state=draining\njoinable=no\nremaining=0\n"+names {
		t.Errorf("draining status = %q", got)
	}
	if got := controlReply(t, cfg, controlReady); got != "draining\n" {
		t.Errorf("draining ready = %q", got)
	}
	for _, conn := range []net.Conn{first, second, third, proxy, daemon} {
		wantStop(t, conn)
		conn.Close()
	}
	waitBroker(t, done)
}

func TestBrokerCancel(t *testing.T) {
	cfg := testBrokerConfig(t)
	cancel, done := startBroker(t, cfg)
	agent := admitted(t, cfg, "agents", "claude")
	service := admitted(t, cfg, "services", "publish")
	// Incomplete requests must not hold shutdown open until the read deadline.
	for _, path := range []string{cfg.control, rolePath(cfg, "daemon")} {
		pending, err := net.DialTimeout("unix", path, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { pending.Close() })
	}
	cancel()
	waitBroker(t, done)
	wantEOF(t, agent)
	wantEOF(t, service)
	for _, path := range []string{cfg.control, rolePath(cfg, "agents"), rolePath(cfg, "services"), rolePath(cfg, "daemon")} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("canceled broker socket %s: stat returned %v", path, err)
		}
	}
}

func TestBrokerDrainLimit(t *testing.T) {
	cfg := testBrokerConfig(t)
	log, err := os.CreateTemp(cfg.dir, "stderr")
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stderr
	os.Stderr = log
	t.Cleanup(func() {
		os.Stderr = old
		log.Close()
	})
	_, done := startBroker(t, cfg)
	agent := admitted(t, cfg, "agents", "claude")
	before := time.Now()
	controlReply(t, cfg, controlStop)
	wantStop(t, agent)
	waitBroker(t, done)
	if time.Since(before) < cfg.drain {
		t.Error("broker exited before its drain limit")
	}
	wantEOF(t, agent)
	output, err := os.ReadFile(log.Name())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(output), "sandbox-lifecycle: did not stop in time: claude\n") {
		t.Errorf("missing timeout diagnostic in %q", output)
	}
}

func TestBrokerRefusals(t *testing.T) {
	cfg := testBrokerConfig(t)
	startBroker(t, cfg)
	admitted(t, cfg, "agents", "codex")
	for _, tt := range []struct{ subdir, wire string }{
		{"agents", "codex\n"},
		{"agents", strings.Repeat("x", maxJoinLine)},
		{"services", formatJoin("codex")},
		{"services", formatJoin("docker")},
		{"daemon", formatJoin("egress-proxy")},
	} {
		conn, reply := wireJoin(t, rolePath(cfg, tt.subdir), tt.wire)
		if reply != msgRefuse {
			t.Fatalf("join %q on %s = %q, want R", tt.wire, tt.subdir, reply)
		}
		wantEOF(t, conn)
	}
	for range 4 {
		admitted(t, cfg, "daemon", "docker")
	}
	full, reply := join(t, rolePath(cfg, "daemon"), "docker")
	if reply != msgRefuse {
		t.Fatalf("full pool = %q, want R", reply)
	}
	wantEOF(t, full)
	admitted(t, cfg, "services", "ssh-agent")
	controlReply(t, cfg, controlStop)
	for _, spec := range sockets {
		late, reply := join(t, rolePath(cfg, spec.subdir), spec.names[0])
		if reply != msgRefuse {
			t.Fatalf("join during drain on %s = %q, want R", spec.subdir, reply)
		}
		wantEOF(t, late)
	}
}

func TestBrokerUnexpectedByte(t *testing.T) {
	cfg := testBrokerConfig(t)
	startBroker(t, cfg)
	agent := admitted(t, cfg, "agents", "claude")
	if _, err := agent.Write([]byte("x")); err != nil {
		t.Fatal(err)
	}
	wantEOF(t, agent)
	waitStatus(t, cfg, "state=idle\njoinable=no\n")
	// The extra byte may arrive in the same read as the join line.
	buffered, reply := wireJoin(t, rolePath(cfg, "agents"), formatJoin("codex")+"x")
	if reply != msgAdmit {
		t.Fatalf("join with trailing byte = %q, want A", reply)
	}
	wantEOF(t, buffered)
	waitStatus(t, cfg, "agents=\n")
}

func TestBrokerRestart(t *testing.T) {
	cfg := testBrokerConfig(t)
	cancel, done := startBroker(t, cfg)
	cancel()
	waitBroker(t, done)

	paths := map[string]os.FileMode{cfg.control: 0o600}
	for _, spec := range sockets {
		paths[rolePath(cfg, spec.subdir)] = 0o666
	}
	for path := range paths {
		stale, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
		if err != nil {
			t.Fatal(err)
		}
		stale.SetUnlinkOnClose(false)
		stale.Close()
	}
	startBroker(t, cfg)
	for path, want := range paths {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode()&os.ModeSocket == 0 || info.Mode().Perm() != want {
			t.Errorf("restarted socket %s mode = %v, want socket %o", path, info.Mode(), want)
		}
	}
	admitted(t, cfg, "agents", "codex")
}

func TestBrokerListenFailure(t *testing.T) {
	cfg := testBrokerConfig(t)
	cfg.control = filepath.Join(cfg.dir, "missing", "control.sock")
	if err := serve(context.Background(), cfg); err == nil {
		t.Fatal("missing control directory: serve returned nil")
	}
	for _, spec := range sockets {
		if _, err := os.Stat(rolePath(cfg, spec.subdir)); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("partially initialized %s listener: stat returned %v", spec.subdir, err)
		}
	}
}
