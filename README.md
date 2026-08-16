# Apple II VERA Tools

A crude, unoptimized 6502 assembly programs that drive a VERA graphics/audio
board wired into an Apple II slot.

Ported from C64 and AGFA Compugraphic 9000PS originals. The VERA register map
and VRAM layout are identical across all three hosts, so only the base address
and the host ROM calls differ.

## VERA documentation

VERA is the video and sound module from the Commander X16, and everything about
it carries over except the base address. The X16 documentation is what you
want for register details.

- [VERA Programmer's Reference](https://github.com/X16Community/x16-docs/blob/master/X16%20Reference%20-%2009%20-%20VERA%20Programmer's%20Reference.md)
- [Commander X16 documentation](https://github.com/X16Community/x16-docs)
- [VERA hardware and FPGA source](https://github.com/X16Community/vera-module)

## Hardware needed

- Apple II (II, II+, IIe, IIgs, or compatible). Plain 6502, no 65C02
  instructions are used, but code works fine on the 65C02.
- VERA card in any peripheral slot, 1 through 7. The slot is detected at
  runtime.
- A monitor connected to VERA, VGA or composite or 15kHz RGB. The Apple II's
  own screen is used only for status and error messages.
- Disk drive to boot DOS 3.3 software.
- An SD card in VERA's card slot, for the SD programs only. FAT32, and JP1
  must select SD rather than VERA flash.

The card is a carrier holding the VERA module, one 74HCT138 to split the slot's
R/W line into read and write strobes, a diode on the interrupt line, and a jack
for the audio pair. `WIRING.md` has the pinouts, the decode and every
connection.

## Programs

| Source                 | DOS name    | Description                                                         |
| ---------------------- | ----------- | ------------------------------------------------------------------- |
| `init_vga.asm`         | INIT-VGA    | Slot autodetect and init, VGA 640x480. Run an init first, everything else needs it. |
| `init_ntsc.asm`        | INIT-NTSC   | The same init, NTSC composite / S-Video 240p output.                 |
| `init_rgb.asm`         | INIT-RGB    | The same init, 15kHz RGB 240p output.                                |
| `vera_color_cycle.asm` | COLOR-CYCLE | 320x240 8bpp bitmap, 256-color grid, palette cycling.                |
| `vera_circles.asm`     | CIRCLES     | 320x240 8bpp bitmap, random filled circles.                          |
| `bach_inv13.asm`       | BACH-INV13  | PSG audio, Bach Invention No. 13 (BWV 784), plus a banner.           |
| `veracon.asm`          | VERACON     | Installs VERA as the Apple II console, 80 columns, CSW redirect.     |
| `vera_bench.asm`       | BENCH       | VRAM throughput benchmark, boxes and raw fill, bytes per second.     |
| `hgr_sd.asm`           | SD-HIRES    | Loads LINE.HGR off the SD card into hi-res page 1 and displays it.   |
| `slides_sd.asm`        | SD-SLIDES   | Slideshow. Streams SLIDE1-4.BIN to the 8bpp bitmap, palette each.    |
| `sd_diag.asm`          | SD-DIAG     | Staged SD bring-up diagnostic: init, block read, mount, find.        |

`vera_common.inc`, `vera_sd.inc` and `vera_init_core.inc` are shared includes,
not standalone programs. 

The three init programs are interchangeable. Pick the one that matches the
monitor. They share `vera_init_core.inc` and differ only in the display
composer setup, so each `.asm` is a handful of register writes and a name.
Running a second one after the first switches the output mode without
rescanning the slots.

An init program publishes what it found to a magic block at `$0300`, and every
other VERA program reads the base address from there. Run one init once after
boot, then any of the others.

Only the init programs write VERA's output mode register, so whichever mode
you pick survives into every program that runs after it.

## Running

`a2vera/a2vera_dos33.dsk` is a DOS 3.3 disk image with the demo programs on
it. Write it to a floppy, or use a Floppy EMU, then boot the machine and:

```
BRUN INIT-VGA
```

or `INIT-NTSC` or `INIT-RGB`, whichever suits the monitor.

Note that AppleWin and other Apple II emulators do not emulate VERA, so you
running these programs will not work.

## SD card

The two SD programs look for their data files in the **root directory** of a
FAT32 card. The loader does not walk subdirectories. Copy the contents of
`sdcard/` to the card root:

| File on card | Bytes | Used by   | Made from                  |
| ------------ | ----- | --------- | -------------------------- |
| `LINE.HGR`   | 8192  | SD-HIRES  | `slides/line.png`          |
| `SLIDE1.BIN` | 77312 | SD-SLIDES | `slides/mthood.png`        |
| `SLIDE2.BIN` | 77312 | SD-SLIDES | `slides/portland.png`      |
| `SLIDE3.BIN` | 77312 | SD-SLIDES | `slides/stjohnsbridge.png` |
| `SLIDE4.BIN` | 77312 | SD-SLIDES | `slides/timberline.png`    |

Each slide is a 512-byte VERA palette followed by a 76800-byte 8bpp bitmap, so
every picture carries its own 256 colors. The source PNGs are in `slides/` if
you want to regenerate them or substitute your own.

VERA's 12.5MHz SPI clock may not be reliable in every slot. On an Apple IIe, slots
4 and 7 were fine, slot 2 lost about 5 percent of reads, and slot 1 could not
hold a data token at all. All slots were clean at 390kHz, which costs about
1.7x in load time. The init program measures the link once at startup and
publishes the verdict, and the SD programs use whatever it decided. Similar
issues were experienced on my IIgs, but your mileage may vary.

## Building from source

Requires ACME 0.97.1 (the visrealm fork). Put `acme.exe` in the `assembler/`
directory, then run from the **repository root**, not from `a2vera/`. ACME
resolves the include paths relative to the current directory:

```
assembler/acme.exe -f apple -o a2vera/vera_circles.bin a2vera/vera_circles.asm
```

`-f apple` emits the DOS 3.3 binary header (load address and length, both
little-endian) directly, so no post-processing shim is needed. The "Using
oversized addressing mode" warnings are benign, ACME is picking a 3-byte
absolute where a 2-byte zero-page form would fit. Any other warning is real.

Prebuilt `.bin` files for every program are already in `a2vera/`, so you only
need ACME if you want to change something.

## Notes for anyone reading the source

A few things in here look wrong until you know why.

- VSYNC is polled from the ISR register instead of being handled by a real
  interrupt service routine. The 6502 IRQ vector lives in ROM on an unexpanded
  machine, so a true ISR would need a language card and would not run on a stock II
  or II+.
- Writes to VERA's DATA0 and DATA1 registers are always absolute stores, never
  `sta (ptr),y`. The indexed form performs a dummy read of the target address
  first, and reading DATA0 auto-increments VERA's address pointer, so every
  byte would advance it twice. The programs patch the slot number into those
  absolute stores at startup.

## Layout

```
WIRING.md       how the VERA module connects to the Apple II slot
a2vera/         sources, shared includes, prebuilt .bin, DOS 3.3 disk image
sdcard/         files to copy to the root of a FAT32 SD card
slides/         source PNGs the SD assets were generated from
agfa-monitor/   the CP437 font blob the init programs embed at build time
assembler/      put acme.exe here
```

## To-do

- Fade the palette in and out between slides in SD-SLIDES, for a smooth
  transition. The fade routines COLOR-CYCLE already uses are in
  `vera_common.inc`.

## License

Public domain, under the Unlicense. See `LICENSE`. Do whatever you want with
it, no attribution required.
