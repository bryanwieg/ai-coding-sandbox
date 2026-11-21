package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"syscall"
	"time"
)

type runConfig struct {
	socket      string
	retry       time.Duration
	interval    time.Duration
	joinTimeout time.Duration
	rejoin      time.Duration
	hardExit    time.Duration
	signal      func(pid int, sig syscall.Signal) error
}

func defaultRunConfig() runConfig {
	return runConfig{
		socket:      clientSocket,
		retry:       admissionRetry,
		interval:    retryInterval,
		joinTimeout: joinTimeout,
		rejoin:      rejoinWindow,
		hardExit:    hardExitMargin,
		signal:      syscall.Kill,
	}
}

// An attempt has one deadline for dialing, writing the join and reading its reply.
func attemptJoin(ctx context.Context, cfg runConfig, name string) (net.Conn, byte) {
	attempt, cancel := context.WithTimeout(ctx, cfg.joinTimeout)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(attempt, "unix", cfg.socket)
	if err != nil {
		return nil, 0
	}
	closeOnCancel := context.AfterFunc(attempt, func() { conn.Close() })
	var reply [1]byte
	_, err = io.WriteString(conn, formatJoin(name))
	if err == nil {
		_, err = io.ReadFull(conn, reply[:])
	}
	if closeOnCancel() && err == nil && reply[0] == msgAdmit {
		return conn, msgAdmit
	}
	conn.Close()
	if reply[0] == msgRefuse {
		return nil, msgRefuse
	}
	return nil, 0
}

func joinBroker(ctx context.Context, cfg runConfig, name string, window time.Duration) (net.Conn, byte) {
	ctx, cancel := context.WithTimeout(ctx, window)
	defer cancel()
	for ctx.Err() == nil {
		conn, reply := attemptJoin(ctx, cfg, name)
		if reply != 0 {
			return conn, reply
		}
		select {
		case <-time.After(cfg.interval):
		case <-ctx.Done():
		}
	}
	return nil, 0
}

// watchBroker owns the admitted connection until the wrapper leaves. Even
// after S, keep it open so the broker can wait for the child to finish.
func watchBroker(ctx context.Context, cfg runConfig, name string, conn net.Conn, stop chan<- bool) {
	for {
		current := conn
		closeOnCancel := context.AfterFunc(ctx, func() { current.Close() })
		var msg [1]byte
		_, err := io.ReadFull(conn, msg[:])
		if err == nil && msg[0] == msgStop {
			stop <- false
			<-ctx.Done()
		}
		closeOnCancel()
		conn.Close()
		if ctx.Err() != nil {
			return
		}
		replacement, reply := joinBroker(ctx, cfg, name, cfg.rejoin)
		if reply != msgAdmit {
			if ctx.Err() == nil {
				stop <- reply != msgRefuse
			}
			return
		}
		conn = replacement
	}
}

type childExit struct {
	status syscall.WaitStatus
	err    error
}

// The kernel ties Pdeathsig to the spawning thread. Keep that thread alive
// until the main child is reaped, including when other PID 1 children exit.
func startAndReap(argv []string, service bool, started chan<- int, exited chan<- childExit) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	path, err := exec.LookPath(argv[0])
	if err != nil {
		fmt.Fprintln(os.Stderr, "sandbox-lifecycle:", err)
		started <- 0
		return
	}
	child, err := os.StartProcess(path, argv, &os.ProcAttr{
		Env:   os.Environ(),
		Files: []*os.File{os.Stdin, os.Stdout, os.Stderr},
		Sys:   &syscall.SysProcAttr{Setpgid: service, Pdeathsig: syscall.SIGKILL},
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "sandbox-lifecycle:", err)
		started <- 0
		return
	}
	defer child.Release()
	started <- child.Pid
	for {
		var status syscall.WaitStatus
		pid, err := syscall.Wait4(-1, &status, 0, nil)
		if err == syscall.EINTR {
			continue
		}
		if err != nil || pid == child.Pid {
			exited <- childExit{status, err}
			return
		}
	}
}

// run joins the broker before starting argv and returns the wrapper exit code.
// It handles signals for the member's role. Tests cancel ctx to request a stop.
func run(ctx context.Context, cfg runConfig, m member, name string, argv []string) int {
	return runWithStart(ctx, cfg, m, name, argv, startAndReap)
}

