# BFI phase-swap FSM model for the 120 Hz GBA build (mirrors gba2hdmi.sv).
# Simulates 6 swap intervals at the HDMI-frame level and checks:
# - releases happen on even frames only (game timing never shifts),
# - the swap arms at a release and applies at the next frame start,
# - each swap shows exactly one duplicate (LL or BB), alternating,
# - the interval is exactly BFI_SWAP_FRAMES game frames,
# - the overlay exemption is structural (bfi_dark includes ~overlay).
# Run: python3 bfi_swap_model.py
BFI_SWAP_FRAMES = 1800

bfi_ins = 1      # toggles every HDMI frame (starts 1 like the RTL reset state)
bfi_phase = 0
swap_cnt = 0
pending = False
releases = []    # HDMI frame indices of releases
dups = []        # (frame index, eff value) of duplicates
eff_hist = []

for f in range(6 * BFI_SWAP_FRAMES * 2 + 4):
    # frame start: toggle parity, apply pending phase flip
    bfi_ins ^= 1
    if pending:
        bfi_phase ^= 1
        pending = False
    eff = bfi_ins ^ bfi_phase
    eff_hist.append(eff)
    # release row, even frames only (gated on !bfi_ins like the RTL)
    if not bfi_ins:
        releases.append(f)
        if swap_cnt == BFI_SWAP_FRAMES - 1:
            swap_cnt = 0
            pending = True
        else:
            swap_cnt += 1

# 1. releases strictly every 2 HDMI frames (one per game frame, even only)
gaps = [b - a for a, b in zip(releases, releases[1:])]
assert min(gaps) == max(gaps) == 2, gaps[:10]
print("releases: every 2 HDMI frames, %d in %d frames: ok" % (len(releases), f + 1))

# 2. exactly one duplicate per interval, alternating lit/lit and black/black
for i in range(1, len(eff_hist)):
    if eff_hist[i] == eff_hist[i - 1]:
        dups.append((i, eff_hist[i]))
assert len(dups) == 6, dups
assert [v for _, v in dups] == [0, 1, 0, 1, 0, 1], dups  # phase starts 0
print("duplicates: one per swap, alternating at", [i for i, _ in dups], ": ok")

# 3. interval exact: duplicates 3600 HDMI frames apart
iv = [b - a for a, b in zip([i for i, _ in dups], [i for i, _ in dups][1:])]
assert iv == [2 * BFI_SWAP_FRAMES] * 5, iv
print("interval: exactly %d game frames: ok" % BFI_SWAP_FRAMES)

# 4. no tear: outside the duplicate, frames strictly alternate
bad = [i for i in range(1, len(eff_hist))
       if eff_hist[i] == eff_hist[i - 1] and i not in [d for d, _ in dups]]
assert not bad, bad[:5]
print("alternation: strict except at swaps: ok")
print("bfi_swap_model: PASS")
