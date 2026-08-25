#!/usr/bin/env python3
"""
AEGIS Vivado xsim Test Runner
Runs all AEGIS VHDL testbenches using Vivado's xsim simulator.
Uses real Xilinx UNISIM primitives (no behavioral stubs needed).
"""

import subprocess
import sys
import os
import time
import re
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional

# ===========================================================================
# Configuration
# ===========================================================================
VIVADO_BIN = Path(r"C:\AMDDesignTools\2025.2\Vivado\bin")
XVHDL  = str(VIVADO_BIN / "xvhdl.bat")
XELAB  = str(VIVADO_BIN / "xelab.bat")
XSIM   = str(VIVADO_BIN / "xsim.bat")

# Project paths
SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent.parent
AEGIS_DIR   = PROJECT_DIR / "rtl" / "aegis"
SIM_STUBS_DIR = PROJECT_DIR / "rtl" / "sim_stubs"

# xsim work directory (avoid Turkish i in path)
XSIM_WORK_DIR = Path(r"C:\Temp\aegis_xsim")
XSIM_WORK_DIR.mkdir(parents=True, exist_ok=True)

# CPA script
CPA_SCRIPT = SCRIPT_DIR / "cpa_omega_analysis.py"

# ===========================================================================
# Test Definitions
# ===========================================================================
@dataclass
class TestModule:
    name: str
    display_name: str
    phase: str
    sources: list
    testbench: str
    stop_time: str
    use_unisim: bool = False       # True = compile with -L unisim
    golden_ref: Optional[str] = None
    description: str = ""

@dataclass
class TestResult:
    module: str
    display_name: str
    phase: str
    status: str
    pass_count: int = 0
    fail_count: int = 0
    duration_s: float = 0.0
    error_msg: str = ""
    sim_output: str = ""

def get_test_registry():
    """All AEGIS test modules for xsim."""
    return [
        TestModule(
            name="prng",
            display_name="Dual Chaotic PRNG",
            phase="3.1",
            sources=[
                str(AEGIS_DIR / "chaotic_prng.vhd"),
                str(AEGIS_DIR / "tb_chaotic_prng.vhd"),
            ],
            testbench="tb_chaotic_prng",
            stop_time="500us",
            description="Q8.24 dual logistic map + XOR mixing"
        ),
        TestModule(
            name="jitter",
            display_name="Clock Jitter Injector",
            phase="3.2",
            sources=[
                str(AEGIS_DIR / "clock_jitter_injector.vhd"),
                str(AEGIS_DIR / "tb_clock_jitter.vhd"),
            ],
            testbench="tb_clock_jitter",
            stop_time="200us",
            use_unisim=True,
            description="MMCM dynamic phase shift jitter"
        ),
        TestModule(
            name="dummy",
            display_name="Dummy Operation Injector",
            phase="3.3",
            sources=[
                str(AEGIS_DIR / "dummy_op_injector.vhd"),
                str(AEGIS_DIR / "tb_dummy_op_injector.vhd"),
            ],
            testbench="tb_dummy_op_injector",
            stop_time="100us",
            description="Shadow AES round + dummy ops"
        ),
        TestModule(
            name="omega",
            display_name="Omega Cloak Top",
            phase="3.4",
            sources=[
                str(AEGIS_DIR / "chaotic_prng.vhd"),
                str(AEGIS_DIR / "clock_jitter_injector.vhd"),
                str(AEGIS_DIR / "dummy_op_injector.vhd"),
                str(AEGIS_DIR / "omega_cloak_top.vhd"),
                str(AEGIS_DIR / "tb_omega_cloak.vhd"),
            ],
            testbench="tb_omega_cloak",
            stop_time="200us",
            use_unisim=True,
            description="Integrated PRNG + Jitter + Dummy"
        ),
        TestModule(
            name="ring_osc",
            display_name="Ring Osc Freq Counter",
            phase="4.1",
            sources=[
                str(AEGIS_DIR / "ring_osc_counter.vhd"),
                str(AEGIS_DIR / "tb_ring_osc_counter.vhd"),
            ],
            testbench="tb_ring_osc_counter",
            stop_time="20ms",
            description="CDC sync + edge count + alarm"
        ),
        TestModule(
            name="pvt",
            display_name="PVT Monitor Top",
            phase="4.2",
            sources=[
                str(AEGIS_DIR / "ring_osc_counter.vhd"),
                str(AEGIS_DIR / "pvt_monitor_top.vhd"),
                str(AEGIS_DIR / "tb_pvt_monitor.vhd"),
            ],
            testbench="tb_pvt_monitor",
            stop_time="30ms",
            description="4-sensor averaging + Q8.8 + AXI"
        ),
        TestModule(
            name="cpa",
            display_name="CPA Omega Analysis",
            phase="3.4+",
            sources=[],
            testbench="",
            stop_time="",
            golden_ref=str(CPA_SCRIPT),
            description="50K trace CPA attack simulation"
        ),
    ]


