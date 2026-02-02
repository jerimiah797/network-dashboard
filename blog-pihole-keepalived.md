# The Missing Piece for Redundant Pi-hole: Keepalived

*How I finally achieved true DNS failover after 30 years of messing with computers*

---

If you're running a Pi-hole on your home network, you've probably experienced the moment of dread: your Pi-hole goes down, and suddenly nothing works. No DNS means no internet—at least, not without manually changing settings on every device.

I've been tinkering with computers for 30 years. I've set up redundant storage, redundant power supplies, even redundant internet connections. But redundant DNS at home? That always felt like overkill—until I realized DNS is the single point of failure that takes down *everything*.

Today I finally solved it, and the answer was a tool I'd somehow never encountered: **keepalived**.

## The Problem with "Just Add Another Pi-hole"

The obvious solution to DNS redundancy is to run two Pi-holes. Most routers let you specify a primary and secondary DNS server. Problem solved, right?

Not quite.

Here's the dirty secret: most devices don't use secondary DNS the way you'd expect. They don't failover gracefully—they either query both simultaneously (doubling your query logs and potentially getting inconsistent results) or they wait an agonizingly long time before trying the backup. Some devices cache the primary DNS and never try the secondary at all.

What we really need is a **single IP address** that automatically moves to whichever Pi-hole is healthy. That's exactly what keepalived does.

## Enter Keepalived and VRRP

Keepalived implements VRRP (Virtual Router Redundancy Protocol)—the same protocol that enterprise networks use for router failover. It's been around forever, it's rock solid, and it's surprisingly easy to set up.

The concept is simple:
- Both Pi-holes have their own IP addresses (let's say .40 and .42)
- Keepalived manages a **Virtual IP** (VIP) that floats between them (let's say .41)
- Your router and all clients point to the VIP
- If the primary Pi-hole fails, the VIP moves to the backup in seconds

No client reconfiguration. No stale DNS caches. Just automatic failover.

## My Setup

| Host | Role | Real IP |
|------|------|---------|
| Proxmox LXC | Primary | 192.168.1.42 |
| Raspberry Pi 3 | Backup | 192.168.1.40 |
| **VIP** | Floating | **192.168.1.41** |

The Proxmox container is my primary—it has better resources and runs on enterprise hardware. The Raspberry Pi is the backup—it's small, cheap, and always on. If Proxmox needs maintenance or has issues, the Pi takes over.

## Setting It Up

### Step 1: Install Keepalived on Both Hosts

```bash
sudo apt update && sudo apt install -y keepalived
```

### Step 2: Create a Health Check Script

This is the key to making keepalived work with Pi-hole. We don't just want to failover when the *host* goes down—we want to failover when *Pi-hole* stops responding to DNS queries.

Create `/etc/keepalived/check_pihole.sh` on both hosts:

```bash
#!/bin/bash
dig @127.0.0.1 google.com +time=2 +tries=1 > /dev/null 2>&1
```

Make it executable:

```bash
sudo chmod +x /etc/keepalived/check_pihole.sh
```

This script exits 0 (success) if Pi-hole responds to a DNS query, and non-zero if it doesn't. Simple and effective.

**Why do we need a health check?** Keepalived already handles the obvious case—if the host goes down entirely, it stops sending VRRP heartbeats, and the backup takes over within a few seconds. That's built into the protocol.

But what about partial failures? The host is up, the network is fine, but Pi-hole has crashed or hung. Without the health check, keepalived would happily keep the VIP on a machine that can't answer DNS queries. The health check script catches these sneaky failures and triggers failover even when the host itself is healthy.

### Step 3: Configure the Primary (Higher Priority)

Create `/etc/keepalived/keepalived.conf` on your primary Pi-hole:

```
global_defs {
    router_id pihole_primary
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
        auth_pass your_secret_here
    }

    virtual_ipaddress {
        192.168.1.41/24
    }

    track_script {
        check_pihole
    }
}
```

### Step 4: Configure the Backup (Lower Priority)

Create the same file on your backup Pi-hole, with a few changes:

```
global_defs {
    router_id pihole_backup
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
        auth_pass your_secret_here
    }

    virtual_ipaddress {
        192.168.1.41/24
    }

    track_script {
        check_pihole
    }
}
```

### Step 5: Start It Up

```bash
sudo systemctl enable keepalived
sudo systemctl start keepalived
```

Check the status:

```bash
journalctl -u keepalived -f
```

You should see your primary enter `MASTER STATE` and your backup enter `BACKUP STATE`.

## The Priority Math (Important!)

This tripped me up at first. The `priority` setting determines which host gets the VIP, but the `weight` modifier changes the effective priority when the health check fails.

My setup:
- Primary: priority 150, weight -60 on failure → effective priority 90
- Backup: priority 100, no change on failure → stays at 100

When the primary is healthy: 150 > 100, primary wins.
When the primary fails: 90 < 100, backup wins.

**The gotcha:** If your weight doesn't drop the primary *below* the backup's priority, failover won't happen. I initially had weight -50, which dropped the primary to 100—a tie. And ties go to the incumbent. Bump it to -60 and failover worked perfectly.

## Testing Failover

The moment of truth. On your primary Pi-hole:

```bash
sudo systemctl stop pihole-FTL
```

Watch the logs on your backup:

```bash
journalctl -u keepalived -f
```

Within about 10-15 seconds, you should see:

```
Keepalived_vrrp: (PIHOLE_VIP) Entering MASTER STATE
```

Test that DNS still works:

```bash
dig @192.168.1.41 google.com
```

Now restart Pi-hole on the primary:

```bash
sudo systemctl start pihole-FTL
```

The VIP should automatically return to the primary. No manual intervention needed.

## Keeping Your Pi-holes in Sync

Failover is great, but it's only useful if both Pi-holes have the same configuration—blocklists, local DNS entries, etc.

Options for syncing:
- **Teleporter** (built-in): Manual export/import via the Pi-hole web UI
- **Gravity Sync**: Automated sync via rsync/SSH
- **Orbital Sync**: Docker-based, uses the Pi-hole API

I'm currently using Teleporter manually since my config doesn't change often. For more dynamic setups, automating the sync is worth the effort.

**Warning:** If you sync settings, double-check that DHCP doesn't get enabled on your backup. Two DHCP servers on one network is a bad time.

## Why This Matters

DNS is invisible when it works and catastrophic when it doesn't. With keepalived:

- Maintenance is painless—stop Pi-hole, do your work, start it again
- Hardware failures don't take down your network
- You can upgrade, experiment, and break things without fear

The setup took me about an hour, and I wish I'd done it years ago. If you're running Pi-hole (or any critical network service), keepalived is the missing piece you didn't know you needed.

---

*Have questions or improvements? I'd love to hear about your setup in the comments.*
