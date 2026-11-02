# Fedora 46+ / Rawhide: isolated Lenovo FPC driver method

This is a separate, experimental alternative to the Fedora 44 system-library replacement procedure in the repository README. It was tested on a Lenovo ThinkPad E16 Gen 1 with an FPC sensor enumerating as USB ID `10a5:9800`, running Fedora 46 Rawhide, KDE Plasma 6 and SDDM.

**Do not combine this method with the system-library replacement steps in the main README. Choose one method.** This method keeps Lenovo's modified libraries under `/opt/fpc-test` and configures only the `fprintd` systemd service to load them. Fedora's packaged `/usr/lib64/libfprint-2.so.2` remains untouched, and no `dnf versionlock` is needed for `libfprint`.

## Compatibility: what the USB ID does and does not tell you

The USB ID `10a5:9800` identifies this FPC sensor controller; it is a useful hardware check, **not a guarantee that every Lenovo laptop or generation is compatible**. Compatibility also depends on the actual sensor, firmware, Lenovo library build, Fedora ABI/dependencies, udev rules and authentication stack.

The Lenovo support listing for the driver archive names ThinkPad E14 Gen 4 and E15 Gen 4. This separate Fedora 46/Rawhide procedure was additionally tested on a ThinkPad E16 Gen 1. Other ThinkPad, IdeaPad and Lenovo models should be treated as unverified until the same sensor and driver combination is confirmed.

Check the actual device rather than relying on the laptop family name:

```bash
lsusb -d 10a5:9800
```

A matching result confirms that the USB device enumerates; it does not by itself prove the Lenovo libraries will work on that system.

## Tested configuration

- ThinkPad E16 Gen 1
- FPC USB sensor `10a5:9800` (firmware `27.26.23.31` on the test system)
- Fedora 46 Rawhide, KDE Plasma 6, SDDM
- Lenovo archive `r1slm02w.zip`, driver version `27.26.23.39`

## 1. Install prerequisites and obtain Lenovo's archive

```bash
sudo dnf install fprintd fprintd-pam unzip

mkdir -p ~/fpc-driver
cd ~/fpc-driver
curl -fLO https://download.lenovo.com/pccbbs/mobiles/r1slm02w.zip
sha256sum r1slm02w.zip
unzip r1slm02w.zip
```

Record the downloaded archive's checksum for your own verification and compare it with a checksum from a trusted, independent source if Lenovo provides one:

```bash
sha256sum r1slm02w.zip
```

Lenovo support listing: <https://support.lenovo.com/us/en/downloads/ds563477-fpc-fingerprint-driver-for-ubuntu-2004-ubuntu-2204-thinkpad-e14-gen-4-e15-gen-4>

Do not run Lenovo's Ubuntu installation scripts on Fedora.

## 2. Install the libraries under `/opt/fpc-test`

From the directory containing the extracted archive:

```bash
sudo install -d -m 0755 /opt/fpc-test

sudo install -m 0755 \
  FPC_driver_linux_libfprint/install_libfprint/usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0 \
  /opt/fpc-test/libfprint-2.so.2.0.0

sudo install -m 0755 \
  FPC_driver_linux_27.26.23.39/install_fpc/libfpcbep.so \
  /opt/fpc-test/libfpcbep.so

sudo ln -sfn libfprint-2.so.2.0.0 /opt/fpc-test/libfprint-2.so.2
sudo restorecon -Rv /opt/fpc-test
```

Check the libraries and dependencies:

```bash
ls -lZ /opt/fpc-test
ldd /opt/fpc-test/libfprint-2.so.2.0.0
```

All required dependencies should resolve. The Lenovo driver loads `libfpcbep.so` dynamically.

## 3. Install Lenovo's udev rule

```bash
sudo install -m 0644 \
  FPC_driver_linux_libfprint/install_libfprint/lib/udev/rules.d/60-libfprint-2-device-fpc.rules \
  /etc/udev/rules.d/60-libfprint-2-device-fpc.rules

sudo restorecon -v /etc/udev/rules.d/60-libfprint-2-device-fpc.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=usb
```

## 4. Configure only `fprintd` to load the Lenovo libraries

Create a systemd drop-in:

```bash
sudo install -d -m 0755 /etc/systemd/system/fprintd.service.d

sudo tee /etc/systemd/system/fprintd.service.d/90-fpc-test.conf >/dev/null <<'EOF'
[Service]
Environment="LD_LIBRARY_PATH=/opt/fpc-test"
EOF
```

Reload systemd and restart the daemon:

```bash
sudo systemctl daemon-reload
sudo systemctl restart fprintd
systemctl show fprintd -p Environment
```

The output should include `LD_LIBRARY_PATH=/opt/fpc-test`. `fprintd` may be D-Bus activated and stop when idle; an inactive state between requests is not necessarily a failure.

## 5. Enroll and verify as the desktop user

Run enrollment as the normal account that will use the fingerprint, **not with `sudo`**:

```bash
fprintd-enroll -f right-index-finger
fprintd-list "$USER"
fprintd-verify
```