# ===========================================================================
# Result Parser — handles both xsim and GHDL output formats
# ===========================================================================
# xsim uses: Note:   PASS: some message
# GHDL uses: (report note): PASS: some message
XSIM_REPORT_RE = re.compile(
    r'(?:Note|Warning|Error|Failure):\s+(.*)',
    re.IGNORECASE
)
GHDL_REPORT_RE = re.compile(
    r'\(report\s+(?:note|error)\):\s*(.*)',
    re.IGNORECASE
)

def parse_results(output: str) -> tuple:
    """Parse PASS/FAIL from simulation output."""
    pc, fc = 0, 0
    seen = set()  # Deduplicate lines (log + stdout may repeat)
    for line in output.splitlines():
        # Try xsim format first, then GHDL
        m = XSIM_REPORT_RE.search(line)
        if not m:
            m = GHDL_REPORT_RE.search(line)
        if not m:
            continue
        msg = m.group(1).strip()
        # Skip header/separator lines
        if msg.startswith("===") or msg.startswith("ALL TESTS"):
            continue
        if msg.startswith("CLOCK JITTER") or msg.startswith("RING OSC"):
            continue
        if msg.startswith("DUAL CHAOTIC") or msg.startswith("DUMMY OP"):
            continue
        if msg.startswith("OMEGA CLOAK") or msg.startswith("PVT MONITOR"):
            continue
        if msg.startswith("CPA OMEGA"):
            continue
        # Skip numeric summary lines: "PASS: 7", "FAIL: 0", "TEST 1:"
        if re.match(r'^(?:PASS|FAIL):\s*\d+\s*$', msg):
            continue
        if re.match(r'^TEST\s+\d+', msg):
            continue
        # Skip phase accumulator report
        if "Phase accumulator" in msg:
            continue
        # Deduplicate
        if msg in seen:
            continue
        seen.add(msg)
        # Count
        if re.search(r'\bPASS\b', msg) and not re.search(r'\bFAIL\b', msg):
            pc += 1
        elif re.search(r'\bFAIL\b', msg):
            fc += 1
    return pc, fc


# ===========================================================================
# xsim Runner
# ===========================================================================
def run_cmd(args, cwd=None, timeout=600):
    """Run a command and return (returncode, stdout+stderr)."""
    try:
        r = subprocess.run(
            args,
            capture_output=True,
            text=True,
            encoding='utf-8',
            errors='replace',
            cwd=cwd or str(XSIM_WORK_DIR),
            timeout=timeout
        )
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT"
    except Exception as e:
        return -1, str(e)


def run_xsim_test(mod: TestModule, verbose: bool = False) -> TestResult:
    """Run a single test module through xvhdl -> xelab -> xsim."""
    t0 = time.time()

    # Special case: Python-only test (CPA)
    if not mod.sources and mod.golden_ref:
        rc, out = run_cmd([sys.executable, mod.golden_ref], cwd=str(SCRIPT_DIR))
        dt = time.time() - t0
        pc, fc = 0, 0
        if "PASS" in out:
            pc = out.count("PASS")
        if "FAIL" in out and rc != 0:
            fc = 1
        status = "PASS" if rc == 0 else "FAIL"
        return TestResult(mod.name, mod.display_name, mod.phase, status,
                          pc, fc, dt, sim_output=out)

    # Work subdirectory per module -- clean first to avoid stale locks
    mod_dir = XSIM_WORK_DIR / mod.name
    if mod_dir.exists():
        import shutil
        try:
            shutil.rmtree(str(mod_dir))
        except Exception:
            pass  # Best effort clean
    mod_dir.mkdir(parents=True, exist_ok=True)

    # 1. Analyze (xvhdl)
    for src in mod.sources:
        cmd = [XVHDL, "--2008", "--work", "work", "--relax", src]
        rc, out = run_cmd(cmd, cwd=str(mod_dir))
        if rc != 0:
            dt = time.time() - t0
            return TestResult(mod.name, mod.display_name, mod.phase, "ERROR",
                              error_msg=f"xvhdl failed: {out}", duration_s=dt)

    # 2. Elaborate (xelab) -- no --2008 here, standard set during xvhdl
    elab_cmd = [XELAB, "--relax",
                "--debug", "off",
                "-s", f"{mod.name}_sim"]
    if mod.use_unisim:
        elab_cmd.extend(["-L", "unisim"])
    elab_cmd.append(f"work.{mod.testbench}")
    rc, out = run_cmd(elab_cmd, cwd=str(mod_dir))
    if rc != 0:
        dt = time.time() - t0
        return TestResult(mod.name, mod.display_name, mod.phase, "ERROR",
                          error_msg=f"xelab failed: {out}", duration_s=dt)

    # 3. Create TCL batch file for xsim with explicit run time + quit
    tcl_file = mod_dir / "run.tcl"
    tcl_file.write_text(f"run {mod.stop_time}\nquit\n")

    # Convert path to forward slashes (TCL interprets backslash escapes)
    tcl_path = str(tcl_file).replace("\\", "/")

    # 4. Simulate (xsim) -- tclbatch mode for controlled termination
    #    (--runall hangs because behavioral clock generators use infinite loops)
    sim_cmd = [XSIM, f"{mod.name}_sim",
               "--tclbatch", tcl_path,
               "--onerror", "quit",
               "--log", f"{mod.name}_sim.log"]
    rc, out = run_cmd(sim_cmd, cwd=str(mod_dir), timeout=600)
    dt = time.time() - t0

    # Also read the log file for full output
    log_file = mod_dir / f"{mod.name}_sim.log"
    if log_file.exists():
        log_content = log_file.read_text(encoding='utf-8', errors='replace')
        out = log_content + "\n" + out

    # Parse results
    pc, fc = parse_results(out)
    status = "PASS" if fc == 0 and pc > 0 else ("FAIL" if fc > 0 else "ERROR")

    return TestResult(mod.name, mod.display_name, mod.phase, status,
                      pc, fc, dt, sim_output=out)


