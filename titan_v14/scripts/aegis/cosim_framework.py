#!/usr/bin/env python3
"""
================================================================================
AEGIS Co-Simulation Framework — GHDL + Python Golden Reference
================================================================================
Automates the full VHDL verification pipeline:
  1. Compile all VHDL sources with GHDL
  2. Run each testbench as subprocess
  3. Parse GHDL output for PASS/FAIL assertions
  4. Compare outputs against Python golden references
  5. Generate VCD/GHW waveforms for debugging
  6. Produce tabular report

Usage:
  python cosim_framework.py --run-all        # Run everything
  python cosim_framework.py --module prng    # Single module
  python cosim_framework.py --list           # List available tests
  python cosim_framework.py --report-only    # Reparse last results
  python cosim_framework.py --ci             # CI mode (exit code = fail count)

Author: AEGIS Project — TITAN V14
================================================================================
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional


# ===========================================================================
# Configuration
# ===========================================================================

# Project root (relative to this script)
SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent.parent  # titan_v13/
RTL_DIR = PROJECT_ROOT / "rtl"
AEGIS_DIR = RTL_DIR / "aegis"
ARTIX_DIR = RTL_DIR / "artix7"
SIM_STUBS_DIR = RTL_DIR / "sim_stubs"
SCRIPTS_DIR = PROJECT_ROOT / "scripts" / "aegis"

# GHDL configuration
GHDL_BIN = "ghdl"
GHDL_STD = "08"
# Use a path without Turkish İ for GHDL work/output (GHDL uses Latin-1 for paths)
GHDL_WORK_DIR = Path("C:/Temp/aegis_cosim/work")
GHDL_WAVE_DIR = Path("C:/Temp/aegis_cosim/waves")

# Results directory (text/JSON reports go here, in project dir)
RESULTS_DIR = SCRIPT_DIR / "cosim_results"
WAVEFORM_DIR = GHDL_WAVE_DIR  # Alias for wave output


# ===========================================================================
# Data Structures
# ===========================================================================

@dataclass
class TestModule:
    """Defines a single testable module."""
    name: str                        # Short name (e.g., "prng")
    display_name: str                # Display name (e.g., "Chaotic PRNG")
    phase: str                       # Phase (e.g., "3.1")
    sources: list                    # VHDL files to compile (order matters!)
    testbench: str                   # Testbench entity name
    stop_time: str                   # Simulation stop time
    golden_ref: Optional[str] = None # Python golden ref script (optional)
    golden_args: list = field(default_factory=list)
    description: str = ""
    wave_format: str = "ghw"         # ghw or vcd


@dataclass
class TestResult:
    """Result of a single test run."""
    module: str
    display_name: str
    phase: str
    status: str          # PASS, FAIL, ERROR, SKIP
    pass_count: int = 0
    fail_count: int = 0
    duration_s: float = 0.0
    error_msg: str = ""
    ghdl_output: str = ""
    wave_file: str = ""


# ===========================================================================
# Test Registry
# ===========================================================================

def get_test_registry() -> list:
    """Returns all registered AEGIS test modules."""
    return [
        # --- Phase 3: Omega Cloak ---
        TestModule(
            name="prng",
            display_name="Dual Chaotic PRNG",
            phase="3.1",
            sources=[str(AEGIS_DIR / "chaotic_prng.vhd"),
                     str(AEGIS_DIR / "tb_chaotic_prng.vhd")],
            testbench="tb_chaotic_prng",
            stop_time="500us",
            golden_ref=str(SCRIPTS_DIR / "generate_prng_vectors.py"),
            description="Q8.24 dual logistic map + XOR mixing + NIST tests"
        ),
        TestModule(
            name="jitter",
            display_name="Clock Jitter Injector",
            phase="3.2",
            sources=[str(SIM_STUBS_DIR / "unisim_pkg.vhd"),
                     str(SIM_STUBS_DIR / "unisim_bufg.vhd"),
                     str(SIM_STUBS_DIR / "unisim_mmcm.vhd"),
                     str(AEGIS_DIR / "clock_jitter_injector.vhd"),
                     str(AEGIS_DIR / "tb_clock_jitter.vhd")],
            testbench="tb_clock_jitter",
            stop_time="200us",
            description="MMCM dynamic phase shift, +/-2ns jitter, bypass mode"
        ),
        TestModule(
            name="dummy",
            display_name="Dummy Operation Injector",
            phase="3.3",
            sources=[str(AEGIS_DIR / "dummy_op_injector.vhd"),
                     str(AEGIS_DIR / "tb_dummy_op_injector.vhd")],
            testbench="tb_dummy_op_injector",
            stop_time="100us",
            description="Shadow AES round, 0-3 dummies, power profile match"
        ),
        TestModule(
            name="omega",
            display_name="Omega Cloak Top",
            phase="3.4",
            sources=[str(SIM_STUBS_DIR / "unisim_pkg.vhd"),
                     str(SIM_STUBS_DIR / "unisim_bufg.vhd"),
                     str(SIM_STUBS_DIR / "unisim_mmcm.vhd"),
                     str(AEGIS_DIR / "chaotic_prng.vhd"),
                     str(AEGIS_DIR / "clock_jitter_injector.vhd"),
                     str(AEGIS_DIR / "dummy_op_injector.vhd"),
                     str(AEGIS_DIR / "omega_cloak_top.vhd"),
                     str(AEGIS_DIR / "tb_omega_cloak.vhd")],
            testbench="tb_omega_cloak",
            stop_time="200us",
            description="Integrated PRNG + Jitter + Dummy master controller"
        ),

        # --- Phase 4: PVT Monitor ---
        TestModule(
            name="ring_osc",
            display_name="Ring Osc Freq Counter",
            phase="4.1",
            sources=[str(AEGIS_DIR / "ring_osc_counter.vhd"),
                     str(AEGIS_DIR / "tb_ring_osc_counter.vhd")],
            testbench="tb_ring_osc_counter",
            stop_time="20ms",
            description="CDC sync + edge count + ±20% alarm"
        ),
        TestModule(
            name="pvt",
            display_name="PVT Monitor Top",
            phase="4.2",
            sources=[str(AEGIS_DIR / "ring_osc_counter.vhd"),
                     str(AEGIS_DIR / "pvt_monitor_top.vhd"),
                     str(AEGIS_DIR / "tb_pvt_monitor.vhd")],
            testbench="tb_pvt_monitor",
            stop_time="30ms",
            description="4-sensor averaging + Q8.8 + AXI + alarm"
        ),

        # --- Phase 5: CPA Analysis (Python only) ---
        TestModule(
            name="cpa",
            display_name="CPA Omega Analysis",
            phase="3.4+",
            sources=[],  # No VHDL — pure Python
            testbench="",
            stop_time="",
            golden_ref=str(SCRIPTS_DIR / "cpa_omega_analysis.py"),
            description="50K trace CPA attack: unprotected vs Omega Cloak"
        ),
    ]


# ===========================================================================
# GHDL Runner
# ===========================================================================

class GHDLRunner:
    """Manages GHDL compilation and simulation."""

    def __init__(self):
        self.work_dir = GHDL_WORK_DIR
        self.work_dir.mkdir(parents=True, exist_ok=True)

    def _run_raw(self, cmd: list, timeout: int = 600) -> subprocess.CompletedProcess:
        """Run an arbitrary command and return result."""
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=str(self.work_dir)
            )
            return result
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(
                cmd, returncode=-1,
                stdout="", stderr="TIMEOUT: Simulation exceeded time limit"
            )
        except FileNotFoundError:
            return subprocess.CompletedProcess(
                cmd, returncode=-2,
                stdout="", stderr=f"GHDL not found: {GHDL_BIN}"
            )

    def analyze(self, source_files: list) -> tuple:
        """Compile VHDL source files. Returns (success, output).
        
        GHDL order: ghdl -a --std=08 --workdir=<dir> [--work=<lib>] <source_file>
        Files in sim_stubs/ are compiled into the 'unisim' library.
        """
        outputs = []
        for src in source_files:
            if not Path(src).exists():
                return False, f"Source not found: {src}"
            # Detect UNISIM stub files -> compile into 'unisim' library
            src_path = Path(src).resolve()
            if "sim_stubs" in str(src_path):
                cmd = [GHDL_BIN, "-a", f"--std={GHDL_STD}", "-frelaxed",
                       f"--workdir={self.work_dir}", "--work=unisim", src]
            else:
                cmd = [GHDL_BIN, "-a", f"--std={GHDL_STD}", "-frelaxed",
                       f"--workdir={self.work_dir}", src]
            result = self._run_raw(cmd)
            outputs.append(result.stderr)
            if result.returncode != 0:
                return False, f"Compile error in {Path(src).name}:\n{result.stderr}"
        return True, "\n".join(outputs)

    def elaborate(self, entity: str) -> tuple:
        """Elaborate a testbench entity. Returns (success, output).
        
        GHDL order: ghdl -e --std=08 --workdir=<dir> <entity>
        """
        cmd = [GHDL_BIN, "-e", f"--std={GHDL_STD}", "-frelaxed",
               f"--workdir={self.work_dir}", entity]
        result = self._run_raw(cmd)
        if result.returncode != 0:
            return False, f"Elaboration error: {result.stderr}"
        return True, result.stderr

    def simulate(self, entity: str, stop_time: str,
                 wave_file: Optional[str] = None) -> tuple:
        """Run simulation. Returns (success, stdout+stderr combined).
        
        GHDL order: ghdl -r --std=08 --workdir=<dir> <entity> --stop-time=X [--wave=Y]
        Simulation options (--stop-time, --wave, --vcd) MUST come AFTER entity.
        """
        cmd = [GHDL_BIN, "-r", f"--std={GHDL_STD}", "-frelaxed",
               f"--workdir={self.work_dir}", entity,
               f"--stop-time={stop_time}"]
        if wave_file:
            if wave_file.endswith(".vcd"):
                cmd.append(f"--vcd={wave_file}")
            else:
                cmd.append(f"--wave={wave_file}")

        result = self._run_raw(cmd, timeout=600)
        combined = result.stdout + "\n" + result.stderr
        success = result.returncode == 0
        return success, combined

    def clean(self):
        """Remove work library."""
        self._run_raw([GHDL_BIN, "--clean", f"--workdir={self.work_dir}"])


# ===========================================================================
# Output Parser
# ===========================================================================

class ResultParser:
    """Parses GHDL simulation output for PASS/FAIL counts.
    
    Only counts PASS/FAIL from VHDL report statements (lines with '(report'),
    filtering out:
     - NUMERIC_STD assertion warnings (metavalue detection)
     - Summary lines (PASS: N / FAIL: N) from testbench self-reports
     - GHDL info messages
    """

    # Match VHDL report lines: filename:line:col:@time:(report note/error): message
    REPORT_LINE = re.compile(r"\(report\s+(note|error|warning)\):\s*(.*)", re.IGNORECASE)
    
    # Match testbench summary lines like "PASS: 5" or "FAIL: 0" — skip these
    SUMMARY_LINE = re.compile(r"^\s*(PASS|FAIL):\s*\d+\s*$")

    @staticmethod
    def parse(output: str) -> tuple:
        """Parse output and return (pass_count, fail_count, errors).
        
        Counts individual test results from VHDL report statements.
        Lines with 'PASS:' in the report message count as passes.
        Lines with 'FAIL:' in the report message count as failures.
        Lines with 'assertion failure' or 'ghdl:error' count as errors.
        """
        passes = 0
        fails = 0
        errors = []
        
        for line in output.split('\n'):
            line_stripped = line.strip()
            
            # Skip assertion warnings (NUMERIC_STD metavalue)
            if 'assertion warning' in line_stripped.lower():
                continue
            
            # Skip ghdl info messages  
            if 'ghdl:info' in line_stripped.lower():
                continue
                
            # Check for GHDL errors (fatal)
            if 'ghdl:error' in line_stripped.lower():
                errors.append(line_stripped)
                continue
            if 'assertion failure' in line_stripped.lower():
                errors.append(line_stripped)
                continue
            
            # Parse VHDL report lines
            m = ResultParser.REPORT_LINE.search(line_stripped)
            if m:
                severity = m.group(1).lower()
                message = m.group(2).strip()
                
                # Skip summary lines ("PASS: 5", "FAIL: 0")
                if ResultParser.SUMMARY_LINE.match(message):
                    continue
                
                # Count individual test results
                if 'PASS:' in message or 'PASS ' in message:
                    passes += 1
                elif 'FAIL:' in message or 'FAIL ' in message:
                    fails += 1
                    if severity == 'error':
                        errors.append(message)
        
        return passes, fails, errors


# ===========================================================================
# Golden Reference Runner
# ===========================================================================

class GoldenRefRunner:
    """Runs Python golden reference scripts."""

    @staticmethod
    def run(script_path: str, args: list = None) -> tuple:
        """Run a Python golden ref script. Returns (success, output)."""
        if not Path(script_path).exists():
            return False, f"Golden ref not found: {script_path}"

        cmd = [sys.executable, script_path] + (args or [])
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=300,
                cwd=str(Path(script_path).parent)
            )
            combined = result.stdout + "\n" + result.stderr
            return result.returncode == 0, combined
        except subprocess.TimeoutExpired:
            return False, "TIMEOUT: Golden reference exceeded time limit"


# ===========================================================================
# Report Generator
# ===========================================================================

class ReportGenerator:
    """Generates formatted test reports."""

    @staticmethod
    def table(results: list) -> str:
        """Generate ASCII table report."""
        lines = []
        lines.append("")
        lines.append("=" * 86)
        lines.append("  AEGIS CO-SIMULATION REPORT")
        lines.append(f"  Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        lines.append("=" * 86)
        lines.append("")

        # Header
        hdr = f"  {'Phase':<6} {'Module':<26} {'Status':<8} {'Pass':>4} {'Fail':>4} {'Time':>8}  Wave"
        lines.append(hdr)
        lines.append("  " + "-" * 82)

        total_pass = 0
        total_fail = 0
        total_error = 0

        for r in results:
            status_icon = {
                "PASS": "[OK]",
                "FAIL": "[!!]",
                "ERROR": "[??]",
                "SKIP": "[--]"
            }.get(r.status, "[??]")

            wave_name = Path(r.wave_file).name if r.wave_file else "-"
            row = (f"  {r.phase:<6} {r.display_name:<26} "
                   f"{status_icon} {r.status:<4} "
                   f"{r.pass_count:>4} {r.fail_count:>4} "
                   f"{r.duration_s:>7.1f}s  {wave_name}")
            lines.append(row)

            total_pass += r.pass_count
            total_fail += r.fail_count
            if r.status in ("FAIL", "ERROR"):
                total_error += 1

        lines.append("  " + "-" * 82)
        lines.append(f"  TOTALS: {total_pass} passed, {total_fail} failed, "
                     f"{total_error} modules with errors")
        lines.append("")

        if total_fail == 0 and total_error == 0:
            lines.append("  +======================================+")
            lines.append("  |  ALL TESTS PASSED -- SYSTEM VERIFIED |")
            lines.append("  +======================================+")
        else:
            lines.append("  +======================================+")
            lines.append(f"  |  {total_error} MODULE(S) NEED ATTENTION        |")
            lines.append("  +======================================+")

        lines.append("")
        return "\n".join(lines)

    @staticmethod
    def json_report(results: list) -> dict:
        """Generate JSON report for CI/CD."""
        return {
            "timestamp": datetime.now().isoformat(),
            "framework": "AEGIS Co-Simulation",
            "ghdl_std": GHDL_STD,
            "tests": [
                {
                    "module": r.module,
                    "name": r.display_name,
                    "phase": r.phase,
                    "status": r.status,
                    "passed": r.pass_count,
                    "failed": r.fail_count,
                    "duration_s": round(r.duration_s, 2),
                    "error": r.error_msg,
                    "waveform": r.wave_file
                }
                for r in results
            ],
            "summary": {
                "total_modules": len(results),
                "passed_modules": sum(1 for r in results if r.status == "PASS"),
                "failed_modules": sum(1 for r in results if r.status in ("FAIL", "ERROR")),
                "total_assertions_pass": sum(r.pass_count for r in results),
                "total_assertions_fail": sum(r.fail_count for r in results),
            }
        }

    @staticmethod
    def failure_details(results: list) -> str:
        """Generate detailed failure report."""
        lines = []
        for r in results:
            if r.status in ("FAIL", "ERROR"):
                lines.append(f"\n{'='*60}")
                lines.append(f"  FAILURE: {r.display_name} (Phase {r.phase})")
                lines.append(f"{'='*60}")
                if r.error_msg:
                    lines.append(f"  Error: {r.error_msg}")
                # Show last 30 lines of GHDL output
                out_lines = r.ghdl_output.strip().split("\n")
                tail = out_lines[-30:] if len(out_lines) > 30 else out_lines
                for l in tail:
                    lines.append(f"  | {l}")
                if r.wave_file:
                    lines.append(f"  Waveform: {r.wave_file}")
        return "\n".join(lines) if lines else ""


# ===========================================================================
# Test Runner (Orchestrator)
# ===========================================================================

class CoSimRunner:
    """Main orchestrator: compile, simulate, compare, report."""

    def __init__(self, verbose: bool = False):
        self.ghdl = GHDLRunner()
        self.golden = GoldenRefRunner()
        self.parser = ResultParser()
        self.reporter = ReportGenerator()
        self.verbose = verbose
        self.results: list = []

        # Create output directories
        RESULTS_DIR.mkdir(parents=True, exist_ok=True)
        WAVEFORM_DIR.mkdir(parents=True, exist_ok=True)

    def run_module(self, module: TestModule) -> TestResult:
        """Run a single module test (compile + simulate + compare)."""
        print(f"\n  [{module.phase}] {module.display_name}...", end=" ", flush=True)
        t0 = time.time()

        # --- Pure Python test (no VHDL) ---
        if not module.sources and module.golden_ref:
            return self._run_python_only(module, t0)

        # --- VHDL test ---
        wave_file = str(WAVEFORM_DIR / f"{module.name}_sim.{module.wave_format}")

        # Step 1: Compile
        ok, output = self.ghdl.analyze(module.sources)
        if not ok:
            print("COMPILE ERROR")
            return TestResult(
                module=module.name, display_name=module.display_name,
                phase=module.phase, status="ERROR",
                error_msg=output, duration_s=time.time() - t0
            )

        # Step 2: Elaborate
        ok, output = self.ghdl.elaborate(module.testbench)
        if not ok:
            print("ELABORATION ERROR")
            return TestResult(
                module=module.name, display_name=module.display_name,
                phase=module.phase, status="ERROR",
                error_msg=output, duration_s=time.time() - t0
            )

        # Step 3: Simulate
        ok, sim_output = self.ghdl.simulate(
            module.testbench, module.stop_time, wave_file
        )
        passes, fails, errors = self.parser.parse(sim_output)

        # Step 4: Golden reference (if available)
        golden_output = ""
        if module.golden_ref:
            gok, golden_output = self.golden.run(
                module.golden_ref, module.golden_args
            )
            if not gok:
                fails += 1
                sim_output += f"\n[Golden Ref FAILED]\n{golden_output}"

        # Determine status
        if not ok or fails > 0:
            status = "FAIL"
            print(f"FAIL ({passes}P/{fails}F)")
        elif passes == 0 and fails == 0:
            status = "PASS"  # No assertions but no errors
            print(f"PASS (no assertions)")
        else:
            status = "PASS"
            print(f"PASS ({passes}P/{fails}F)")

        duration = time.time() - t0
        return TestResult(
            module=module.name, display_name=module.display_name,
            phase=module.phase, status=status,
            pass_count=passes, fail_count=fails,
            duration_s=duration, ghdl_output=sim_output,
            wave_file=wave_file if Path(wave_file).exists() else ""
        )

    def _run_python_only(self, module: TestModule, t0: float) -> TestResult:
        """Run a Python-only test module."""
        ok, output = self.golden.run(module.golden_ref, module.golden_args)
        passes, fails, _ = self.parser.parse(output)
        duration = time.time() - t0

        # For CPA: look for "EFFECTIVE" keyword
        if "EFFECTIVE" in output:
            passes += 1
        if "NOT recoverable" in output:
            passes += 1

        status = "PASS" if ok and fails == 0 else "FAIL"
        icon = status
        print(f"{icon} ({passes}P/{fails}F, {duration:.1f}s)")

        return TestResult(
            module=module.name, display_name=module.display_name,
            phase=module.phase, status=status,
            pass_count=passes, fail_count=fails,
            duration_s=duration, ghdl_output=output
        )

    def run_all(self, filter_name: str = None) -> list:
        """Run all (or filtered) tests."""
        registry = get_test_registry()

        if filter_name:
            registry = [m for m in registry
                        if filter_name.lower() in m.name.lower()]
            if not registry:
                print(f"  No module matching '{filter_name}'")
                return []

        print("\n" + "=" * 60)
        print("  AEGIS Co-Simulation Framework")
        print(f"  GHDL Standard: VHDL-{GHDL_STD}")
        print(f"  Work Directory: {GHDL_WORK_DIR}")
        print(f"  Modules: {len(registry)}")
        print("=" * 60)

        # Clean work directory for fresh build
        self.ghdl.clean()
        GHDL_WORK_DIR.mkdir(parents=True, exist_ok=True)

        self.results = []
        for module in registry:
            try:
                result = self.run_module(module)
            except Exception as e:
                result = TestResult(
                    module=module.name, display_name=module.display_name,
                    phase=module.phase, status="ERROR",
                    error_msg=str(e), duration_s=0.0
                )
                print(f"EXCEPTION: {e}")
            self.results.append(result)

        return self.results

    def generate_report(self) -> str:
        """Generate and save the full report."""
        # ASCII table
        table = self.reporter.table(self.results)
        print(table)

        # Failure details
        details = self.reporter.failure_details(self.results)
        if details:
            print(details)

        # Save JSON report
        json_path = RESULTS_DIR / "cosim_report.json"
        json_data = self.reporter.json_report(self.results)
        with open(json_path, "w") as f:
            json.dump(json_data, f, indent=2)

        # Save text report
        txt_path = RESULTS_DIR / "cosim_report.txt"
        with open(txt_path, "w", encoding="utf-8") as f:
            f.write(table)
            if details:
                f.write("\n" + details)

        print(f"\n  Reports saved:")
        print(f"    Text: {txt_path}")
        print(f"    JSON: {json_path}")
        if WAVEFORM_DIR.exists():
            waves = list(WAVEFORM_DIR.glob("*.*"))
            if waves:
                print(f"    Waveforms: {WAVEFORM_DIR} ({len(waves)} files)")

        return table

    def exit_code(self) -> int:
        """Return CI-friendly exit code (0=all pass, N=fail count)."""
        return sum(1 for r in self.results if r.status in ("FAIL", "ERROR"))


# ===========================================================================
# CLI
# ===========================================================================

def list_modules():
    """Print available test modules."""
    registry = get_test_registry()
    print("\n  Available AEGIS Test Modules:")
    print("  " + "-" * 56)
    print(f"  {'Name':<12} {'Phase':<6} {'Description'}")
    print("  " + "-" * 56)
    for m in registry:
        print(f"  {m.name:<12} {m.phase:<6} {m.display_name}")
    print()


def main():
    parser = argparse.ArgumentParser(
        description="AEGIS Co-Simulation Framework — GHDL + Python",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python cosim_framework.py --run-all          # Run all tests
  python cosim_framework.py --module prng      # Test PRNG only
  python cosim_framework.py --module cpa       # CPA analysis only
  python cosim_framework.py --list             # List modules
  python cosim_framework.py --ci               # CI mode (exit code)
        """
    )
    parser.add_argument("--run-all", action="store_true",
                        help="Run all test modules")
    parser.add_argument("--module", "-m", type=str,
                        help="Run specific module by name")
    parser.add_argument("--list", "-l", action="store_true",
                        help="List available test modules")
    parser.add_argument("--ci", action="store_true",
                        help="CI mode: exit code = number of failures")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Verbose GHDL output")
    parser.add_argument("--report-only", action="store_true",
                        help="Reparse and display last results")

    args = parser.parse_args()

    if args.list:
        list_modules()
        return

    if not args.run_all and not args.module and not args.report_only:
        parser.print_help()
        return

    runner = CoSimRunner(verbose=args.verbose)

    if args.report_only:
        json_path = RESULTS_DIR / "cosim_report.json"
        if json_path.exists():
            with open(json_path) as f:
                data = json.load(f)
            for t in data.get("tests", []):
                runner.results.append(TestResult(
                    module=t["module"], display_name=t["name"],
                    phase=t["phase"], status=t["status"],
                    pass_count=t["passed"], fail_count=t["failed"],
                    duration_s=t["duration_s"], wave_file=t.get("waveform", "")
                ))
            runner.generate_report()
        else:
            print("  No previous results found. Run --run-all first.")
        return

    if args.run_all:
        runner.run_all()
    elif args.module:
        runner.run_all(filter_name=args.module)

    runner.generate_report()

    if args.ci:
        sys.exit(runner.exit_code())


if __name__ == "__main__":
    main()
