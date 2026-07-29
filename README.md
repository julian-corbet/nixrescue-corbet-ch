# nixrescue

The second-order system you never hope you need: a small, self-contained
NixOS install on its own medium, with its own kernel, booted only when a
machine's everyday OS won't. It is not a laptop product and not tied to any
one host shape — it sits in front of *any* main that can substitute a
hub-built Nix closure and spare it one boot-menu entry.

nixrescue never freelances into its neighbours. It declares a boot entry (a
boot-arbitration module builds and signs it), declares repair tooling (a
storage-toolchain module composes it), declares a RAM level and a network
peer the same way — each a separate, reusable module, none of it duplicated
here.

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

**A plain function** (`lib.mkMaintainer`), called by a MAIN — NixOS or not.
"Build a squashfs of a toplevel's closure, fit-check it, `dd` it onto a raw
device, skip the whole thing if nothing changed" needs nothing NixOS-specific,
so a NixOS main and a system-manager main call this identically. See
`lib/mkMaintainer.nix`.

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

On the main, wherever it periodically materialises the rescue onto its cold
medium:

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
which is the entire reason `mkMaintainer` stays a function and never becomes
a module.

## What is deliberately not here

No `nixrescue.kernel.*` — every rescue reuses its own host's stock
`boot.kernelPackages`, pinned simply by whichever toplevel `mkMaintainer` was
pointed at. No ESP filename, signing, or NVRAM entry — that is a boot-loader
module's job; this project only declares repair tooling and a boot target.
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
real closure with the production `mksquashfs` invocation on every `nix flake check`, failing the
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

Not yet tested here, on purpose: a real UEFI boot path through a signed UKI
(that belongs to the boot-arbitration module this project sits behind, once
its own extra-entry mechanism exists) and firmware binding (no VM has real
GPU or radio hardware to bind against — see `docs/design.md` for how that gap
gets closed instead).
