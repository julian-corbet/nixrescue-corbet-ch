# Design notes

The reasoning behind the release mechanisms this repo actually ships. Host-specific
facts (which machine, which measurement was taken where) live outside
this repo on purpose — everything below is the mechanism, portable to any
consumer.

## Target composition boundary

The common host model separates device class from boot role. `nixarch`,
`nixnas`, and `nixvps` are device-class adapters; `primary` and `nixrescue`
are boot roles. A container is an explicit no-boot case with no ESP or
firmware actuator. The same intent should be visible across NixOS,
system-manager, and Home Manager where the plane can participate, without
inventing a Home Manager boot actuator.

Within that model, nixrescue owns only recovery content and runtime. nixboot
produces and verifies the UKI/ESP artifact around it. nixdeploy is the
delivery specialist: scheduling, authenticated transport, post-health reconciliation,
activation, rollback, reimage, and typed outcomes. The private
composition selects the class and role and supplies every real host, disk,
identity, endpoint, key, and production-policy fact.

`lib.mkRelease` makes the signed-manifest unit; `lib.mkReconciler` owns the
content-specific raw-slot and UKI pairing. nixdeploy passes the exact authenticated artifact to
that command. A/B/C media provide interruption-safe rotation; an explicitly declared single-slot
medium provides verified in-place repair without pretending it has rollback. The obsolete
whole-device maintainer path is removed.

## Storage format: squashfs, not erofs, not f2fs

The rescue image is one read-only artifact, read into RAM once and then
served from page cache — never rewritten in place. Under that shape,
`mksquashfs -comp zstd -Xcompression-level 22 -b 1M` beat both alternatives
tried:

- **erofs at the same compression level came out larger, not smaller, and
  took roughly twenty times longer to build.** Its real advantage —
  fixed-output-size pclusters giving better random-read latency — is moot
  for an image that lives in RAM after first touch. Separately,
  `-Ededupe` silently disables multi-threading for the *entire* erofs-utils
  run (a one-shot global flag, not per-file), independent of `--workers` —
  worth knowing if erofs is ever revisited for a different shape of image.
- **f2fs does not release blocks unless a write path explicitly asks.**
  Compression reserves the *uncompressed* block count against the inode
  until `release_cblocks` runs, so every write path has to remember to
  release, and it is easy for one not to. f2fs earns its keep on a
  genuinely mutable store living on flash; it is the wrong tool for a
  write-once image.

`-b 1M`, squashfs's maximum block size, trades "reading one byte
decompresses a whole megabyte" for the best ratio at that level — a real
cost when loop-mounting for random access, irrelevant once the image is
RAM-resident with pages cached after first touch.

## Medium layout in the current implementation

Raw partitions, one squashfs `dd`'d onto each — no containing filesystem.
Nothing to fsck, nothing to corrupt in the ordinary sense: a slot is a valid
squashfs superblock or it is not, and `mount -t squashfs` reads it straight
off the block device. Equal slot size across every target medium is what
lets one image be one artifact with one size budget; per-device identity
belongs in the vault, not in the rescue image itself.

The slot count is a device-class fact. On a three-slot medium, current and previous remain
protected while a new release lands in the third. On an explicit one-slot medium, the reconciler
first completes and verifies the replacement UKI, then rewrites and reads back the sole squashfs,
and publishes the matching UKI last. It records no fictional previous generation: power loss
during that raw write requires repair from the next successful main boot.

Slots are found by partition name, which makes the naming rule part of this
contract rather than a habit of whichever tool carved the medium. A
partition takes the bare name of the module that owns its content
(`nixrescue`, `nixvault`), and an `-a`/`-b`/`-c` suffix only on a medium
carrying several of that same role. There is deliberately no `-slot`/`-part`
infix: the GPT type code already says *what* a partition is, so the name
only has to say *whose* it is. `examples/rescue`'s probe globs `nixrescue*`
to match both shapes. A medium named any other way fails silently rather
than loudly — a glob matching nothing expands to itself, every existence
test on it then fails, and the image boots to no store at all.

The UKI embeds the squashfs SHA-256 digest and byte length as well as the exact
`init=/nix/store/.../init`. The initrd hashes a candidate's signed byte range before mounting it,
then checks the pathname and `nix-path-registration`. A store pathname is not an integrity proof:
an attacker can manufacture it inside another squashfs. The ESP pointer is only a performance hint
among digest-compatible slots.

## Boot flow

