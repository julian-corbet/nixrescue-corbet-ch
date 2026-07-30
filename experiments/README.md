# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth writing
up properly. Nothing here is guaranteed to work, be maintained, or survive the
next cleanup pass. If something turns out to matter, distill the finding into
[`../studies/`](../studies/README.md) and let the experiment stay disposable.

This is also the open-questions ledger for this project's own judgment calls.
Every entry below is a design choice that is *reasoned*, not yet *measured*
against a real build — recorded so the difference stays visible.

Two of the three below are now settled; #002 remains open.

## 001 — a real UEFI boot path through `pkgs.testers.nixosTest` — SETTLED

**Question:** `checks/rescue-vm-test.nix` boots the rescue's own NixOS
configuration directly under QEMU, which needs no signed UKI, no boot
partition, no slot-selection pointer file. nixpkgs' own `qemu-vm.nix` also
supports `useEFIBoot` and `useBootLoader`, which would let a test walk
through real UEFI firmware, a real boot menu, and real slot selection.

**Settled.** `nixboot.extraEntries` landed upstream, and
`checks/rescue-uefi-boot-vm-test.nix` now exercises exactly this: real OVMF
firmware, a real signed-or-unsigned UKI, and both the pointer-honoured and
fallback-on-bad-pointer slot-selection scenarios. See that file's own header
for the full chain it proves and `checks/default.nix` for how it is wired
into `nix flake check`.

## 002 — exercising the vault-unlock path end to end

**Question:** `modules/nixrescue.nix` renders `nixrescue-unlock-vault` when
`vault.device` is set, but no test yet builds a synthetic vault container
(LUKS → squashfs, matching the real one's shape) and drives the actual
unlock-and-mount path against it, the way `rescue-vm-test.nix` already does
for the generic broken-disk case.

**Reasoning as it stands:** the disk-recovery subtest already proves the
underlying primitives (find, unlock, mount a LUKS-backed volume) work inside
this harness. A vault-shaped fixture is a genuinely separate second
consumer — the packing format is a different module's job — so building one
here risks the exact fixture-ownership mistake this family's own test-domain
design record warns about.

**What would settle it:** a second consumer of the same synthetic-vault
fixture appearing (the packing module's own test suite is the obvious
candidate). Until then, a hand-rolled fixture here would be premature.

## 003 — squashfs image size headroom under real curated firmware

**Question:** `docs/design.md` states the storage-format decision in
generic terms; the actual byte budget for a real image (OS plus curated
firmware) against a real slot size is a host-specific measurement this repo
deliberately does not carry.

**Settled at the mechanism level.** `examples/rescue` is now a real, generic
`nixosConfigurations.rescue` (nixrescue's own module, `nixfs`, curated
firmware via `lib/firmware.nix`, and the overlay store arrangement), and
`checks/rescue-image-fits-slot.nix` builds its real closure into a real
squashfs with the production invocation and fails the *build* if it would
not fit a declared slot size, on every `nix flake check`. That is the part
that is portable and belongs in this repo.

**What still does not belong here:** the actual byte counts a real consumer
measures for a real slot on a real medium. Shipping host-specific byte-counts in a
public repo would tie mechanism to topology, which this project's own house
rule forbids — that measurement belongs in whichever consumer's own
configuration actually sizes its slots, taken by running the same check
against that consumer's own toplevel and slot size.
