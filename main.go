package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("amplet - CLI tool")
		fmt.Println("Usage: amplet <command>")
		return
	}

	switch os.Args[1] {
	case "ping":
		fmt.Println("pong")
	case "hello":
		fmt.Println("Hello from amplet 🚀")
	default:
		fmt.Println("Unknown command")
	}
}