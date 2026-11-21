package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	os.Exit(dispatch(os.Args[1:], os.Stdout, os.Stderr))
}

func dispatch(args []string, stdout, stderr io.Writer) int {
	if len(args) == 1 {
		switch args[0] {
		case "serve":
			ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
			defer cancel()
			if err := serve(ctx, defaultBrokerConfig()); err != nil {
				fmt.Fprintln(stderr, "sandbox-lifecycle:", err)
				return 1
			}
			return 0
		case controlReady, controlStatus, controlStop:
			reply, err := requestControl(controlSocket, args[0])
			if err != nil {
				fmt.Fprintln(stderr, "sandbox-lifecycle:", err)
				return 1
			}
			if args[0] == controlStatus {
				fmt.Fprint(stdout, reply)
				return 0
			}
			if reply == "ok\n" {
				return 0
			}
			return 1
		}
	}
	if len(args) >= 4 && args[0] == "run" && args[2] == "--" && args[3] != "" {
		if m, ok := members[args[1]]; ok {
			return run(context.Background(), defaultRunConfig(), m, m.name, args[3:])
		}
	}
	fmt.Fprintln(stderr, "sandbox-lifecycle: usage: sandbox-lifecycle serve | run NAME -- COMMAND [ARGS...] | ready | status | stop")
	return exitUsage
}
