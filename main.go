package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("amplet - CLI tool")
		fmt.Println("Usage: amplet <command>")
		return
	}

	switch os.Args[1] {
	case "ping":
		fmt.Println("pong.")
	case "hello":
		fmt.Println("Hello from amplet 🚀")
	case "run":
		runAgent()
	default:
		fmt.Println("Unknown command")
	}
}

// runAgent runs the amplet agent as a long-lived daemon (used by systemd).
func runAgent() {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)

	for {
		select {
		case <-sig:
			return
		case <-ticker.C:
			// Periodic work (e.g. heartbeat to API) can go here
			_ = ticker
		}
	}
}