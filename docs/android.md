# Android port — feasibility notes

Investigated, then shelved. Recording what was found so the next attempt does
not have to rediscover it.

## The blocker

Building for Android means cross-compiling the Cython cores for `arm64-v8a`,
which in practice means python-for-android / Buildozer, which only runs on
Linux. On this machine that would be WSL2 — and WSL2 will not start:

```
Wsl/Service/CreateInstance/CreateVm/HCS/HCS_E_HYPERV_NOT_INSTALLED
```

The cause is firmware, not Windows:

| Check | Value |
| --- | --- |
| CPU | Intel Core i9-9900K |
| `VMMonitorModeExtensions` (CPU supports VT-x) | True |
| `VirtualizationFirmwareEnabled` (VT-x on in BIOS) | **False** |
| `HypervisorPresent` | False |

So VT-x is switched off in the BIOS/UEFI. Docker Desktop is not a way around
it — it runs on the same WSL2/Hyper-V layer.

To unblock the local route:

1. Reboot into BIOS/UEFI and enable *Intel Virtualization Technology (VT-x)*.
2. From an elevated PowerShell: `wsl --install --no-distribution`, then reboot.
3. `wsl -d Ubuntu` should then start, and the toolchain can be installed inside.

## What else was already in place

| Component | State |
| --- | --- |
| WSL2 Ubuntu (two distros) | installed, stopped |
| Android SDK, platform-tools, `adb` | present, `adb` works |
| Platform android-34, build-tools 34.0.0 | present |
| Android NDK | **missing** (~1 GB download) |
| JDK 17 | **missing** |
| A physical device | none connected |

## Route that needs no local virtualisation

GitHub Actions. `ubuntu-latest` runners have everything Buildozer needs, and
the repository is already on GitHub, so a workflow can produce an APK as a
build artifact. The cost is iteration speed: a Buildozer run takes 20-40
minutes, and the first several attempts at a new recipe usually fail.

## Work remaining after the build chain works

Getting an APK to build is the first of several steps, not the last:

* **A python-for-android recipe** that cross-compiles `snes/*.pyx` for arm64.
  p4a builds Cython code for its own components, so the path is known, but a
  recipe for a local package takes some fitting.
* **A touch frontend.** The current one is keyboard-only and unusable on a
  phone; an on-screen pad is needed. Bluetooth controllers, on the other
  hand, arrive through the same SDL GameController API that `snes/gamepad.py`
  already uses, so that part carries over unchanged.
* **Storage.** Android's scoped storage means picking a ROM through the
  Storage Access Framework rather than a path.
* **Performance, unmeasured.** The desktop build runs at ~110 fps on an
  i9-9900K. A phone's single-core throughput is roughly a third to a half of
  that, which puts the estimate at 35-55 fps — possibly under the 60 fps
  target. The scanline renderer in `snes/ppu.pyx` is the largest cost and
  would be the first thing to optimise. This cannot be settled without a
  device.
