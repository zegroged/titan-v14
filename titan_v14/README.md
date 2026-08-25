# PROJECT TITAN V14 — AEGIS Security Framework

**Sovereign Secure Communication Terminal | Xilinx Artix-7 XC7A100T**

---

## Overview

TITAN V14 is a dual-FPGA lockstep architecture with integrated side-channel protection. AEGIS adds four countermeasure layers against DPA/SPA attacks, physical tampering, and environmental manipulation.

**Key Result**: CPA correlation reduced from **0.916 to 0.011** (98.8%) across 50,000 traces.

For full technical details, see [AEGIS_BENCHMARK_REPORT.md](AEGIS_BENCHMARK_REPORT.md).

---

## Architecture

```
TITAN V14 = V13 Base + AEGIS Security Subsystem

V13 Base:  MMCM | Supervisor | SPI Key | AES-256-CTR | UART Pipeline | Watchdog
AEGIS:     Omega Cloak (PRNG + Jitter + Dummy) | PVT Monitor (4x Ring Osc) | AI Engine
Kill Chain: KILL_PIN | PF_WDT | AEGIS_IRQ | PVT_ALARM -> OR -> Zeroization
```

## Quick Start

```bash
# List all test modules
python scripts/aegis/cosim_framework.py --list

# Run all verification tests
python scripts/aegis/cosim_framework.py --run-all

# Run CPA attack simulation
python scripts/aegis/cpa_omega_analysis.py
```

## File Structure

```
titan_v14/
  rtl/
    aegis/           # AEGIS security modules (13 VHDL)
    artix7/          # Top module (V14) + constraints
    common/          # V14 base modules (AES, SHA, UART, Kill, TRNG, SEU, SVN)
    polarfire/       # PolarFire auditor
  tb/                # 17 GHDL regression tests (all PASS)
  sw/
    callwhite_mcu/   # STM32L4 C firmware (49 modules)
  scripts/
    aegis/           # Python verification (co-sim, CPA, PRNG golden ref)
  AEGIS_BENCHMARK_REPORT.md   # Full technical report
```

## Resource Utilization

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| LUT | ~3,500 | 63,400 | 5.5% |
| FF | ~2,500 | 126,800 | 2.0% |
| MMCM | 2 | 6 | 33% |
| DSP | 0 | 240 | 0% |

## License

Proprietary. Distribution restricted.

**Copyright 2026 PROJECT TITAN**
