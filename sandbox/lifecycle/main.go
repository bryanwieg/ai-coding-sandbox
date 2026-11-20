// sandbox-lifecycle coordinates the shared services of one Compose project.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"
)

const (
	agentSocket    = "/run/sandbox-agent-leases/control.sock"
	observerSocket = "/run/sandbox-sidecar-lifecycle/control.sock"
	admitted       = 'A'
	stopping       = 'S'
	admissionLimit = 2 * time.Second
	maxObservers   = 32
)

type broker struct {
	mu        sync.Mutex
	agents    map[*net.UnixConn]struct{}
	observers map[*net.UnixConn]struct{}
	closing   bool
	deadline  time.Time
	idle      time.Duration
	wake      chan struct{}
}

func (b *broker) changed() {
	select {
	case b.wake <- struct{}{}:
	default:
	}
}

func (b *broker) accept(listener *net.UnixListener, agent bool) error {
	for {
		conn, err := listener.AcceptUnix()
		if err != nil {
			return err
		}

		b.mu.Lock()
		if b.closing || (!agent && len(b.observers) >= maxObservers) {
			b.mu.Unlock()
			conn.Close()
			continue
		}
		conn.SetWriteDeadline(time.Now().Add(admissionLimit))
		_, err = conn.Write([]byte{admitted})
		if err != nil {
			b.mu.Unlock()
			conn.Close()
			continue
		}
		if agent {
			b.agents[conn] = struct{}{}
			b.deadline = time.Time{}
		} else {
			b.observers[conn] = struct{}{}
		}
		b.mu.Unlock()
		b.changed()

		go b.waitForClose(conn, agent)
	}
}

func (b *broker) waitForClose(conn *net.UnixConn, agent bool) {
	// Clients only receive messages. Any byte from a client ends its subscription.
	var unexpected [1]byte
	conn.Read(unexpected[:])
	conn.Close()

	b.mu.Lock()
	if agent {
		delete(b.agents, conn)
		if len(b.agents) == 0 {
			b.deadline = time.Now().Add(b.idle)
		}
	} else {
		delete(b.observers, conn)
	}
	b.mu.Unlock()
	b.changed()
}

func listen(path string) (*net.UnixListener, error) {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o666); err != nil {
		listener.Close()
		return nil, err
	}
	return listener, nil
}

func markReady(path string) error {
	return os.WriteFile(path, nil, 0o600)
}

func serve(ctx context.Context, agentsPath, observersPath, ready string, startup, idle, drain time.Duration, stopOwner func()) error {
	agents, err := listen(agentsPath)
	if err != nil {
		return err
	}
	defer agents.Close()
	observers, err := listen(observersPath)
	if err != nil {
		return err
	}
	defer observers.Close()

	b := &broker{
		agents:    make(map[*net.UnixConn]struct{}),
		observers: make(map[*net.UnixConn]struct{}),
		deadline:  time.Now().Add(startup),
		idle:      idle,
		wake:      make(chan struct{}, 1),
	}
	readyMarked := false
	defer func() {
		b.mu.Lock()
		b.closing = true
		for agent := range b.agents {
			agent.Close()
		}
		for observer := range b.observers {
			observer.Close()
		}
		b.mu.Unlock()
		if readyMarked {
			os.Remove(ready)
			if ctx.Err() == nil {
				stopOwner()
			}
		}
	}()
	listenerFailure := make(chan error, 2)
	go func() { listenerFailure <- b.accept(agents, true) }()
	go func() { listenerFailure <- b.accept(observers, false) }()
	if err := markReady(ready); err != nil {
		return err
	}
	readyMarked = true

	for {
		b.mu.Lock()
		deadline := b.deadline
		if !deadline.IsZero() && time.Until(deadline) <= 0 {
			b.closing = true
			b.mu.Unlock()
			break
		}
		b.mu.Unlock()

		var expires <-chan time.Time
		var timer *time.Timer
		if !deadline.IsZero() {
			timer = time.NewTimer(time.Until(deadline))
			expires = timer.C
		}
		var stopped error
		select {
		case <-ctx.Done():
			stopped = ctx.Err()
		case stopped = <-listenerFailure:
		case <-b.wake:
		case <-expires:
		}
		if timer != nil {
			timer.Stop()
		}
		if stopped != nil {
			return stopped
		}
	}

	// Keep the proxy up during its observers' cleanup, with admission closed.
	os.Remove(ready)
	agents.Close()
	observers.Close()
	b.drain(ctx, drain)
	return nil
}

