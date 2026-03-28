# eGPU Fix: RTX 5070 via Razer Core X over Thunderbolt 3

## Hardware Setup

| Component | Details |
|-----------|---------|
| GPU | NVIDIA GeForce RTX 5070 (GB205, PCI ID `10de:2f04`), MSI |
| Enclosure | Razer Core X (Thunderbolt 3) |
| Host Bridge | Intel Alder Lake-P TB4, Alpine Ridge 2C (JHL6340) |
| Driver | `nvidia-driver-590-open` (590.x), CUDA 13.x — use the latest available 590+ open driver |
| Kernel | 6.17.0+ (Ubuntu) |

> **Driver note:** Use the latest available open driver ≥ 590. The RTX 5070 (Blackwell/GB205)
> requires 570+ for basic support. Driver 590 open was introduced after the initial 580 setup
> and offers improved Blackwell support. Install with:
> ```bash
> sudo apt install nvidia-driver-590-open
> ```
> To check for newer drivers: `sudo ubuntu-drivers list`

## Quick Fix

```bash
sudo ./egpu-fix.sh
```

See [`egpu-fix.sh`](egpu-fix.sh) — runs the full 7-step reset automatically.

## Symptoms After Reboot

After a power reboot, the eGPU often fails to initialize properly:

```
$ nvidia-smi
NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.

$ sudo modprobe nvidia
modprobe: ERROR: could not insert 'nvidia': No such device

$ sudo dmesg | grep -i nvidia
NVRM: The NVIDIA GPU 0000:05:00.0 (PCI ID: 10de:2f04)
NVRM: fallen off the bus and is not responding to commands.
nvidia 0000:05:00.0: probe with driver nvidia failed with error -1
```

Running `lspci -v -s 05:00.0` will show `!!! Unknown header type 7f` indicating corrupted PCI config space. You may also see this in `journalctl`:

```
libvirtd: internal error: Unknown PCI header type '127' for device '0000:05:00.0'
[drm:nv_drm_dev_load [nvidia_drm]] *ERROR* [nvidia-drm] [GPU ID 0x00000500] Failed to allocate NvKmsKapiDevice
```

## Root Cause

The Alpine Ridge Thunderbolt 3 bridge at PCI bus `03:00.0` caches the PCIe link state from boot. If the eGPU enclosure wasn't fully powered and ready when the bridge first enumerated the bus, the link is established in a broken state. The GPU appears in `lspci` but cannot respond to memory-mapped I/O or config reads.

Simply removing the GPU from the PCI bus and rescanning does **not** fix this because the bridge devices on buses 03 and 04 retain the broken link state.

## Fix Procedure

### Quick Reference (Manual)

```bash
# Step 1: Remove entire Thunderbolt bridge chain (top-down)
sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:05:00.1/remove'
sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:05:00.0/remove'
sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:04:01.0/remove'
sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:03:00.0/remove'

# Step 2: Physically unplug Thunderbolt cable, wait 3 seconds, replug

# Step 3: Rescan PCI bus
sudo sh -c 'echo 1 > /sys/bus/pci/rescan'

# Step 4: Authorize Thunderbolt device
echo 1 | sudo tee /sys/bus/thunderbolt/devices/0-1/authorized

# Step 5: Rescan again after authorization
sleep 3
sudo sh -c 'echo 1 > /sys/bus/pci/rescan'

# Step 6: Load driver
sleep 3
sudo modprobe nvidia

# Step 7: Verify
nvidia-smi
```

### Step-by-Step Explanation

**Step 1 - Remove PCI devices:** Remove all four PCI devices in the Thunderbolt chain. Order matters - remove endpoints (bus 05) before bridges (buses 04, 03). This tears down the entire stale link.

- `05:00.1` - NVIDIA HD Audio (GPU audio output)
- `05:00.0` - NVIDIA GeForce RTX 5070 (VGA controller)
- `04:01.0` - Alpine Ridge downstream bridge
- `03:00.0` - Alpine Ridge upstream bridge

**Step 2 - Physical replug:** Unplug the Thunderbolt cable from the laptop, wait a few seconds, and replug. This forces the bridge hardware to renegotiate the PCIe link from scratch.

**Step 3 - PCI rescan:** The kernel re-enumerates the PCI bus and discovers the Thunderbolt bridge chain fresh.

**Step 4 - Thunderbolt authorization:** The Razer Core X requires explicit Thunderbolt authorization. The device UUID is `e9010000-0080-7518-a3db-e281d4357001`. You can also authorize via `boltctl`:

```bash
sudo boltctl authorize e9010000-0080-7518-a3db-e281d4357001
```

**Step 5 - Second rescan:** After TB authorization, rescan PCI again so the GPU endpoints on bus 05 are properly enumerated with a live link.

**Step 6 - Load driver:** With a clean PCIe link, `modprobe nvidia` will successfully probe the device.

**Step 7 - Verify:** `nvidia-smi` should show the RTX 5070 with 12GB VRAM.

## Diagnostic Commands

```bash
# Check if GPU is on PCI bus
lspci | grep -i nvidia

# Check PCI config space health (should NOT show "Unknown header type 7f")
lspci -v -s 05:00.0 | head -5

# Good output has "bus master" in Flags:
#   Flags: bus master, fast devsel, latency 0, IRQ 17
# Bad output is missing "bus master" or shows header type 7f

# Check Thunderbolt device status
boltctl list

# Check kernel messages for GPU errors
sudo dmesg | grep -i -E "nvidia|thunderbolt|05:00"

# Check if nvidia module is loaded
lsmod | grep nvidia

# Check previous boot for errors (survives reboot)
journalctl -b -1 --priority=err | grep -i "nvidia\|thunderbolt\|pci"
```

## What Does NOT Work

| Approach | Why It Fails |
|----------|-------------|
| Removing only bus 05 devices + rescan | Bridge (03/04) keeps stale link state |
| Replugging TB cable without removing PCI devices | Kernel uses cached (broken) enumeration |
| Power cycling Razer Core X without removing bridge chain | Same stale bridge state |
| `boltctl authorize` alone | Reports "already authorized" but link is dead |
| Repeated `modprobe nvidia` attempts | Same "fallen off bus" error every time |
| `sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:05:00.0/remove'` + rescan only | Bridge retains broken PCIe link negotiation |

## Bolt Configuration

The Razer Core X is enrolled in bolt with IOMMU policy:

```
$ boltctl list
 ● Razer Core X
   ├─ type:          peripheral
   ├─ name:          Core X
   ├─ vendor:        Razer
   ├─ uuid:          e9010000-0080-7518-a3db-e281d4357001
   ├─ generation:    Thunderbolt 3
   └─ stored:
      ├─ policy:     iommu
      └─ key:        no
```

If the `iommu` policy causes persistent issues, re-enroll with `auto`:

```bash
sudo boltctl forget e9010000-0080-7518-a3db-e281d4357001
sudo boltctl enroll --policy auto e9010000-0080-7518-a3db-e281d4357001
```

## Preventing the Issue

The most reliable approach is to ensure the Razer Core X is **powered on and connected before booting** the laptop. If booting with the eGPU disconnected or powered off, you will likely need the fix procedure above.

---

*Last verified: 2026-03-27 | Driver: nvidia-driver-590-open (590.x, latest) | Kernel: 6.17.0-19-generic*
