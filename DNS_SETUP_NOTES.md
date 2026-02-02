# Pi-hole HA Setup with Keepalived

## Overview

Two Pi-hole instances with automatic failover using keepalived (VRRP).

| Host | Role | Real IP | Notes |
|------|------|---------|-------|
| Proxmox LXC | Primary | 192.168.1.42 | DHCP server enabled |
| Raspberry Pi 3 | Backup | 192.168.1.40 | DHCP disabled, query logging off |
| **VIP** | Floating | **192.168.1.41** | Managed by keepalived |

Clients should use **192.168.1.41** for DNS.

## How It Works

- Keepalived runs on both hosts, managing VIP 192.168.1.41
- Health check script tests if Pi-hole DNS is responding every 5 seconds
- If primary fails health check, VIP moves to backup within ~10 seconds
- When primary recovers, it takes VIP back (preemption)

### Priority Math

- Proxmox: priority 150, weight -60 on failure → effective 90
- RPi: priority 100 (always)
- Higher priority wins; Proxmox wins when healthy, RPi wins when Proxmox fails

## Configuration Files

### Health Check Script (both hosts)

`/etc/keepalived/check_pihole.sh`:
```bash
#!/bin/bash
dig @127.0.0.1 google.com +time=2 +tries=1 > /dev/null 2>&1
```

### Proxmox Keepalived Config

`/etc/keepalived/keepalived.conf`:
```
global_defs {
    router_id pihole_proxmox
    script_user root
    enable_script_security
}

vrrp_script check_pihole {
    script "/etc/keepalived/check_pihole.sh"
    interval 5
    weight -60
    fall 2
    rise 2
}

vrrp_instance PIHOLE_VIP {
    state MASTER
    interface eth0
    virtual_router_id 41
    priority 150
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass pihole41
    }

    virtual_ipaddress {
        192.168.1.41/24
    }

    track_script {
        check_pihole
    }
}
```

### RPi Keepalived Config

`/etc/keepalived/keepalived.conf`:
```
global_defs {
    router_id pihole_rpi
    script_user root
    enable_script_security
}

vrrp_script check_pihole {
    script "/etc/keepalived/check_pihole.sh"
    interval 5
    weight -50
    fall 2
    rise 2
}

vrrp_instance PIHOLE_VIP {
    state BACKUP
    interface eth0
    virtual_router_id 41
    priority 100
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass pihole41
    }

    virtual_ipaddress {
        192.168.1.41/24
    }

    track_script {
        check_pihole
    }
}
```

## RPi Network Auto-Switching

The RPi is configured to prefer Ethernet over WiFi:

- Ethernet priority: 100
- WiFi priority: 10
- When Ethernet is plugged in, WiFi radio is disabled automatically
- When Ethernet is unplugged, WiFi re-enables

Dispatcher script at `/etc/NetworkManager/dispatcher.d/99-wired-over-wifi`.

**Note:** Keepalived is configured for `eth0`. If running on WiFi, keepalived won't work properly.

## Useful Commands

```bash
# Check VRRP state
journalctl -u keepalived -f

# Check which host has the VIP
ip addr show | grep 192.168.1.41

# Test failover (on Proxmox)
systemctl stop pihole-FTL   # VIP should move to RPi
systemctl start pihole-FTL  # VIP should return

# Test DNS through VIP
dig @192.168.1.41 google.com

# Restart keepalived
systemctl restart keepalived
```

## Pi-hole Sync

Currently manual via Teleporter (Settings → Teleporter → Export/Import).

Future options:
- Orbital Sync (if/when v6 API support is added)
- Scripted Teleporter export/import via API
- inotifywait on config files to trigger sync

## Important Notes

- Only Proxmox Pi-hole runs DHCP - RPi DHCP is **disabled**
- RPi has query logging disabled to reduce SD card writes
- Both Pi-holes should have matching blocklists and local DNS entries
- After syncing via Teleporter, verify DHCP is still disabled on RPi
