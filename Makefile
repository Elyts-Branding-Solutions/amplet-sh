BINARY=amplet
SERVER_BINARY=amplet-server
INSTALL_DIR=/usr/local/bin

# Build agent for current OS
build:
	go build -o $(BINARY) .

# Build server for current OS
build-server:
	go build -o $(SERVER_BINARY) ./cmd/server

# Build both
build-all: build build-server

# Build agent Linux binary (e.g. from macOS for deployment)
build-linux:
	GOOS=linux GOARCH=amd64 go build -o $(BINARY)-linux-amd64 .

# Build server Linux binary
build-server-linux:
	GOOS=linux GOARCH=amd64 go build -o $(SERVER_BINARY)-linux-amd64 ./cmd/server

# Build for GitHub Release (named asset for curl install)
release-linux:
	GOOS=linux GOARCH=amd64 go build -o amplet-linux-amd64 .
	GOOS=linux GOARCH=arm64 go build -o amplet-linux-arm64 .

# Install agent to INSTALL_DIR
install: build
	install -m 755 $(BINARY) $(INSTALL_DIR)

# Install both binaries
install-all: build-all
	install -m 755 $(BINARY) $(INSTALL_DIR)
	install -m 755 $(SERVER_BINARY) $(INSTALL_DIR)

.PHONY: build build-server build-all build-linux build-server-linux release-linux install install-all
