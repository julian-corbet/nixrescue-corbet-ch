# nixrescue

The second-order system you never hope you need: a small, self-contained
NixOS install on its own medium, with its own kernel, booted only when a
machine's everyday OS won't. It is not a laptop product and not tied to any
one host shape — it sits in front of *any* main that can substitute a
Nix closure and expose it as a boot artifact.

nixrescue produces recovery content and runtime behavior. It does not own
the surrounding UKI, ESP entry, signing, firmware registration, transport,
activation, or rollback. Those boundaries are explicit below.

## The two things this repo actually is

**A tiny NixOS module** (`nixosModules.default`), imported into the rescue's
OWN `nixosConfigurations.<host>-rescue` — never into a main's configuration.
The rescue IS a NixOS configuration; its payload is ordinary
`environment.systemPackages` and ordinary service config in the consumer's
own config. This module exists only for the handful of things genuinely
specific to being a rescue: a pointer to an optional graphical session, the
operator's public keys, which device (if any) holds this host's vault and
how long to wait for it, and a staleness stamp a human can actually read.
See `modules/nixrescue.nix` for the full option surface and its SCOPE block.

**A plain function** (`lib.mkMaintainer`), currently called by a MAIN — NixOS or not.
"Build a squashfs of a toplevel's closure, fit-check it, `dd` it onto a raw
device, skip the whole thing if nothing changed" needs nothing NixOS-specific,
so a NixOS main and a system-manager main call this identically. See
`lib/mkMaintainer.nix`. This is current implemented behavior, not the target
ownership boundary: materialization and scheduling move to nixdeploy.

## Target architecture and ownership boundary

The target host model has two independent axes. A device class is `nixarch`,
`nixnas`, or `nixvps`; a boot role is `primary` or `nixrescue`. The recovery
role may be composed for any bootable class. A container or other target with
no firmware handoff is an explicit no-boot case and carries no boot role,
ESP, or firmware actuator.

The three specialists meet without overlapping:

- **nixrescue** produces the recovery NixOS content and its runtime contract;
- **nixboot** produces and verifies the boot artifact that points at that
  content, including UKI construction and signing;
- **nixdeploy** alone delivers it across NixOS, system-manager, and Home
  Manager where meaningful: scheduling, transport, materialization, slot
  rotation and selection, activation, rollback, reimage, and typed outcomes.

The private composition chooses the device class and boot role and supplies
all real host, disk, identity, endpoint, key, and production-policy facts.
This public repo contains only the reusable mechanism, examples, and tests.

This target is not fully implemented today. `nixosModules.default` already
produces the rescue runtime. nixboot's `extraEntries.*` already builds the
boot artifact used by the UEFI integration test. However,
`lib.mkMaintainer`, its example timers, and slot-selection logic still live
here; they are migration debt to nixdeploy, not a second delivery contract to
extend.

## Quickstart

```nix
{
  inputs.nixrescue.url = "github:julian-corbet/nixrescue-corbet-ch";
}
```

On the rescue's own configuration:

```nix
# nixosConfigurations."myhost-rescue" — a real, separate NixOS system
{
  imports = [ inputs.nixrescue.nixosModules.default ];
  nixrescue = {
    enable = true;
    builtAt = "2026-07-28T00:00:00Z"; # stamped by whatever builds this image
    authorizedKeys = [ "ssh-ed25519 AAAA... operator" ];
    gui.package = null; # or a package whose one entrypoint raises a session
    vault.device = "/dev/disk/by-partlabel/vault"; # or leave null: no vault
  };
}
```

Current API, on the main that materializes the rescue onto its cold medium:

```nix
let
  maintainer = inputs.nixrescue.lib.mkMaintainer {
    inherit pkgs;
    name = "slot-a";
    toplevel = self.nixosConfigurations."myhost-rescue".config.system.build.toplevel;
    device = "/dev/disk/by-partlabel/nixrescue-a";
  };
in {
  systemd.services.nixrescue-maintain-slot-a = maintainer.service;
  systemd.timers.nixrescue-maintain-slot-a = maintainer.timer;
}
```

