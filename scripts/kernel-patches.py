#!/usr/bin/env python3
"""Patch Kleaf so device modules are signed with the GKI-generated key.

Usage: kernel-patches.py <kernel-work-dir>
"""

import pathlib
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "kernel")
if not (root / "common/ack").is_dir():
    sys.exit(f"not a GrapheneOS kernel tree: {root}")


def patch(rel, old, new, marker):
    p = root / rel
    s = p.read_text()
    if marker in s:
        return False
    if old not in s:
        sys.exit(f"patch anchor not found in {rel}")
    p.write_text(s.replace(old, new, 1))
    return True


# The kernel_build rule exposes implicit outputs as filegroups.
key_label = '"//common/ack:kernel_aarch64/certs/signing_key.pem"'
patch(
    "private/devices/google/common/kleaf/device_build.bzl",
    '        make_goals = ["modules", "dtbs"],\n'
    "        kmi_symbol_list = target_kmi_symbol_list,",
    '        make_goals = ["modules", "dtbs"],\n'
    f"        module_signing_key = {key_label},\n"
    "        kmi_symbol_list = target_kmi_symbol_list,",
    marker=f"module_signing_key = {key_label}",
)

# sign-file accepts the combined PEM as both key and certificate.
patch(
    "common/ack/scripts/Makefile.modinst",
    'cmd_sign = scripts/sign-file $(CONFIG_MODULE_SIG_HASH) "$(sig-key)" '
    "certs/signing_key.x509 $@ \\\n",
    'cmd_sign = scripts/sign-file $(CONFIG_MODULE_SIG_HASH) "$(sig-key)" '
    '"$(sig-key)" $@ \\\n',
    marker='"$(sig-key)" "$(sig-key)"',
)

print(f"kernel patches applied to {root}")