func (b *broker) drain(ctx context.Context, duration time.Duration) {
	deadline := time.Now().Add(duration)
	timer := time.NewTimer(duration)
	defer timer.Stop()

	b.mu.Lock()
	observers := make([]*net.UnixConn, 0, len(b.observers))
	for observer := range b.observers {
		observers = append(observers, observer)
	}
	b.mu.Unlock()
	for _, observer := range observers {
		observer.SetWriteDeadline(deadline)
		observer.Write([]byte{stopping})
	}

	for {
		b.mu.Lock()
		remaining := len(b.observers)
		b.mu.Unlock()
		if remaining == 0 {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			return
		case <-b.wake:
		}
	}
}

func join(ctx context.Context, path, ready string, observer bool, stopOwner func()) error {
	dialer := net.Dialer{Timeout: admissionLimit}
	conn, err := dialer.DialContext(ctx, "unix", path)
	if err != nil {
		return err
	}
	defer conn.Close()

	conn.SetReadDeadline(time.Now().Add(admissionLimit))
	var message [1]byte
	if _, err := io.ReadFull(conn, message[:]); err != nil {
		return err
	}
	if message[0] != admitted {
		return fmt.Errorf("lifecycle broker refused admission")
	}
	conn.SetReadDeadline(time.Time{})
	if err := markReady(ready); err != nil {
		return err
	}
	defer os.Remove(ready)

	// Closing the connection interrupts the read when the owner exits.
	cancelRead := context.AfterFunc(ctx, func() { conn.Close() })
	defer cancelRead()
	_, err = io.ReadFull(conn, message[:])
	if ctx.Err() != nil {
		return nil
	}
	os.Remove(ready)
	stopOwner()
	if observer {
		<-ctx.Done()
		if err != nil || message[0] == stopping {
			return nil
		}
	}
	if err != nil {
		return fmt.Errorf("lost lifecycle broker: %w", err)
	}
	return fmt.Errorf("unexpected lifecycle broker message")
}

func run() error {
	if len(os.Args) != 4 {
		return fmt.Errorf("usage: sandbox-lifecycle serve|hold|observe OWNER_PID READY_FILE")
	}
	mode, ready := os.Args[1], os.Args[3]
	pid, err := strconv.Atoi(os.Args[2])
	if err != nil || pid <= 0 {
		return fmt.Errorf("invalid owner PID %q", os.Args[2])
	}
	owner, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	defer owner.Release()

	sigCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	ctx, cancel := context.WithCancel(sigCtx)
	defer cancel()
	go func() {
		ticker := time.NewTicker(200 * time.Millisecond)
		defer ticker.Stop()
		for {
			if owner.Signal(syscall.Signal(0)) != nil {
				cancel()
				return
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	stopOwner := func() {
		if ctx.Err() == nil {
			owner.Signal(syscall.SIGTERM)
		}
	}

	switch mode {
	case "serve":
		return serve(ctx, agentSocket, observerSocket, ready, 120*time.Second, 2*time.Second, 25*time.Second, stopOwner)
	case "hold":
		return join(ctx, agentSocket, ready, false, stopOwner)
	case "observe":
		return join(ctx, observerSocket, ready, true, stopOwner)
	default:
		return fmt.Errorf("unknown lifecycle mode %q", mode)
	}
}

func main() {
	if err := run(); err != nil && !errors.Is(err, context.Canceled) {
		fmt.Fprintln(os.Stderr, "sandbox-lifecycle:", err)
		os.Exit(1)
	}
}
