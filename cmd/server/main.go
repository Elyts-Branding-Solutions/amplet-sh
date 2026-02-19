package main

import (
	"fmt"
	"net/http"
	"os"

	"github.com/joho/godotenv"
)

func main() {
	godotenv.Load() // load .env if present; silently ignored if missing

	pool, err := openDB()
	if err != nil {
		fmt.Fprintf(os.Stderr, "db connect: %v\n", err)
		os.Exit(1)
	}
	defer pool.Close()

	if err := migrateDB(pool); err != nil {
		fmt.Fprintf(os.Stderr, "db migrate: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("database ready")

	mux := http.NewServeMux()
	mux.HandleFunc("/ws/agent", makeWSHandler(pool))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	addr := ":" + envOr("PORT", "8080")
	fmt.Printf("amplet server listening on %s\n", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		fmt.Fprintf(os.Stderr, "server: %v\n", err)
		os.Exit(1)
	}
}
