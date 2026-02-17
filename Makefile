BINARY=amplet
INSTALL_DIR=/usr/local/bin

# Build for current OS
build:
	go build -o $(BINARY) .

# Build Linux binary (e.g. from macOS for deployment)
build-linux:
	GOOS=linux GOARCH=amd64 go build -o $(BINARY) .

# Build for GitHub Release (named asset for curl install)
release-linux:
	GOOS=linux GOARCH=amd64 go build -o amplet-linux-amd64 .

# Install to INSTALL_DIR (run with sudo on Linux)
install: build
	install -m 755 $(BINARY) $(INSTALL_DIR)

# Install Linux binary (build then copy to target machine)
install-linux: build-linux
	@echo "Binary: ./$(BINARY)"
	@echo "Copy to Linux and run: sudo install -m 755 $(BINARY) $(INSTALL_DIR)"

.PHONY: build build-linux release-linux install install-linux
