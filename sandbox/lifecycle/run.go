package main

import (
	"context"
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

// run joins the broker before starting argv and returns the wrapper exit code.
// It handles signals for the member's role. Tests cancel ctx to request a stop.
func run(ctx context.Context, cfg runConfig, m member, name string, argv []string) int {
	return 1
}
