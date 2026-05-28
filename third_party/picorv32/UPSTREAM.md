# PicoRV32 Upstream Information

## Project

[PicoRV32 — Minimalistic RISC-V CPU Core](https://github.com/YosysHQ/picorv32)

## Integrated Version

Commit:
`87c89acc18994c8cf9a2311e871818e87d304568`

Replace with the exact upstream commit hash used for integration.

## License

ISC License

## Integration Method

PicoRV32 is vendored directly into:

`third_party/picorv32/`

No modifications have been made to upstream RTL sources.

## Files Included

* `picorv32.v`
* `simpleuart.v`
* `spimemio.v`

## Purpose in HelixSoC

PicoRV32 serves as the scalar RV32 processor core hosting the
Helix Vector Extension (HVX) through the PCPI coprocessor interface.

## Reproducibility

```bash
git clone https://github.com/YosysHQ/picorv32
git checkout 87c89ac
```

## Notes

* Helix integrates exclusively through the PCPI interface.
* No modifications to PicoRV32 decode or execution logic.
* Upstream compatibility intentionally preserved.