That assignment is identical whether this config is a real NixOS
`configuration.nix` or a system-manager config — both understand
`systemd.services.<name>` / `systemd.timers.<name>` as plain attribute sets,
which is why the current helper is a function rather than a module. New
delivery design belongs in nixdeploy; do not grow this helper into another
scheduler or rollout engine.

## What is deliberately not here

No `nixrescue.kernel.*` — every rescue reuses its own host's stock
`boot.kernelPackages`, pinned simply by whichever toplevel `mkMaintainer` was
pointed at. No ESP filename, signing, or NVRAM entry — nixboot produces and
verifies that artifact. No transport, scheduling, materialization policy,
slot rotation/selection, activation, rollback, reimage, or outcome model —
nixdeploy owns delivery. This project's current `mkMaintainer` and slot logic
predate that boundary and are to be migrated, not copied.
No `apps.*`, no `desktop.enable` — a consumer wanting a tool in its rescue
reaches for ordinary `environment.systemPackages` in its own configuration.
No opinion on what a vault contains or how it's packed — this project only
knows which device to try and how long to wait for a passphrase; packing is
a separate module's whole job, kept deliberately apart.

See `docs/design.md` for the medium layout, the storage-format decision, and
the boot-flow this module implements pieces of.

## `examples/rescue` — a real, generic `nixosConfigurations.rescue`

Not a host config, and not imported by anything else in this repo — an example composing this
project's own module with `nixfs` (the repair toolchain), curated firmware, the
squashfs+tmpfs overlay store arrangement a slot boots into, and a graphical session. `flake.nix`
builds it as `nixosConfigurations.rescue`, and `checks/rescue-image-fits-slot.nix` squashes its
real closure with the module's exact `mksquashfs` invocation on every `nix flake check`, failing the
build outright if it would not fit its declared slot. `nixrescue.gui.package` is wired here to
[nixscroll](https://github.com/julian-corbet/nixscroll-corbet-ch)'s `scroll` compositor, plus a
plain `foot` terminal for it to spawn — this project's own module still never picks a compositor
itself (see `modules/nixrescue.nix`'s own option doc); only this example does, and it fills no
other role (no bar, no notifier, no file manager, no polkit agent, no audio). See
`examples/rescue/configuration.nix`'s own comment for why that's wired directly rather than
through nixdesktop's policy+backend split, for now.

## `lib/firmware.nix` — curated firmware, not the whole redistributable set

A reviewable list of whole vendor subtrees (AMD and Intel graphics, Intel and MediaTek wireless,
CPU microcode), copied out of upstream `linux-firmware` rather than shipping the entire
package via `hardware.enableRedistributableFirmware = true`. `mkCuratedFirmware` does the
copying and closes three verified traps along the way — the flat driver-requested name that lives
as a symlink one level above its vendor directory, the partial-vendor-directory trap of trimming
inside a subtree once selected, and a cross-vendor symlink some OEM firmware uses to re-badge
another vendor's blob. See the file's own header for all three, and `docs/design.md` for the
short version.

## Testing

`checks/rescue-vm-test.nix` boots a real, disposable QEMU VM
(`pkgs.testers.nixosTest` — nothing persists after the build, no standing VM
infrastructure) and asserts the boot contract end to end: `multi-user.target`
reached, sshd up with the operator key installed, the repair toolchain
present with a tool actually run, the GUI pointer actually launching its
target, a synthetic broken disk (LUKS + btrfs, built inside the VM) found,
unlocked and mounted with a file read back off it, and `lib.mkMaintainer`
itself building a real squashfs and writing it to a raw device. `nix flake
check` runs it, alongside the module's own rendering-only `checks/eval-tests.nix`.

`checks/rescue-uefi-boot-vm-test.nix` separately exercises an OVMF UEFI path
through a UKI built by nixboot's `extraEntries.*`, including the currently
local slot-selection behavior. It proves the software boundary; it does not
prove physical firmware binding to a real GPU or radio. The slot-delivery
portion belongs in nixdeploy under the target architecture above.
