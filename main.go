package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("amplet - hardware monitoring agent")
		fmt.Println("Usage: amplet <command>")
		fmt.Println("Commands: ping | run")
		return
	}

	switch os.Args[1] {
	case "ping":
		fmt.Println("pong..!")
	case "run":
		runAgent()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", os.Args[1])
		os.Exit(1)
	}
}
