#!/bin/bash
# Run this script on the Pi to set up auto-start for the Flask server

# Create the systemd service
sudo tee /etc/systemd/system/network-dashboard.service << 'EOF'
[Unit]
Description=Network Dashboard
After=network.target

[Service]
User=jham
WorkingDirectory=/home/jham/network-dashboard
ExecStart=/home/jham/network-dashboard/venv/bin/python app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable network-dashboard
sudo systemctl start network-dashboard

# Show status
sudo systemctl status network-dashboard
