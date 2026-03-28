---
name: egpu-thunderbolt-fix
description: Use when an NVIDIA eGPU connected via Thunderbolt is causing system freezes, nvidia-smi fails, dmesg shows "fallen off the bus", lspci shows Unknown header type 0x7f, or journalctl shows Unknown PCI header type 127 for TB bridge devices
---

# eGPU Thunderbolt PCIe Link Reset

## Overview

The Alpine Ridge TB3 bridge caches the PCIe link state on boot. If the eGPU wasn't ready during enumeration, the entire TB chain is stuck in a broken state — the GPU appears in `lspci` but can't respond to I/O. The NVIDIA driver fails to load, causing full system freezes.

## Hardware (this setup)

| Component | Detail |
|-----------|--------|
| GPU | NVIDIA RTX 5070 (GB205), PCI `10de:2f04` |
| Enclosure | Razer Core X (Thunderbolt 3) |
| Bridge | Alpine Ridge 2C (JHL6340), Intel Alder Lake-P |
| Driver | `nvidia-driver-590-open` (use latest ≥590) |
| TB UUID | `e9010000-0080-7518-a3db-e281d4357001` |
| PCI chain | `03:00.0` → `04:01.0` → `05:00.0` (GPU) + `05:00.1` (audio) |

## Diagnose First

```bash
# Broken link: shows 0x7f / "Unknown header type 7f"
lspci -v -s 05:00.0 | head -5

# Check journal from previous boot
journalctl -b -1 --priority=err | grep -i "nvidia\|pci header\|thunderbolt"

# Healthy: has "bus master" in Flags. Broken: missing or header type 7f
```

Key log signatures of broken link:
- `Unknown PCI header type '127'` (libvirtd or kernel)
- `Failed to allocate NvKmsKapiDevice` (nvidia_drm)
- `fallen off the bus` (NVRM)

## Fix: Automated

```bash
sudo ./egpu-fix.sh   # https://github.com/PenguinzTech/egpu-fix
```

## Fix: Manual (7 steps)

```bash
# 1. Remove chain — endpoints BEFORE bridges
sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:05:00.1/remove'
sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:05:00.0/remove'
sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:04:01.0/remove'
sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:03:00.0/remove'

# 2. Physically unplug TB cable → wait 3s → replug

# 3. Rescan + authorize
sudo sh -c 'echo 1 > /sys/bus/pci/rescan'
echo 1 | sudo tee /sys/bus/thunderbolt/devices/0-1/authorized
sleep 3
sudo sh -c 'echo 1 > /sys/bus/pci/rescan'

# 4. Load driver
sleep 3
sudo modprobe nvidia

# 5. Verify
nvidia-smi
```

## What Does NOT Work

| Approach | Why |
|----------|-----|
| Remove only `05:xx` + rescan | Bridge (03/04) retains stale state |
| Replug cable without removing PCI devices | Kernel uses cached enumeration |
| Power cycle Razer Core X only | Same stale bridge state |
| `boltctl authorize` alone | Reports authorized but link is dead |
| Repeated `modprobe nvidia` | Same "fallen off bus" every time |

## Driver / Kernel Notes

- RTX 5070 (Blackwell/GB205) requires driver ≥570; use latest ≥590 open
- After a kernel upgrade, check `linux-modules-nvidia-XXX-generic` is installed for the running kernel
- `nvidia-smi` reporting "No devices found" with driver installed = kernel module mismatch or broken TB link
- `rc` prefix in `dpkg -l` = package removed but config files remain (common after kernel upgrades)

## Bolt Config

The `iommu` bolt policy requires IOMMU validation before authorizing the device. If a udev rule
(`/etc/udev/rules.d/10-thunderbolt-power.rules`) fails to set `domain0/power/control`, the IOMMU
check stalls and the device stays at `authorized = 0` — even when powered on before boot. Symptoms:
`boltctl list` shows `policy: iommu` and `authflags: none`, sysfs `authorized` remains `0`.

Fix: re-enroll with `auto` policy so boltd authorizes immediately on connect without IOMMU gating:

```bash
sudo boltctl forget e9010000-0080-7518-a3db-e281d4357001
sudo boltctl enroll --policy auto e9010000-0080-7518-a3db-e281d4357001
```

**Diagnosis command:**
```bash
boltctl list   # look for "policy: iommu" + "authflags: none" = broken auto-auth
```

**Note on egpu-fix.sh authorization step:** After switching to `auto` policy, boltd authorizes
the device immediately on replug — before the script reaches the `authorized` sysfs write.
Writing `1` to an already-`1` TB `authorized` file returns `EINVAL`. This error is harmless;
the device is already authorized. The script exits there but the GPU is already functional —
verify with `nvidia-smi` before assuming failure.

## Prevention

**Power on the Razer Core X and connect TB cable BEFORE booting the laptop, AND ensure bolt
policy is `auto` (not `iommu`).** Both conditions are required for clean boot-time enumeration.
