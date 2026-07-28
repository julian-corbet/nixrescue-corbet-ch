# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth writing
up properly. Nothing here is guaranteed to work, be maintained, or survive the
next cleanup pass. If something turns out to matter, distill the finding into
[`../studies/`](../studies/README.md) and let the experiment stay disposable.

This is also the open-questions ledger for this project's own judgment calls.
Every entry below is a design choice that is *reasoned*, not yet *measured*
against a real build — recorded so the difference stays visible.

All open; nothing has been run yet.

## 001 — a real UEFI boot path through `pkgs.testers.nixosTest`

**Question:** `checks/rescue-vm-test.nix` boots the rescue's own NixOS
configuration directly under QEMU, which needs no signed UKI, no boot
partition, no slot-selection pointer file. nixpkgs' own `qemu-vm.nix` also
supports `useEFIBoot` and `useBootLoader`, which would let a test walk
through real UEFI firmware, a real boot menu, and real slot selection.

**Reasoning as it stands:** the harness is deliberately built to grow rather
than arrive complete — a passing boot test beats an aspirational suite that
never ships. The UEFI path also depends on a boot-arbitration module's own
extra-entry mechanism, which does not exist yet; blocking this project's own
tests on that would be exactly the kind of premature coupling its module
split exists to avoid.

**What would settle it:** the extra-entry mechanism landing anywhere in the
family. Once a signed second UKI can be built and named, extending this
harness with `useEFIBoot = true` is additive, not a redesign.

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
firmware) against a real slot size is a fleet-specific measurement this repo
deliberately does not carry.

**Reasoning as it stands:** shipping fleet byte-counts in a public repo
would tie mechanism to topology, which this project's own house rule
forbids. The mechanism (equal slot size, squashfs at level 22, a stated
firmware curation strategy) is what's portable; the exact numbers are not.

**What would settle it:** nothing, here — that measurement belongs in
whichever consumer's own configuration actually sizes its slots, not in this
repo.