Enrollments are per Linux account. Enrolling root does not enroll the desktop user.

## 6. Enable fingerprint authentication

Inspect the active authselect profile and available features first:

```bash
authselect current
authselect list-features local | grep fingerprint
```

The tested system used the `local` profile. If `with-fingerprint` is available for the active profile and is not already enabled:

```bash
sudo authselect enable-feature with-fingerprint
sudo authselect apply-changes
sudo authselect check
```

Do not manually edit authselect-generated PAM files. Review the resulting `/etc/pam.d/fingerprint-auth` before relying on fingerprint authentication.

## 7. KDE Plasma 6 lock screen

Run as the desktop user:

```bash
kwriteconfig6 --file kscreenlockerrc \
  --group Authenticators --key Fingerprint true

kreadconfig6 --file kscreenlockerrc \
  --group Authenticators --key Fingerprint
```

The setting should print `true`. The tested KDE lock-screen PAM service was `/etc/pam.d/kde-fingerprint`, which included `fingerprint-auth`.

## 8. SDDM: password OR fingerprint

**Caution:** PAM edits can prevent graphical login. Keep an existing session open, retain the account password, and know how to switch to a TTY (`Ctrl`+`Alt`+`F3`) before testing. Back up the existing file first:

```bash
sudo cp -a /etc/pam.d/sddm /etc/pam.d/sddm.before-fpc
```

On the tested Fedora 46 Rawhide system, adding these two lines at the beginning of the `auth` section in `/etc/pam.d/sddm` enabled either password or fingerprint authentication:

```pam
auth       [success=1 new_authtok_reqd=1 default=ignore] pam_unix.so try_first_pass likeauth nullok
auth       sufficient   pam_fprintd.so
```

Leave the rest of Fedora's SDDM PAM file intact. Do not replace the whole file with a copied example: PAM stacks vary by Fedora release and local configuration.

The tested behavior was:

- Password login: entering the correct account password succeeds without requiring a fingerprint.
- Fingerprint login: leave the password field empty, press Enter, and scan the enrolled finger.

This is an either/or configuration, not two-factor authentication. Test both paths separately. If behavior differs, restore the backup from a working session or TTY:

```bash
sudo cp -a /etc/pam.d/sddm.before-fpc /etc/pam.d/sddm
```

## 9. Optional KDE OpenPGP/KGpg startup prompt

On one tested Plasma 6 setup, a passphrase dialog for an OpenPGP secret key appeared immediately after desktop login. Disabling KGpg's system desktop autostart for the current user stopped the prompt. This is a report about one setup, not proof that KGpg causes every such prompt.

If the system autostart entry exists, create a per-user override:

```bash
mkdir -p ~/.config/autostart
cp /etc/xdg/autostart/org.kde.kgpg.desktop \
  ~/.config/autostart/org.kde.kgpg.desktop

if grep -q '^Hidden=' ~/.config/autostart/org.kde.kgpg.desktop; then
  sed -i 's/^Hidden=.*/Hidden=true/' \
    ~/.config/autostart/org.kde.kgpg.desktop
else
  printf '\nHidden=true\n' >> \
    ~/.config/autostart/org.kde.kgpg.desktop
fi
```

Log out and back in to test. This disables only that desktop autostart entry for the current user; it does not delete keys, disable `gpg-agent`, or uninstall KGpg. KGpg can still be started manually.

## 10. Rollback the isolated driver setup

Remove the service override and udev rule, then reload services and rules:

```bash
sudo rm -f /etc/systemd/system/fprintd.service.d/90-fpc-test.conf
sudo systemctl daemon-reload
sudo systemctl restart fprintd

sudo rm -f /etc/udev/rules.d/60-libfprint-2-device-fpc.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=usb
```

After confirming the service no longer uses the directory, remove the Lenovo libraries if desired:

```bash
sudo rm -rf /opt/fpc-test
```

Restore SDDM's backup separately if you changed its PAM file. Disable the authselect fingerprint feature only if you intend to undo that system-wide PAM setting and have checked that no other service relies on it:

```bash
sudo authselect disable-feature with-fingerprint
sudo authselect apply-changes
sudo authselect check
```

## Limitations and notes

- This uses Lenovo's modified `libfprint` and proprietary `libfpcbep.so`; it is not an upstream Fedora driver.
- The modified library is loaded by `fprintd` through a service-specific `LD_LIBRARY_PATH`. Fedora's packaged `/usr/lib64/libfprint-2.so.2` remains in place.
- This method was tested on Fedora 46 Rawhide; later Rawhide changes to `fprintd`, systemd, PAM, SDDM, or Plasma may require adjustments.
- The SDDM PAM lines are a tested example, not a universal PAM configuration. Preserve the distribution's other rules.
- KWallet auto-unlock was not verified as part of this test. Fingerprint authentication does not provide the account password to PAM, so it should not be expected to unlock a password-protected wallet automatically.
- Do not redistribute Lenovo's proprietary `libfpcbep.so`; link to Lenovo's official archive instead.
