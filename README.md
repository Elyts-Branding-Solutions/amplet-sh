# amplet

CLI tool. Run `amplet ping` → pong.

## Install on another machine (from this repo)

```bash
git clone https://github.com/Elyts-Branding-Solutions/amplet-sh.git
cd amplet-sh
make build
sudo make install
```

Then use:

```bash
amplet ping   # prints pong
amplet hello  # prints Hello from amplet 🚀
```

## Build for Linux from another OS

```bash
make build-linux
# Copy the `amplet` binary to the Linux machine, then:
# sudo install -m 755 amplet /usr/local/bin
```
