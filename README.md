# KernelSU-Next kernels for GrapheneOS

## Warning

- These are **unofficial** builds. They are not affiliated with or endorsed by GrapheneOS or KernelSU-Next.
- Flashing a kernel can **brick your device**, cause data loss, or make it unbootable. You do it **at your own risk**.
- The authors take **no responsibility** for any damage, data loss, or other consequences.
- KernelSU weakens the device security model and may break GrapheneOS hardening, verified boot, and Play Integrity / attestation.
- Unlocking the bootloader **wipes all data** and voids the warranty.
- Back up your data and make sure you can restore the stock images before flashing.

## Supported devices

| Device          | Model    |
| --------------- | -------- |
| Pixel 7 / 7 Pro | `pantah` |
| Pixel 7a        | `lynx`   |
| Pixel 8 / 8 Pro | `shusky` |
| Pixel 8a        | `akita`  |

## Builds

Each run publishes an artifact (`ksu-<version>-<target>-<run>`) containing:

- `boot.img`
- `dtbo.img`
- `vendor_kernel_boot.img`
- `system_dlkm.img`
- `vendor_dlkm.img`
- `install.sh`

## Installation

Requirements: unlocked bootloader, `adb` and `fastboot` installed.

1. Download and extract the artifact zip for your device.
2. Boot into the bootloader:

   ```sh
   adb reboot bootloader
   ```

3. Flash:

   ```sh
   ./install.sh
   ```

   On Windows, or to flash manually:

   ```sh
   fastboot oem disable-verification
   fastboot flash boot boot.img
   fastboot flash dtbo dtbo.img
   fastboot flash vendor_kernel_boot vendor_kernel_boot.img
   fastboot reboot fastboot
   fastboot flash system_dlkm system_dlkm.img
   fastboot flash vendor_dlkm vendor_dlkm.img
   ```

4. Reboot:

   ```sh
   fastboot reboot
   ```

5. Install the KernelSU-Next manager app and verify root.

To restore the stock kernel, flash the matching GrapheneOS factory image or the original kernel images.
