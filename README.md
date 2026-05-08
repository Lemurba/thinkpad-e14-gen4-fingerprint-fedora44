# FPC 10a5:9800 fingerprint reader on Fedora (KDE/GNOME)

> [!WARNING]
> **Only run the commands or the install script below if you fully understand
> exactly what they do.**
>
> Both the manual procedure in this README **and** the `install.sh` helper
> replace system files under `/usr/lib64` (`libfprint-2.so.2.0.0`) with a
> third-party binary distributed by Lenovo, install a proprietary closed-source
> library (`libfpcbep.so`), modify SELinux contexts, edit PAM configuration via
> `authselect`, and lock a Fedora package version in `dnf`.
>
> Running these steps without understanding them can break authentication on
> your system, prevent you from logging in, or interfere with future updates.
>
> Read every command and the entire `install.sh` first. Verify the integrity
> of the Lenovo download yourself. **Use at your own risk.**

Guide to enable the **FPC Sensor Controller** fingerprint reader (USB ID `10a5:9800`) on Fedora using the official Linux driver bundle published by Lenovo. Tested on **Fedora 44 (KDE)** with sensor firmware `27.26.23.33` and driver `27.26.23.39`.

## Two ways to install

You can pick one:

- **[Approach A — automated](#approach-a--automated-installsh)**: download `install.sh`, inspect it, and run it. Fastest, includes uninstall and status commands. Recommended once you trust the script.
- **[Approach B — manual, step by step](#approach-b--manual-step-by-step)**: run each command yourself and read what each one does. More transparent and educational.

Both approaches yield the same result. Use **only one** of them.

## Compatible models

Lenovo laptops shipping this sensor include, but are not limited to:

- ThinkPad E14 Gen 4 (21E3/21E4)
- ThinkPad E15 Gen 4
- ThinkPad E16 Gen 1
- IdeaPad / IdeaBook models with the same FPC sensor

Confirm with:

```bash
lsusb | grep -i 10a5:9800
# Bus 003 Device 002: ID 10a5:9800 FPC FPC Sensor Controller L:0002 FW:27.26.23.33
```

If the device shows up, this guide applies.

## Why this procedure is needed

Fedora's stock `libfprint` package **does not include** support for this sensor — it relies on a proprietary algorithm library (`libfpcbep.so`) and a patched `libfprint-2.so` that Lenovo only distributes as a `.zip` for Ubuntu. This guide adapts that bundle to Fedora.

## Prerequisites

```bash
sudo dnf install -y fprintd fprintd-pam unzip
```

## Approach A — automated (`install.sh`)

The repository ships an `install.sh` helper that performs every step in
**Approach B** automatically and adds an `uninstall` and `status` command.

1. Download the script (do **not** pipe straight to `bash` — read it first):

   ```bash
   curl -LO https://raw.githubusercontent.com/Lemurba/thinkpad-e14-gen4-fingerprint-fedora44/main/install.sh
   ```

   Or, if you prefer to clone the whole repo:

   ```bash
   git clone https://github.com/Lemurba/thinkpad-e14-gen4-fingerprint-fedora44.git
   cd thinkpad-e14-gen4-fingerprint-fedora44
   ```

2. **Read it** — open `install.sh` in a text editor and confirm what it does:

   ```bash
   less install.sh
   ```

3. Make it executable:

   ```bash
   chmod +x install.sh
   ```

4. Run it as root:

   ```bash
   sudo ./install.sh
   ```

   The script prompts for confirmation if the FPC sensor is not detected and
   prints what it is about to do at each step.

### Other commands

```bash
sudo ./install.sh status        # show what is installed and what is not
sudo ./install.sh uninstall     # revert all changes (restore backup, remove blob, disable PAM, unlock dnf)
./install.sh --help             # full list of flags (--no-pam, --no-lock, --workdir, --keep-workdir)
```

After the script reports success, jump straight to **[Enroll a
fingerprint](#enroll-a-fingerprint)** below.

## Approach B — manual, step by step

Read each command before running it.

### Step B1 — Download and extract the official Lenovo driver

```bash
mkdir -p ~/fpc-driver && cd ~/fpc-driver
curl -LO https://download.lenovo.com/pccbbs/mobiles/r1slm02w.zip
unzip r1slm02w.zip
```

Official support page (in case the link changes):
<https://pcsupport.lenovo.com/us/en/products/laptops-and-netbooks/thinkpad-edge-laptops/thinkpad-e14-gen-4-type-21e3-21e4/downloads/driver-list/component?name=leitor%20biom%C3%A9trico&id=A4F7592E-3C73-4CCF-ABB9-09549219DFC8>

The archive expands into two folders:

- `FPC_driver_linux_27.26.23.39/install_fpc/` — contains `libfpcbep.so`
- `FPC_driver_linux_libfprint/install_libfprint/` — contains `libfprint-2.so.2.0.0`

### Step B2 — Install the binaries on Fedora

The Lenovo bundle targets Ubuntu (`/usr/lib/x86_64-linux-gnu/`). On Fedora the libraries belong in `/usr/lib64/`:

```bash
cd ~/fpc-driver

# Back up the current libfprint (for rollback)
sudo cp -v /usr/lib64/libfprint-2.so.2.0.0 /usr/lib64/libfprint-2.so.2.0.0.bak

# Replace libfprint with Lenovo's version (FPC driver baked in)
sudo install -m 0755 \
  FPC_driver_linux_libfprint/install_libfprint/usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0 \
  /usr/lib64/libfprint-2.so.2.0.0

# Install the proprietary algorithm library
sudo install -m 0755 \
  FPC_driver_linux_27.26.23.39/install_fpc/libfpcbep.so \
  /usr/lib64/libfpcbep.so
```

### Step B3 — SELinux, udev and fprintd

```bash
sudo restorecon -Rv /usr/lib64/libfprint-2.so.2.0.0 /usr/lib64/libfpcbep.so
sudo udevadm control --reload-rules
sudo udevadm trigger
sudo systemctl restart fprintd
```

> The udev rule `/usr/lib/udev/rules.d/60-libfprint-2-device-fpc.rules` ships with Fedora 44's `libfprint` package and already covers `10a5:9800` — you do not need to copy the rule from the Lenovo bundle.

Verify:

```bash
fprintd-list "$USER"
# Expected: "found 1 devices  Device at /net/reactivated/Fprint/Device/0"
```

If you still get "No devices available", reboot once.

## Enroll a fingerprint

> _Both approaches converge here._

```bash
fprintd-enroll
```

Touch the sensor as many times as requested (typically 5). Repeat per finger:

```bash
fprintd-enroll -f right-thumb
fprintd-enroll -f left-index-finger
```

List enrolled fingers:

```bash
fprintd-list "$USER"
```

## Enable fingerprint authentication (sudo, login, lock screen)

> _Skip this section if you used Approach A — `install.sh` already does it
> unless you passed `--no-pam`._

Fedora manages PAM through `authselect`:

```bash
sudo authselect enable-feature with-fingerprint
sudo authselect apply-changes
```

Test:

```bash
sudo -k && sudo true   # should ask for the fingerprint
```

On KDE Plasma the GUI lives at **System Settings → Users → Configure fingerprint** (or `kcmshell6 kcm_users`). On GNOME, **Settings → Users**.

## Prevent `dnf upgrade` from overwriting libfprint (recommended)

> _Skip this section if you used Approach A — `install.sh` already does it
> unless you passed `--no-lock`._

Whenever Fedora updates the `libfprint` package, the official `libfprint-2.so.2.0.0` (without FPC support) is restored and the fingerprint stops working. To lock the version:

```bash
sudo dnf install -y python3-dnf-plugin-versionlock
sudo dnf versionlock add libfprint
```

List locks:

```bash
sudo dnf versionlock list
```

To unlock later (e.g. to reapply after a major update):

```bash
sudo dnf versionlock delete libfprint
```

Simpler alternative (no plugin) — add to `/etc/dnf/dnf.conf`:

```
excludepkgs=libfprint
```

## Rollback

If you used **Approach A**, simply run:

```bash
sudo ./install.sh uninstall
```

If you used **Approach B**, undo manually:

```bash
sudo cp -v /usr/lib64/libfprint-2.so.2.0.0.bak /usr/lib64/libfprint-2.so.2.0.0
sudo rm -f /usr/lib64/libfpcbep.so
sudo systemctl restart fprintd
```

Or, if no backup is available:

```bash
sudo dnf reinstall libfprint
sudo rm -f /usr/lib64/libfpcbep.so
sudo systemctl restart fprintd
```

## Notes

- This procedure replaces `/usr/lib64/libfprint-2.so.2.0.0` with an FPC/Lenovo build. The companion files (`libfprint-2.so`, `libfprint-2.so.2`) remain as symlinks to it.
- Lenovo's `libfprint-2.so.2.0.0` is ABI-compatible with Fedora 44's glib/gusb/libgudev (all `NEEDED` libraries resolve in `/lib64`).
- Source for the patched `libfprint` (LGPL-2.1): <https://github.com/fingerprint-cards/libfprint/commit/ad1933814a775c11f9581507910bae525c67ff2a>
- `libfpcbep.so` is a proprietary, closed-source library distributed only as a binary by FPC/Lenovo.

## References

- Lenovo official driver (zip): <https://download.lenovo.com/pccbbs/mobiles/r1slm02w.zip>
- ThinkPad E14 Gen 4 support page — Biometric Reader: <https://pcsupport.lenovo.com/us/en/products/laptops-and-netbooks/thinkpad-edge-laptops/thinkpad-e14-gen-4-type-21e3-21e4/downloads/driver-list/component?name=leitor%20biom%C3%A9trico&id=A4F7592E-3C73-4CCF-ABB9-09549219DFC8>
- Upstream `libfprint`: <https://fprint.freedesktop.org/>
- `authselect` documentation: <https://github.com/authselect/authselect>

## Licenses

- Lenovo's `libfprint-2.so`: LGPL-2.1 (see `LICENCE-LGPL2.1.txt` inside the zip)
- `libfpcbep.so`: proprietary, redistribution authorized by Lenovo via the official support page
- This guide: public domain
