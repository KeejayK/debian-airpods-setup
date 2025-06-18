# debian-airpods-setup

A simple script automating the forgetting, pairing, and connecting your AirPods on Debian/Ubuntu/Mint.

## Features

- Forget existing AirPods pairings
- Ensure `ControllerMode = bredr` in Bluetooth config (with backup)
- Restart Bluetooth (SystemD or SysV)
- Interactive scan prompt
- Configurable device name & timeout
- `--remove-only` mode
- Colorized, numbered progress messages

## Installation

```bash
# Clone the repo
git clone https://github.com/KeejayK/debian-airpods-setup.git
cd airpods-connector

# Install script
./install.sh
```

## Usage

```bash
# Show help
connect-airpods.sh --help

# Default: forget, scan, pair & connect
connect-airpods.sh

# Forget only, then exit
connect-airpods.sh --remove-only

# Custom device name & timeout
connect-airpods.sh --name "Keejay's Airpods" --timeout 15

# Enable verbose logging
connect-airpods.sh --verbose
```

## Troubleshooting

- bluetoothctl missing: Install bluez/bluez-utils.

- Scan fails: Ensure your AirPods are in pairing mode (LED blinking).

- Permission errors: You may need to run with sudo for config edits and service restarts.
