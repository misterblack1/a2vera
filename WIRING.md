# Wiring a VERA module to an Apple II expansion slot

You need a card that plugs into the Apple II slot, A VERA, one 74HCT138
to turn the slot's R/W line into separate read and write strobes, a diode on the
interrupt line, and a jack for the audio output.

No bus buffers, no level shifters, no programmable logic.

It works in any slot from 1 to 7. The software finds the card by scanning.

## Where VERA lands in the address space

The slot's /I/O SELECT line goes low when the 6502 addresses `$Cn00` through
`$CnFF`, where n is the slot number. That 256-byte page is the card's whole
footprint, so a card in slot 4 answers at `$C400`.

Only A0 through A4 reach the VERA, which is all VERA's 32 registers need.
A5 through A7 are not decoded, so the register block repeats eight times across
the page. Use `$Cn00` through `$Cn1F` and treat the rest as a mirror.

## Apple II slot pins used

| Pin | Signal | Goes to |
| --- | --- | --- |
| 1 | /I/O SELECT | 138 pin 2 (A1) |
| 2 to 6 | A0 to A4 | VERA, see the table below |
| 18 | R/W | 138 pin 1 (A0) |
| 25 | +5V | VERA pin 3, 138 pin 16 |
| 26 | GND | VERA pins 4, 23, 24, 138 pin 8 |
| 30 | /IRQ | VERA pin 16 through a diode |
| 31 | /RES | VERA pin 14 |
| 41 | /DEVICE SELECT | HCT138 pin 3 (A2) |
| 42 to 49 | D7 down to D0 | VERA, see the table below |

## The VERA connector


```
        +--------+
   NC  1|  o  o  |2   NC
  +5V  3|  o  o  |4   GND
   D7  5|  o  o  |6   D6
   D5  7|  o  o  |8   D4
   D3  9|  o  o  |10  D2
   D1 11|  o  o  |12  D0
  /CS 13|  o  o  |14  /RES
  /WR 15|  o  o  |16  /IRQ
   A4 17|  o  o  |18  /RD
   A2 19|  o  o  |20  A3
   A0 21|  o  o  |22  A1
  GND 23|  o  o  |24  GND
AUD_L 25|  o  o  |26  AUD_R
        +--------+
```

## Address decode

One 74HCT138, I only tested with a HCT part. ACT or LS may work fine.

| 138 pin | Signal |
| --- | --- |
| 1 (A0) | R/W, slot pin 18 |
| 2 (A1) | /I/O SELECT, slot pin 1 |
| 3 (A2) | /DEVICE SELECT, slot pin 41 |
| 4 (/E0) | GND |
| 5 (/E1) | GND |
| 6 (E2) | +5V |
| 8 | GND |
| 16 | +5V |

Both active-low enables are grounded and the active-high enable is at +5V, so
the decoder is always on and the outputs follow the three inputs directly.

| /DEV SEL | /IO SEL | R/W | Output | Strobe |
| --- | --- | --- | --- | --- |
| 1 | 0 | 0 | Y4, pin 11 | /VERA_WR |
| 1 | 0 | 1 | Y5, pin 10 | /VERA_RD |
| 1 | 1 | x | Y6, Y7 | none |
| 0 | 1 | 0 | Y2, pin 13 | unused |
| 0 | 1 | 1 | Y3, pin 12 | unused |

Y4 goes to VERA pin 15 (/WR) and Y5 goes to VERA pin 18 (/RD).

0.1uF ceramic across the 138's supply pins, close to the chip.

## Connections

Address:

```
slot 2  (A0) -> VERA 21 (A0)
slot 3  (A1) -> VERA 22 (A1)
slot 4  (A2) -> VERA 19 (A2)
slot 5  (A3) -> VERA 20 (A3)
slot 6  (A4) -> VERA 17 (A4)
```

Data:

```
slot 49 (D0) -> VERA 12 (D0)
slot 48 (D1) -> VERA 11 (D1)
slot 47 (D2) -> VERA 10 (D2)
slot 46 (D3) -> VERA  9 (D3)
slot 45 (D4) -> VERA  8 (D4)
slot 44 (D5) -> VERA  7 (D5)
slot 43 (D6) -> VERA  6 (D6)
slot 42 (D7) -> VERA  5 (D7)
```

Control:

```
138 Y4 (pin 11) -> VERA 15 (/WR)
138 Y5 (pin 10) -> VERA 18 (/RD)
GND             -> VERA 13 (/CS)
slot 31 (/RES)  -> VERA 14 (/RES)
slot 30 (/IRQ)  -> diode -> VERA 16 (/IRQ)
```

## /IRQ through a diode

The Apple II's interrupt line is shared by every card in the machine and pulled
up on the motherboard, so a card is only ever allowed to pull it down. Put a
diode in series to make the VERA's output open collector:

```
slot 30 (/IRQ) ---->|---- VERA 16 (/IRQ)
                 anode  cathode
```

A 1N4148 or similar diode is fine.

The programs in this repo poll VERA's ISR register rather than taking an
interrupt, so they run on a card with the diode left off.

## Audio

VERA pins 25 and 26 are analog outputs for the PSG, left and right. Pins 23
and 24 are their ground return. A 3.5mm stereo jack wires straight across, tip
to pin 25, ring to pin 26, sleeve to ground. Nothing else in between.

Keep that pair routed against pins 23 and 24 and away from the data lines.

## Levels and buffering

VERA's interface is native 5V, so D0 to D7, A0 to A4, /CS, /RD, /WR and
/RES connect to the slot directly. There is no transceiver on the data bus and
no series resistors anywhere.

## Parts

| Qty | Part |
| --- | --- |
| 1 | VERA, Commander X16 |
| 1 | 74HCT138 or similar |
| 1 | 0.1uF ceramic capacitor |
| 1 | 1N4148 |
| 1 | 26-pin dual-row header, 0.1" pitch |
| 1 | 3.5mm stereo jack |
| | Apple II card blank and hookup wire |
