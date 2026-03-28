# egpu-fix

Fix script for NVIDIA eGPU (Razer Core X / RTX 5070) Thunderbolt 3 broken PCIe link state on Ubuntu.

## The Problem

After rebooting without the eGPU powered on first, the Alpine Ridge TB3 bridge caches a broken PCIe link state. The GPU appears in `lspci` but responds with `Unknown header type 0x7f` — it has "fallen off the bus" and the NVIDIA driver fails to load, causing system freezes.

## Quick Start

```bash
sudo ./egpu-fix.sh
```

## Hardware

| Component | Details |
|-----------|---------|
| GPU | NVIDIA GeForce RTX 5070 (GB205) |
| Enclosure | Razer Core X (Thunderbolt 3) |
| Host | Intel Alder Lake-P, Alpine Ridge 2C (JHL6340) |
| OS | Ubuntu, kernel 6.17.0+ |
| Driver | nvidia-driver-590-open (latest 590+) |

## Files

- [`egpu-fix.sh`](egpu-fix.sh) — Automated 7-step reset script
- [`EGPU_FIX.md`](EGPU_FIX.md) — Full documentation: root cause, manual steps, diagnostics, what doesn't work

## Prevention

Power on the Razer Core X and connect the Thunderbolt cable **before booting** the laptop.
