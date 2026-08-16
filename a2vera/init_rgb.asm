; init_rgb.asm: VERA autodetect + init, 15kHz RGB output
;
; One of three interchangeable init programs. INIT-VGA, INIT-NTSC and
; INIT-RGB share vera_init_core.inc and differ only in the display
; composer setup below. Pick whichever matches the monitor and BRUN it
; once after boot, then run any of the other VERA programs.
;
; Run: BRUN INIT-RGB
;
; This is the mode for a SCART TV, a PVM, or an arcade monitor. Line rate
; is the same 15kHz as NTSC but the color signal is component RGB, so
; there is no chroma bandwidth limit and 80-column text stays readable.

!cpu 6502

* = $0800

!source "a2vera/vera_init_core.inc"

MODE_ID = MODE_RGB

; =============================================================================
; V_VIDEO_SETUP: 15kHz RGB 240p, 80x30 text
;
; 240P (DC_VIDEO bit 3) draws 263 progressive lines per field instead of
; 262.5 interlaced. Both fields then land on the same scanlines, so what
; reaches the screen is the even half of the 640x480 frame. VSCALE stays
; at 2x, which puts each source line on one even and one odd frame line,
; so every one of the 240 source lines survives that halving. Leaving
; VSCALE alone is also what keeps the bitmap programs looking the same
; here as they do on VGA, since they set HSCALE but inherit VSCALE.

;
; Bit 2 in RGB mode is HV Sync, meaning separate H and V sync lines
; instead of composite sync on the H pin. It is left clear because SCART
; and most PVMs want composite sync. Set it for a monitor that wants the
; two separately.
; =============================================================================
!zone v_video_setup
v_video_setup:
        +VSET OFS_CTRL,  $00    ; DCSEL=0
        +VSET OFS_DC0A,  $80    ; HSCALE 1:1
        +VSET OFS_DC0B,  $40    ; VSCALE 2x -> 240 source lines, 80x30 text
        +VSET OFS_DC0C,  $00    ; BORDER
        +VSET OFS_DC09,  $9B    ; VIDEO: layer0 on, 240P, output mode 3 (RGB)
        +VSET OFS_CTRL,  $02    ; DCSEL=1
        +VSET OFS_DC09,  $00    ; HSTART
        +VSET OFS_DC0A,  160    ; HSTOP  (160*4 = 640)
        +VSET OFS_DC0B,  $00    ; VSTART
        +VSET OFS_DC0C,  240    ; VSTOP  (240*2 = 480)
        +VSET OFS_CTRL,  $00    ; back to DCSEL=0
        rts

; --- mode-specific strings ---

msg_title:
        !text "VERA INIT - 15KHZ RGB"
        !byte 13
        !text "---------------------"
        !byte 13, 13, 0

vstr_mode:
        !text "15kHz RGB 240p", 0