func runWithStart(ctx context.Context, cfg runConfig, m member, name string, argv []string,
	start func([]string, bool, chan<- int, chan<- childExit)) int {
	service := m.role == roleService
	stops := make(chan os.Signal, 8)
	otherSignals := make(chan os.Signal, 8)
	if service {
		signal.Notify(stops, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	} else {
		signal.Notify(stops, syscall.SIGTERM)
		signal.Notify(otherSignals, syscall.SIGHUP, syscall.SIGINT, syscall.SIGQUIT, syscall.SIGTSTP)
		defer signal.Stop(otherSignals)
	}
	defer signal.Stop(stops)

	watchCtx, leave := context.WithCancel(context.Background())
	admission := make(chan byte, 1)
	brokerStop := make(chan bool, 1)
	left := make(chan struct{})
	go func() {
		defer close(left)
		conn, reply := joinBroker(watchCtx, cfg, name, cfg.retry)
		admission <- reply
		if reply == msgAdmit {
			watchBroker(watchCtx, cfg, name, conn, brokerStop)
		}
	}()
	defer func() {
		leave()
		<-left
	}()

	// A stop during admission has no child to signal.
	beforeStart := 128 + int(syscall.SIGTERM)
	if service {
		beforeStart = 0
	}
	var reply byte
	select {
	case <-stops:
		return beforeStart
	case <-ctx.Done():
		return beforeStart
	case reply = <-admission:
	}
	// Both admission and a stop may already be queued.
	select {
	case <-stops:
		return beforeStart
	case <-ctx.Done():
		return beforeStart
	default:
	}
	if reply == msgRefuse {
		fmt.Fprintln(os.Stderr, "sandbox-lifecycle: the session group is stopping; start the session again.")
		return exitRefused
	}
	if reply != msgAdmit {
		fmt.Fprintf(os.Stderr, "sandbox-lifecycle: cannot reach the lifecycle broker at %s\n", cfg.socket)
		return 1
	}

	started := make(chan int)
	exited := make(chan childExit, 1)
	go start(argv, service, started, exited)
	var pid, killTarget, pendingTerms int
	var childSignals <-chan os.Signal
	var grace, hard <-chan time.Time
	var hardTimer *time.Timer
	requested, lost := false, false
	requestStop := func(forwardAgain bool) {
		if requested && !forwardAgain {
			return
		}
		if !requested {
			requested = true
			grace = time.After(m.grace)
			hardTimer = time.NewTimer(m.grace + cfg.hardExit)
		}
		if pid == 0 {
			pendingTerms++
		} else {
			cfg.signal(pid, syscall.SIGTERM)
		}
	}
	cancelled := ctx.Done()
	var result childExit
supervise:
	for {
		select {
		case pid = <-started:
			if pid == 0 {
				return 127
			}
			killTarget = pid
			if service {
				killTarget = -pid
			}
			childSignals = otherSignals
			for range pendingTerms {
				cfg.signal(pid, syscall.SIGTERM)
			}
			if hard != nil {
				// The grace expired before the child's PID was available.
				cfg.signal(killTarget, syscall.SIGKILL)
			}
		case result = <-exited:
			break supervise
		case <-cancelled:
			cancelled = nil
			requestStop(false)
		case lost = <-brokerStop:
			if lost {
				fmt.Fprintln(os.Stderr, "sandbox-lifecycle: lost the lifecycle broker")
			}
			requestStop(false)
		case <-stops:
			requestStop(!service)
		case sig := <-childSignals:
			if sig == syscall.SIGHUP {
				cfg.signal(pid, syscall.SIGHUP)
			}
		case <-grace:
			if pid != 0 {
				cfg.signal(killTarget, syscall.SIGKILL)
			}
			hard = hardTimer.C
		case <-hard:
			select {
			case result = <-exited:
				break supervise
			default:
				fmt.Fprintf(os.Stderr, "sandbox-lifecycle: %s did not stop in time; forcing exit.\n", name)
				return 1
			}
		}
	}
	if m.role == roleService {
		cfg.signal(killTarget, syscall.SIGKILL)
	}
	if result.err != nil {
		fmt.Fprintln(os.Stderr, "sandbox-lifecycle:", result.err)
		return 1
	}
	if lost {
		return 1
	}
	if result.status.Signaled() {
		if requested && m.role == roleService {
			return 0
		}
		return 128 + int(result.status.Signal())
	}
	return result.status.ExitStatus()
}
