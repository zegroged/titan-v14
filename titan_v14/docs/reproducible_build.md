# Reproducible Builds — PROJECT HİDRA

## Amaç
Aynı kaynak kodundan aynı binary/bitstream üretmek — supply-chain attack tespiti.

## MCU Firmware (STM32L476)
```bash
# Docker konteyner (pinned toolchain)
docker run --rm -v $(pwd):/src hidra-build:arm-gcc-12.3 \
  make -C /src/sw/callwhite_mcu all

# Hash verify
sha256sum build/callwhite.bin > build/SHA256SUMS
```

## Rust (hidra_net/hidra_core/hidra_ui)
```bash
# Locked dependencies
cargo build --release --locked

# Verify
sha256sum target/release/hidra_* > SHA256SUMS.rust
```

## FPGA Bitstream (Vivado)
```tcl
# Deterministic synthesis
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.USERID 0xHIDRA14 [current_design]
# TCL script ensures identical P&R seed
source scripts/build_bitstream.tcl
```

## Doğrulama
1. İki farklı makinede build → hash karşılaştır
2. CI/CD pipeline'da otomatik hash check
3. Release'de SHA256SUMS imzalı (GPG)
