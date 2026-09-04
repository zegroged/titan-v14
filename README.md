# TITAN V14

> An FPGA-based hardware security module: custom AES-256 with a masked S-box, ring-oscillator TRNG, and side-channel countermeasures in VHDL — verified with PSL assertions and attacked with simulated CPA — paired with a post-quantum cryptography stack in Rust.

**Turkish README:** [README.tr.md](README.tr.md)

[![tests](https://github.com/zegroged/titan-v14/actions/workflows/test.yml/badge.svg)](https://github.com/zegroged/titan-v14/actions/workflows/test.yml)
![VHDL](https://img.shields.io/badge/VHDL-174%20files-blue)
![Rust](https://img.shields.io/badge/Rust-11%20crates-orange)
![Target](https://img.shields.io/badge/Target-Artix--7%20XC7A100T%20%2B%20PolarFire-lightgrey)
![Tests](https://img.shields.io/badge/GHDL-13%2F13%20pass%2C%20100%25%20coverage-brightgreen)
![Formal](https://img.shields.io/badge/PSL%20assertions-6%2F6%20pass-brightgreen)
![CPA](https://img.shields.io/badge/CPA%20attack-defended%20(sim)-brightgreen)
![Synthesis](https://img.shields.io/badge/Vivado-synthesized%2C%206.5%25%20of%20XC7A100T-brightgreen)
![Status](https://img.shields.io/badge/Status-never%20fabricated-yellow)
![License](https://img.shields.io/badge/License-MIT-blue)

---

**How this was built:** the code was written with AI assistance and reviewed by the author.

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

### Verification

Everything below is simulation-level, but it goes further than "the testbenches pass."
All reports are in [`titan_v14/reports/`](titan_v14/reports/).

| Report | What was done | Result |
| --- | --- | --- |
| [CPA attack](titan_v14/reports/CPA_ATTACK_REPORT.md) | Correlation power analysis against `aes256_core` byte 0 — 256 traces, Hamming-weight leakage model on the S-box output, run at five noise levels (σ = 0 … 4) | The attack recovered the wrong key byte at every noise level. Masking held. |
| [Formal verification](titan_v14/reports/FORMAL_VERIFICATION_REPORT.md) | PSL assertions over the 17-state AES FSM: fault stickiness, kill-zeroes, no-output-under-fault, FSM validity, spurious-start survival, bounded completion | 6/6 pass; completion bounded at 258 cycles against a 500-cycle limit |
| [Second-order masking](titan_v14/reports/SECOND_ORDER_MASKING_REPORT.md) | DRBG-to-mask bridge, mask independence measured by Hamming weight, mask dynamism across encryptions | Seeding, independence, and dynamism pass; two NIST-vector tests fail *by construction* because a dynamic mask cannot match a fixed vector — documented as expected |
| [TRNG entropy](titan_v14/reports/TRNG_ENTROPY_REPORT.md) | NIST SP 800-90B (simplified) over 131,072 simulated bits | 2/6 pass — **and that is the correct outcome**, see below |
| [Functional coverage](titan_v14/reports/GHDL_COVERAGE_REPORT.md) | GHDL 5.1.1, VHDL-2008 | 13/13 testbenches, 100% of declared scenarios exercised |

The TRNG result is worth reading in full, because a failing entropy test looks alarming
until you see why: GHDL cannot model the physical jitter of a ring oscillator. In
simulation the three ring oscillators run at exactly their nominal frequencies, so the
output is deterministic and the monobit, runs, chi-square, and min-entropy tests fail
by construction. Serial correlation and autocorrelation — the two tests that measure
structure rather than randomness — pass at r = 0.000000. The report says this plainly
rather than hiding the failures.

The CPA report carries the same kind of note: glitch-based leakage does not exist in a
functional simulation, so a defended result there does not prove a defended result on
silicon.

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
2. **Timing has not been closed, but the constraints exist.** The reports in this
   repository come from *out-of-context* synthesis runs, which is why
   `timing_summary.rpt` says *"There are no user specified timing constraints"* and
   returns NA for WNS and TNS. The real constraints are written —
   `rtl/artix7/master_constraints.xdc` declares a 50 MHz system clock — and
   `scripts/build_artix7.tcl` loads them, but that full in-context build was never
   run to completion. Running it is the cheapest remaining task in this project and
   would produce the one number missing from the Status table: the frequency the
   design actually closes at.
3. **The TRNG's entropy has been tested, but only where testing cannot work.** The
   NIST SP 800-90B run over 131,072 simulated bits is in the repository, and four of
   its six tests fail because a simulated ring oscillator has no physical jitter. This
   is the single most important remaining gap: a ring-oscillator TRNG's whole value is
   physical randomness, and it can only be measured on silicon.
4. **The side-channel countermeasures survived a simulated attack, not a real one.**
   The CPA run against the AES core failed to recover the key at any noise level, which
   is evidence that the masking is doing something. But functional simulation contains
   no glitch leakage, no EM emission, and no measurement noise from a real probe. Until
   power traces are captured off a board, the countermeasures are supported by
   simulation rather than proven against hardware.
5. **The PolarFire half was never built.** Only the Artix-7 side has RTL. The
   supervisory device exists in the design documents.
6. **The AES core is not a certified implementation.** It passes known-answer tests
   against NIST vectors in simulation. That is correctness, not certification.
7. **The Rust post-quantum crates wrap reference implementations** and have not been
   independently audited.

---

## What would move this forward

Two things, in order.

**Run the full in-context build.** `scripts/build_artix7.tcl` already loads
`master_constraints.xdc` with its 50 MHz clock and already calls
`report_timing_summary`. Running it to completion costs a Vivado session and turns
the NA in the timing report into a real WNS figure.

**Then get a development board.** An Artix-7 board carrying the XC7A100T — the same
part this design already synthesizes for, at 6.5% utilisation — costs a few hundred
dollars, not the price of a custom dual-FPGA board. That closes the two gaps that
simulation structurally cannot: measuring the TRNG's real entropy against
NIST SP 800-90B on physical jitter, and capturing power traces to test the masking
against glitch leakage that no functional simulator produces.

---

## License

MIT — see [LICENSE](LICENSE).
