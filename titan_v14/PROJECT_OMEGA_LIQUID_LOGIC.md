# Project OMEGA: Liquid Logic Analysis

## Overview
128-node combinatorial chaos network (clock-less). Each node: XOR(3 neighbors) XOR inject.
Source: `PROJECT-HIDRA SAF2/rtl/omega/liquid_reservoir.vhd` (62KB)

## V14 Integration Status
- `chaos_node.vhd` + `liquid_reservoir.vhd` -> `rtl/aegis/` (GHDL analyzed OK)
- **Simulation-only** — NOT in Vivado synthesis path
- No dedicated testbench (analysis-only validation)

## Potential Use Cases

| Use Case | Feasibility | V14 Overlap |
|----------|-------------|-------------|
| **PUF (Physical Unclonable Function)** | High | None — unique capability |
| Entropy source | Low | `trng_ring_osc` already exists |
| Side-channel protection | Low | Omega Cloak already covers |
| Research/demo showcase | High | Adds innovation narrative |

## Recommended Path: PUF
Each FPGA's unique routing delays cause the combinatorial network to settle
into chip-specific bit patterns. This creates a hardware fingerprint for:
- Device authentication (anti-cloning)
- Secure key derivation (chip-bound keys)
- Factory provisioning (without eFUSE dependency)

## Technical Risks
1. **Combinatorial loops**: Vivado requires `ALLOW_COMBINATORIAL_LOOPS` + `dont_touch`
2. **Temperature/voltage sensitivity**: PUF output may drift — needs fuzzy extraction
3. **XOR linearity**: Network is linear over GF(2) — cryptographically weak alone
4. **Verification gap**: No formal verification possible for combinatorial loops

## Phase 3 Roadmap
- [ ] Hardware PUF characterization on Artix-7
- [ ] Bit stability analysis across temperature range
- [ ] Fuzzy extraction algorithm for stable key derivation
- [ ] Integration with eFUSE for hybrid authentication