```
boot → firmware verifies the host-signed UKI
     → signed image digest authenticates a raw slot before the initrd mounts it
     → embedded init path confirms the release is internally coherent
     → rescue OS up from a plaintext slot        (zero crypto in the content path)
     → operator PUBLIC keys come from the shared image
     → device TPM unseals only its SSH host identity
        (missing credential or PCR mismatch: sshd stays down, console stays usable)
     → a vault's passphrase, if one is configured, at the console or over SSH
        (systemd-ask-password, the same pattern a boot-arbitration module's
         own initrd remote-unlock already uses elsewhere in this family)
     → vault opens → real identity → normal reachability
     → passphrase times out → still a fully usable, local-only rescue
```

Public keys live in the image because they are not secret. The TPM credential gates only SSH
identity and never decrypts a vault or disk. Every useful data container still requires the
operator's passphrase. Its runtime producer is shared across planes through
`nixboot.lib.mkTpmSshCredential`; no rescue derivation generates or contains a device identity.

## Firmware: curated, not the whole redistributable set

`hardware.enableRedistributableFirmware = true` hands the kernel the entire upstream
`linux-firmware` package — every vendor's blobs, for hardware a given rescue will never see.
Inside an image sized to a small, fixed slot, that is not a rounding error; it is the largest
single thing in the closure after the toplevel itself. `lib/firmware.nix` curates instead: a
reviewable list of whole top-level vendor subtrees (the same shape nixfs keeps its own
filesystem/tool catalogue as data), copied out of the upstream package via
`hardware.enableRedistributableFirmware = false` plus `hardware.firmware = [ (curated
derivation) ]`.

Three traps, each verified against a real build, not assumed:

- **The flat-name trap.** A driver requests firmware by a flat name
  (`iwlwifi-so-a0-gf-a0-89.ucode`), never by its vendor-directory path. Upstream satisfies that
  with a symlink sitting at the *top* of the firmware tree, pointing into the vendor directory
  where the real bytes live. Copying the vendor directory copies the bytes; it does not copy the
  sibling symlink that makes them reachable by the name the kernel actually asks for. The fix
  resolves every top-level symlink whose target falls under a selected subtree and recreates it,
  rather than hand-listing glob patterns that would silently miss whichever name someone didn't
  think to type.
- **The partial-vendor-directory trap.** Never trim inside a subtree once it is selected. A vendor
  directory is one hardware generation's firmware next to the next generation's; a partially
  curated directory looks identical to a complete one until the day a device stops binding, which
  is the exact failure curation exists to prevent.
- **The cross-vendor-symlink trap.** A selected directory's own internal symlinks are not
  guaranteed to stay inside it — some OEM-branded firmware is a re-badge of a blob filed under a
  different, unselected vendor directory entirely. Copying the selected directory whole still
  copies that symlink, now pointing at nothing. The fix is general rather than a per-case
  exception: any symlink that copies dangling gets dereferenced against the full, uncurated source
  tree instead, which always resolves.

## Size is a build-time gate, not a `dd`-time surprise

`checks/rescue-image-fits-slot.nix` builds the real
squashfs from the generic example closure, using the module's exact `mksquashfs` invocation, and
fails the *derivation* the moment that image would not fit its declared slot. An image that grows
too fat to ship becomes a build failure here, long before anyone reaches for a `dd`.

`mkReconciler` repeats the capacity check against the selected live slot before writing and then
hashes the bytes back from the device.

## Headless and graphical, from one closure

Every consumer boots to `multi-user.target`; sshd comes up only with a valid device credential. A graphical
session is raised on demand at the console, never automatically. This
project's own module never names a compositor — `nixrescue.gui.package` is a
bare package pointer, resolved with `lib.getExe`, and `null` means
headless-only. Which compositor to point it at stays the consumer's own
choice; nothing about the module changed to let `examples/rescue` make one.

`examples/rescue` makes that generic example choice through the same pointer:
[nixscroll](https://github.com/julian-corbet/nixscroll-corbet-ch)'s `scroll`
compositor plus a plain terminal (`foot`). The build-time size gate, rather
than a production measurement copied into documentation, proves that the
chosen example still fits its declared illustrative budget. The example
fills no other desktop role; a real composition chooses its own payload and
budget privately.

## Testing philosophy — and its one honest gap

A `pkgs.testers.nixosTest` VM proves the software: it boots, the toolchain
is really there, a synthetic broken disk really gets found, unlocked and
read, materialisation really writes real bytes to a real block device. What
it cannot prove is firmware binding — no VM has a real GPU or a real radio
to bind against, so a curated firmware set that boots clean in QEMU can still
fail to bind a real device on real hardware. That risk is closed with one
supervised human boot per physical target at first install, confirming the
hardware that actually matters comes up; everything after that first boot is
automated.
