# TITAN V14 — GHDL Functional Coverage Report
**Date**: 2026-02-25  
**Tool**: GHDL 5.1.1 (mcode backend)  
**Standard**: VHDL-2008

---

## Executive Summary

| Metric | Value |
|--------|-------|
| Total Test Benches | 13 |
| PASS | **13** |
| FAIL | 0 |
| SKIP | 0 |
| Functional Coverage | **100%** (all declared test scenarios exercised) |

> [!NOTE]
> GHDL mcode backend does not support native line/branch coverage instrumentation (`--coverage` flag requires LLVM backend). This report provides **functional coverage** based on test scenario completion.

---

## Module-Level Functional Coverage

| # | Module | Test Bench | Tests | Result |
|---|--------|-----------|-------|--------|
| 1 | Tanh LUT ROM | `tb_tanh_lut_rom` | LUT read, boundary values | ✅ PASS |
| 2 | Shift-Add Multiplier | `tb_shift_add_multiplier` | Multiply correctness, overflow | ✅ PASS |
| 3 | Chaotic PRNG | `tb_chaotic_prng` | Seed load, entropy distribution | ✅ PASS |
| 4 | Ring Oscillator Counter | `tb_ring_osc_counter` | Freq count, alarm threshold | ✅ PASS |
| 5 | ESN Reservoir Core | `tb_esn_reservoir` | Reservoir state propagation | ✅ PASS |
| 6 | ESN Readout Layer | `tb_esn_readout` | Weight multiplication, output | ✅ PASS |
| 7 | Anomaly Detector | `tb_anomaly_detector` | Threshold, IRQ generation | ✅ PASS |
| 8 | PVT Monitor | `tb_pvt_monitor` | Multi-sensor, alarm, AXI-St output | ✅ PASS |
| 9 | Dummy Op Injector | `tb_dummy_op_injector` | Stall insertion, count tracking | ✅ PASS |
| 10 | Clock Jitter Injector | `tb_clock_jitter` | Phase shift, MMCM lock | ✅ PASS |
| 11 | Omega Cloak Top | `tb_omega_cloak` | Full DPA pipeline, enable/disable | ✅ PASS |
| 12 | AEGIS Top | `tb_aegis_top` | E2E: normal→anomaly→backpressure→clear | ✅ PASS |
| 13 | Artix-7 Top V14 | `tb_artix7_top_v14` | Boot, armed, omega, kill, PVT, AEGIS, full-op | ✅ PASS |

---

## Coverage Gaps & Recommendations

| Gap | Severity | Recommendation |
|-----|----------|----------------|
| No line/branch coverage metrics | Medium | Migrate to GHDL LLVM backend or use commercial simulator (VCS/Questa) for structural coverage |
| SPI command slave (`spi_cmd_slave`) not individually tested in GHDL | Low | Add `tb_spi_cmd_slave.vhd` to GHDL suite |
| `comm_protocol` only tested via integration (`tb_artix7_top_v14`) | Low | Create standalone `tb_comm_protocol.vhd` |
| TRNG ring oscillator uses behavioral model in simulation | Info | Hardware validation required on actual FPGA |

---

## Conclusion

All 13 declared test scenarios exercise the full TITAN V14 module hierarchy from leaf components (LUT ROM, multiplier) through mid-level subsystems (ESN, PVT, Omega Cloak) to the top-level integration (`artix7_top_v14`). **Functional coverage is 100%**.

For structural (line/branch) coverage, migration to GHDL's LLVM backend or a commercial EDA tool is recommended.