# ===========================================================================
# Main
# ===========================================================================
def main():
    verbose = "--verbose" in sys.argv or "-v" in sys.argv

    registry = get_test_registry()

    print()
    print("=" * 60)
    print("  AEGIS Vivado xsim Test Suite")
    print(f"  Vivado: {VIVADO_BIN}")
    print(f"  Work Directory: {XSIM_WORK_DIR}")
    print(f"  Modules: {len(registry)}")
    print("=" * 60)
    print()

    # Copy PRNG golden vectors if needed
    csv_src = AEGIS_DIR / "test_vectors_prng.csv"
    csv_dst_prng = XSIM_WORK_DIR / "prng" / "test_vectors_prng.csv"
    if csv_src.exists():
        csv_dst_prng.parent.mkdir(parents=True, exist_ok=True)
        import shutil
        shutil.copy2(str(csv_src), str(csv_dst_prng))

    results = []
    for mod in registry:
        label = f"[{mod.phase}] {mod.display_name}"
        print(f"  {label}... ", end="", flush=True)

        result = run_xsim_test(mod, verbose)
        results.append(result)

        if result.status == "PASS":
            print(f"PASS ({result.pass_count}P/{result.fail_count}F)")
        elif result.status == "FAIL":
            print(f"FAIL ({result.pass_count}P/{result.fail_count}F)")
        elif result.status == "ERROR":
            print(f"ERROR")
        print()

    # Summary table
    print()
    print("=" * 86)
    print("  AEGIS VIVADO xsim REPORT")
    print("=" * 86)
    print()
    print(f"  {'Phase':<7} {'Module':<28} {'Status':<12} {'Pass':>4} {'Fail':>4} {'Time':>8}")
    print(f"  {'-'*82}")

    total_pass, total_fail = 0, 0
    fail_modules = []
    for r in results:
        total_pass += r.pass_count
        total_fail += r.fail_count
        st = "[OK] PASS" if r.status == "PASS" else ("[!!] FAIL" if r.status == "FAIL" else "[XX] ERR ")
        print(f"  {r.phase:<7} {r.display_name:<28} {st:<12} {r.pass_count:>4} {r.fail_count:>4} {r.duration_s:>7.1f}s")
        if r.status != "PASS":
            fail_modules.append(r)

    print(f"  {'-'*82}")
    print(f"  TOTALS: {total_pass} passed, {total_fail} failed, {len(fail_modules)} modules with errors")
    print()

    if not fail_modules:
        print("  +======================================+")
        print("  |  ALL TESTS PASSED -- SYSTEM VERIFIED |")
        print("  +======================================+")
    else:
        print(f"  +======================================+")
        print(f"  |  {len(fail_modules)} MODULE(S) NEED ATTENTION        |")
        print(f"  +======================================+")

    print()

    # Show failures in verbose mode
    if fail_modules:
        for r in fail_modules:
            print(f"\n{'='*60}")
            print(f"  FAILURE: {r.display_name} (Phase {r.phase})")
            print(f"{'='*60}")
            if r.error_msg:
                print(f"  Error: {r.error_msg[:500]}")
            if verbose and r.sim_output:
                for line in r.sim_output.splitlines():
                    if "PASS" in line or "FAIL" in line or "report" in line.lower():
                        print(f"  | {line}")
            print()


if __name__ == "__main__":
    main()
