# nixrescue

The second-order system you never hope you need: a small, self-contained
NixOS install on its own medium, with its own kernel, booted only when a
machine's everyday OS won't. It is not a laptop product and not tied to any
one host shape — it sits in front of *any* main that can substitute a
Nix closure and expose it as a boot artifact.

nixrescue produces recovery content and runtime behavior. It does not own
the surrounding UKI, ESP entry, signing, firmware registration, transport,
activation, or rollback. Those boundaries are explicit below.

## The runtime and release contract

**A tiny NixOS module** (`nixosModules.default`), imported into the rescue's
OWN `nixosConfigurations.<host>-rescue` — never into a main's configuration.
The rescue IS a NixOS configuration; its payload is ordinary
`environment.systemPackages` and ordinary service config in the consumer's
own config. This module exists only for the handful of things genuinely
specific to being a rescue: a pointer to an optional graphical session, the
operator's public keys, which device (if any) holds this host's vault and
how long to wait for it, and a staleness stamp a human can actually read.
See `modules/nixrescue.nix` for the full option surface and its SCOPE block.

**Two plain release functions.** `lib.mkRelease` builds one squashfs, hashes it, asks nixboot to
embed its digest and byte length in the unsigned UKI, and binds those artifacts below one immutable
store path. `lib.mkReconciler` accepts only that exact signed-manifest artifact, verifies the UKI
and raw bytes, and publishes `current` last. Its explicit modes are atomic A/B/C rotation or a
single verified in-place slot with no on-medium rollback.
Both are backend-neutral; there is no legacy whole-device maintainer path.

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
- **nixdeploy** authenticates and transports the exact release, then invokes its reconciler after
  a healthy activation and on AlreadyCurrent. Only system planes may receive boot authority.

The private composition chooses the device class and boot role and supplies
all real host, disk, identity, endpoint, key, and production-policy facts.
This public repo contains only the reusable mechanism, examples, and tests.

The shared image contains no host private identity. A receiving device may contribute one
TPM/PCR-bound SSH host-key credential through systemd-stub; failed unseal leaves sshd down and the
console working. NixOS initrd-SSH hosts maintain it through nixboot; other Linux/system-manager
hosts use `nixboot.lib.mkTpmSshCredential`. TPM is never an unlock path for a vault or another data
container.

## Quickstart

```nix
{
  inputs.nixrescue.url = "github:julian-corbet/nixrescue-corbet-ch";
}
```

On the rescue's own configuration:

```nix
# one generic nixosSystem shared by every compatible machine
{
  imports = [ inputs.nixrescue.nixosModules.default inputs.nixrescue.nixosModules.overlayStore ];
  nixrescue = {
    enable = true;
    builtAt = "2026-07-28T00:00:00Z"; # stamped by whatever builds this image
    authorizedKeys = [ "ssh-ed25519 AAAA... operator" ];
    ssh.enable = true; # TPM credential required by default; no fallback identity
    gui.package = null; # or a package whose one entrypoint raises a session
    vault.device = "/dev/disk/by-partlabel/vault"; # or leave null: no vault
  };
}
```

On a main that consumes the immutable release:

```nix
let
  release = inputs.nixrescue.lib.mkRelease {
    inherit pkgs toplevel;
    mkUki = { kernelParamFile, ... }: inputs.nixboot.lib.mkUki {
      inherit pkgs toplevel;
      name = "nixrescue";
      kernelParamFiles = [ kernelParamFile ];
    };
  };
  reconciler = inputs.nixrescue.lib.mkReconciler {
    inherit pkgs;
    name = "machine-class";
    release = release.bundle;
    slots = map (n: "/dev/disk/by-partlabel/nixrescue-${n}") [ "a" "b" "c" ];
    signing = {
      enable = true;
      dbKey = "/run/secure-boot/keys/db/db.key";
      dbCert = "/run/secure-boot/keys/db/db.pem";
    };
  };
in {
  nixdeploy.receiver.bootRoleReconcile = {
    command = "${reconciler}/bin/nixrescue-reconcile-machine-class";
    role = "nixrescue";
  };
}
```

The signed manifest must name `release.bundle` exactly. The reconciler rejects any other argument;
it is safe to run after every successful boot as well as through nixdeploy.

For a device with exactly one rescue partition, declare the geometry rather than inventing slots:

```nix
slots = [ "/dev/disk/by-partlabel/nixrescue" ];
updateMode = "in-place";
historyKeep = 1;
```

That mode signs and verifies the replacement UKI before touching the raw slot, validates the
written image against the digest authenticated by the UKI, and publishes the matching UKI last. It
cannot preserve the old squashfs across a power loss during the one physical write; A/B/C media
remain the mode for on-medium rollback.

## What is deliberately not here

No `nixrescue.kernel.*` — the shared configuration chooses one broad kernel/module set. No NVRAM
write or Secure Boot enrollment — firmware ownership is a supervised ceremony. No transport,
activation, reimage, or outcome model — nixdeploy owns those. The content-specific raw-slot and
UKI-pair validation remains here in `mkReconciler`.
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
infrastructure) and asserts the runtime contract: `multi-user.target`
reached, the repair toolchain
present with a tool actually run, the GUI pointer actually launching its
target, a synthetic broken disk (LUKS + btrfs, built inside the VM) found,
unlocked and mounted with a file read back off it. The reconciler VM separately exercises both a
real GPT A/B/C medium and an independent one-slot medium, including signature verification,
read-back hashing, publication order, history rotation where possible, and repeat idempotence.
`nix flake check` runs it alongside the module's own rendering-only `checks/eval-tests.nix`.

`checks/rescue-uefi-boot-vm-test.nix` separately exercises an OVMF UEFI path through a UKI built by
nixboot. It proves the production resolver rejects a valid squashfs with the expected pathname but
the wrong signed digest. It proves the software boundary; it does not prove physical firmware
binding to a real GPU or radio.
