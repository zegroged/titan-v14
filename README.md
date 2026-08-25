# TITAN V14

> An FPGA-based hardware security module: custom AES-256, ring-oscillator TRNG, and side-channel countermeasures in VHDL, paired with a post-quantum cryptography stack in Rust.

**Turkish README:** [README.tr.md](README.tr.md)

![VHDL](https://img.shields.io/badge/VHDL-174%20files-blue)
![Rust](https://img.shields.io/badge/Rust-11%20crates-orange)
![Target](https://img.shields.io/badge/Target-Artix--7%20XC7A100T%20%2B%20PolarFire-lightgrey)
![Simulation](https://img.shields.io/badge/GHDL-13%2F13%20testbenches%20pass-brightgreen)
![Synthesis](https://img.shields.io/badge/Vivado-synthesized%2C%206.5%25%20of%20XC7A100T-brightgreen)
![Status](https://img.shields.io/badge/Status-never%20fabricated-yellow)
![License](https://img.shields.io/badge/License-MIT-blue)

---

## Status — read this first

This project was **designed, simulated, and synthesized for its target part. It was
never built in silicon.** Every claim below is a simulation or synthesis result, not
a measurement from working hardware.

The synthesis is real and the reports are in this repository. Vivado synthesized the
top-level design `artix7_top_v14` for the Artix-7 XC7A100T:

| Metric | Top level (`v14_ooc_synth`) | AES subsystem (`v14_aes_synth`) |
| --- | --- | --- |
| Slice LUTs | 4,098 (6.46%) | 4,183 (6.60%) |
| Slice registers | 3,959 (3.12%) | 3,162 (2.49%) |
| Block RAM | 0 | 0 |
| DSP slices | 0 | 0 |

The design fits in roughly 6.5% of the part and uses no block RAM or DSP slices — the
AES datapath, the TRNG, and the countermeasure logic are all pure fabric. Reports:
[`titan_v14/reports/`](titan_v14/reports/).

It was an independent project, intended as a portfolio piece to approach a defense
electronics company. It stopped when the cost of fabricating a single custom
dual-FPGA board turned out to be far beyond what I could fund. Nothing here was
produced under contract, and no third party holds rights to it.

Publishing it as a reference implementation: the RTL, the testbenches, the build
scripts, and the design documents are all here.

---

## Overview

TITAN is a two-chip security terminal design. A **Xilinx Artix-7 (XC7A100T)** carries
the cryptographic datapath and the countermeasure logic; a **Microchip PolarFire
(MPF100)** was planned as the supervisory device, chosen for its flash-based fabric
and built-in design security. Between them sits a red/black separation boundary — the
"BLACK" UART is the only path that leaves the secure side.

The interesting part is not that it does AES. It is what surrounds the AES:

- The S-box has a **masked variant** (`aes_sbox_masked.vhd`) — a first-order boolean
  masking countermeasure against differential power analysis.
- A **dummy operation injector** and a **clock jitter injector** run alongside the
  datapath, so power and timing traces do not line up with the real rounds.
- An **Echo State Network** (reservoir computing) is implemented in hardware to flag
  anomalous behaviour, fed by a **PVT monitor** watching process, voltage, and
  temperature for glitch and fault-injection attempts.
- A **power-on self test** (`post_self_test.vhd`) runs known-answer tests against
  fixed NIST vectors before the device will operate.
- A **kill protocol** (`kill_protocol.vhd`) erases key material on a supervisory
  signal.

The Rust side (`titan-core/`) is the protocol layer that was meant to run above the
hardware: post-quantum key exchange and signatures, a Double Ratchet, a DHT, and a
dead-drop transport.

---

## What is in the repository

### Hardware (VHDL — 174 files)

| Area | Modules |
| --- | --- |
| Symmetric crypto | `aes256_core`, `aes_key_expand`, `aes_round`, `aes_sbox`, **`aes_sbox_masked`** |
| Entropy | `trng_ring_osc`, `trng_wrapper` |
| Key handling | `secure_key_storage`, `key_loader_spi`, `kill_protocol` |
| Countermeasures | dummy-operation injector, clock-jitter injector, `post_self_test` |
| Anomaly detection | ESN reservoir core, ESN readout layer, anomaly detector, PVT monitor |
| I/O and control | `spi_cmd_slave`, `uart_driver`, `uart_telemetry`, `comm_protocol`, `data_gearbox` |
| Supervision | `system_supervisor`, `watchdog_monitor` |

**84 RTL modules, 66 testbenches.** GHDL reports 13 of 13 integration-level
testbenches passing, including the Artix-7 top-level integration test.

### Software (Rust — 11 crates)

| Crate | Purpose |
| --- | --- |
| `titan_kyber` | Post-quantum key encapsulation (ML-KEM / Kyber) |
| `titan_dilithium` | Post-quantum signatures (ML-DSA / Dilithium) |
| `titan_ratchet` | Double Ratchet forward secrecy |
| `titan_envelope` | Message sealing |
| `titan_entropy` | Entropy collection and health checks |
| `titan_dht` | Distributed hash table |
| `titan_dead_drop` | Asynchronous message drop |
| `titan_hopping` | Frequency hopping logic |
| `titan_hal` | Hardware abstraction over the FPGA link |
| `titan_sentry` | Runtime monitoring |
| `titan_integration_tests` | Cross-crate integration tests |

A second workspace, `titan_v14/sw/`, holds the host-side tools: `hidra_core` (with a
fuzzing harness), `hidra_net`, `hidra_sim`, `hidra_e2e`, and `hidra_ui`.

### Documents

`titan_v14/docs/` contains the design material that usually does not survive a hobby
project: a [key ceremony procedure](titan_v14/docs/key_ceremony.md), a
[reproducible build](titan_v14/docs/reproducible_build.md) description, an
[ephemeral build](titan_v14/docs/ephemeral_build.md) note, a hardware test plan, a
security policy, and a cellular module engineering plan.

---

## Building

No board is required — the testbenches run in simulation, and the synthesis reports
already in `titan_v14/reports/` were produced by the Tcl flow below.

```bat
:: VHDL simulation (GHDL) — Windows
cd titan_v14\scripts
run_all_tb.bat
```

```bash
# Rust workspace
cd titan-core
cargo test
```

Synthesis is driven by the Tcl scripts in `titan_v14/scripts/` — `build_artix7.tcl`
and `build_bitstream.tcl` for Vivado, `build_polarfire_*.tcl` for the PolarFire side
that was never completed. Neither toolchain is required to run the simulations.

---

## Known limitations

These are the honest gaps. Most of them exist because the project stopped before
hardware.

1. **No silicon validation.** Synthesis is done and utilisation is known (see Status),
   but nothing has run on a real part. Real throughput is unmeasured.
2. **Timing is unverified, and the reason is in the report.** `timing_summary.rpt`
   states *"There are no user specified timing constraints"* — WNS and TNS come back
   as NA. The design was synthesized without an XDC clock constraint, so the maximum
   frequency it can actually close at is unknown. Writing proper constraints and
   re-running synthesis is a small job and should be done before any board work.
3. **The TRNG's entropy has never been measured.** This is the most important gap.
   A ring-oscillator TRNG's whole value is physical randomness; simulating it proves
   nothing, because a simulated oscillator is deterministic. Running it on real
   silicon and putting the output through NIST SP 800-22 or dieharder is the first
   thing that should happen to this design.
4. **The side-channel countermeasures are untested against real attacks.** Masking,
   dummy operations, and jitter injection are implemented, but no power traces have
   ever been captured. A countermeasure that has not faced an oscilloscope is a
   hypothesis.
5. **The PolarFire half was never built.** Only the Artix-7 side has RTL. The
   supervisory device exists in the design documents.
6. **The AES core is not a certified implementation.** It passes known-answer tests
   against NIST vectors in simulation. That is correctness, not certification.
7. **The Rust post-quantum crates wrap reference implementations** and have not been
   independently audited.

---

## What would move this forward

Two things, in order.

**Write the timing constraints.** The design synthesizes but has no XDC clock
constraint, so its maximum frequency is unknown. This costs nothing but time and
turns an NA in the report into a number.

**Then get a development board.** An Artix-7 board carrying the XC7A100T — the same
part this design already synthesizes for, at 6.5% utilisation — costs a few hundred
dollars, not the price of a custom dual-FPGA board. That closes the two gaps that
matter most: measuring the TRNG's actual entropy against NIST SP 800-22, and
capturing power traces to find out whether the masking and jitter countermeasures
do anything real.

---

## License

MIT — see [LICENSE](LICENSE).
