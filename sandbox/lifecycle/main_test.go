package main

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"
)

type testBroker struct {
	agent    string
	observer string
	ready    string
	stopped  chan struct{}
	done     chan error
}

func startBroker(t *testing.T, startup, idle, drain time.Duration) testBroker {
	t.Helper()
	dir, err := os.MkdirTemp("", "sandbox-lifecycle-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	b := testBroker{
		agent:    filepath.Join(dir, "agent"),
		observer: filepath.Join(dir, "observer"),
		ready:    filepath.Join(dir, "ready"),
		stopped:  make(chan struct{}),
		done:     make(chan error, 1),
	}
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		b.done <- serve(ctx, b.agent, b.observer, b.ready, startup, idle, drain, func() { close(b.stopped) })
		close(b.done)
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case err := <-b.done:
			if err != nil && !errors.Is(err, context.Canceled) {
				t.Error(err)
			}
		case <-time.After(5 * time.Second):
			t.Error("broker did not stop after cancel")
		}
	})

	readyBy := time.Now().Add(5 * time.Second)
	for time.Now().Before(readyBy) {
		if _, err := os.Stat(b.ready); err == nil {
			return b
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("broker did not become ready")
	return b
}

func connect(path string) (net.Conn, error) {
	conn, err := net.DialTimeout("unix", path, time.Second)
	if err != nil {
		return nil, err
	}
	if err := readMessage(conn, admitted, time.Second); err != nil {
		conn.Close()
		return nil, err
	}
	return conn, nil
}

func readMessage(conn net.Conn, byteWanted byte, within time.Duration) error {
	conn.SetReadDeadline(time.Now().Add(within))
	var buf [1]byte
	if _, err := io.ReadFull(conn, buf[:]); err != nil {
		return err
	}
	if buf[0] != byteWanted {
		return errors.New("unexpected lifecycle message")
	}
	return nil
}

func lease(t *testing.T, path string) net.Conn {
	t.Helper()
	conn, err := connect(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

func assertRunning(t *testing.T, observer net.Conn, within time.Duration) {
	t.Helper()
	var timeout net.Error
	if err := readMessage(observer, stopping, within); !errors.As(err, &timeout) || !timeout.Timeout() {
		t.Fatalf("observer got a message or disconnected while still active: %v", err)
	}
}

func assertStopped(t *testing.T, b testBroker) {
	t.Helper()
	select {
	case <-b.stopped:
	case <-time.After(5 * time.Second):
		t.Fatal("broker did not shut down")
	}
}

func TestLastAgentStartsShutdown(t *testing.T) {
	const idle = 60 * time.Millisecond
	b := startBroker(t, 5*time.Second, idle, 5*time.Second)
	observer := lease(t, b.observer)

	var group sync.WaitGroup
	leases := make([]net.Conn, 2)
	for i := range leases {
		group.Go(func() {
			lease, err := connect(b.agent)
			if err != nil {
				t.Error(err)
				return
			}
			leases[i] = lease
			t.Cleanup(func() { lease.Close() })
		})
	}
	group.Wait()
	if t.Failed() {
		return
	}
	leases[0].Close()
	assertRunning(t, observer, 2*idle)
	leases[1].Close()
	if err := readMessage(observer, stopping, 5*time.Second); err != nil {
		t.Fatal(err)
	}
	if conn, err := connect(b.agent); err == nil {
		conn.Close()
		t.Fatal("broker admitted an agent during drain")
	}
	select {
	case <-b.stopped:
		t.Fatal("broker stopped before its observer disconnected")
	default:
	}
	observer.Close()
	assertStopped(t, b)
}

func TestObserverCannotExtendLifetimeOrDrain(t *testing.T) {
	b := startBroker(t, 300*time.Millisecond, time.Second, 100*time.Millisecond)
	observer := lease(t, b.observer)
	untrusted := lease(t, b.observer)
	if _, err := untrusted.Write([]byte{admitted}); err != nil {
		t.Fatal(err)
	}
	if err := readMessage(observer, stopping, 2*time.Second); err != nil {
		t.Fatal(err)
	}
	assertStopped(t, b)
	var next [1]byte
	observer.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := observer.Read(next[:]); !errors.Is(err, io.EOF) {
		t.Fatalf("observer still connected after drain deadline: %v", err)
	}
}

func TestObserverWaitsForOwnerDuringShutdown(t *testing.T) {
	b := startBroker(t, 5*time.Second, 20*time.Millisecond, 5*time.Second)
	agent := lease(t, b.agent)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ready := b.ready + ".observer"
	signalled := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		done <- join(ctx, b.observer, ready, true, func() { close(signalled) })
	}()
	readyBy := time.Now().Add(time.Second)
	for {
		if _, err := os.Stat(ready); err == nil {
			break
		}
		if time.Now().After(readyBy) {
			t.Fatal("observer did not become ready")
		}
		time.Sleep(time.Millisecond)
	}
	agent.Close()
	select {
	case <-signalled:
	case <-time.After(time.Second):
		t.Fatal("observer did not signal owner")
	}
	select {
	case <-b.stopped:
		t.Fatal("observer disconnected before owner finished")
	default:
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("observer stayed alive after owner finished")
	}
	assertStopped(t, b)
}

func TestShutdownDeadlineSignalsOwnerThatIgnoresTerm(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	owner := exec.CommandContext(ctx, "sh", "-c", `
		trap '' TERM
		trap 'exit 17' USR1
		printf r
		while :; do sleep 0.1 & wait; done
	`)
	ready, err := owner.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := owner.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { owner.Wait() })
	var marker [1]byte
	if _, err := io.ReadFull(ready, marker[:]); err != nil {
		t.Fatal(err)
	}
	if err := owner.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	if err := enforceDeadline(ctx, owner.Process, 20*time.Millisecond); err != nil {
		t.Fatal(err)
	}
	var exit *exec.ExitError
	if err := owner.Wait(); !errors.As(err, &exit) || exit.ExitCode() != 17 {
		t.Fatalf("owner did not exit through its shutdown deadline trap: %v", err)
	}
}
