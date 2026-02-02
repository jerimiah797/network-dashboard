# Network Diagnostic Dashboard

A real-time network monitoring dashboard built with Flask and Server-Sent Events (SSE). Monitors hosts via ping and port checks, and tracks Dynamic DNS synchronization.

## Features

- Real-time status updates via SSE (no page refresh needed)
- Ping and TCP port monitoring for configured hosts
- Dynamic DNS sync monitoring (compares external IP with DNS resolution)
- Dark theme UI

## Requirements

- Python 3
- Flask
- `dig` command (for DDNS checks)

On Debian/Ubuntu/Raspberry Pi OS, install `dig` with:

```bash
sudo apt install dnsutils
```

## Installation

```bash
# Create and activate virtual environment
python3 -m venv venv
source venv/bin/activate

# Install Python dependencies
pip install -r requirements.txt
```

## Usage

```bash
source venv/bin/activate
python app.py
```

The dashboard will be available at `http://localhost:5000`.

## Configuration

Edit the `HOSTS` dictionary in `app.py` to configure which hosts and ports to monitor. Each host can have multiple checks:

```python
"example": {
    "name": "Display Name",
    "ip": "192.168.1.100",
    "checks": [
        {"type": "ping"},
        {"type": "port", "port": 22, "label": "SSH"},
        {"type": "port", "port": 80, "label": "HTTP"},
    ],
},
```

To change the DDNS hostname, edit the `DDNS_HOSTNAME` variable.
