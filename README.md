# debian-airpods-setup

A simple script automating the forgetting, pairing, and connecting your AirPods on Debian/Ubuntu/Mint.

## Features

- Forget existing AirPods pairings
- Ensure `ControllerMode = bredr` in Bluetooth config (with backup)
- Restart Bluetooth (SystemD or SysV)
- Interactive scan prompt

## Installation

```bash
# Clone the repo
git clone https://github.com/KeejayK/debian-airpods-setup.git
cd airpods-connector

# Mark it executable
chmod +x connect-airpods.sh

# Move into PATH
sudo mv connect-airpods.sh /usr/local/bin/
```

## Usage

```bash
# Default: Forget, scan, pair and connect
sudo connect-airpods.sh

# Enable verbose debugging
connect-airpods.sh --verbose
```

## Troubleshooting

- bluetoothctl missing: Install bluez/bluez-utils.

- Scan fails: Ensure your AirPods are in pairing mode (LED blinking).

## Credits

Manual pairing instructions (ControllerMode, scanning steps, etc.) were adapted from [aidos-dev’s GitHub Gist](https://gist.github.com/aidos-dev/b49078c1d8c6bb1621e4ac199d18213b).
