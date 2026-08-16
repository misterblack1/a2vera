; init_vga.asm: VERA autodetect + init, VGA 640x480 output
;
; One of three interchangeable init programs. INIT-VGA, INIT-NTSC and
; INIT-RGB share vera_init_core.inc and differ only in the display
; composer setup below. Pick whichever matches the monitor and BRUN it
; once after boot, then run any of the other VERA programs.
;
; Run: BRUN INIT-VGA

!cpu 6502

* = $0800

!source "a2vera/vera_init_core.inc"

MODE_ID = MODE_VGA

; =============================================================================
; V_VIDEO_SETUP: VGA 640x480 60Hz progressive, 80x30 text
; =============================================================================
!zone v_video_setup
v_video_setup:
        +VSET OFS_CTRL,  $00    ; DCSEL=0
        +VSET OFS_DC0A,  $80    ; HSCALE 1:1
        +VSET OFS_DC0B,  $40    ; VSCALE 2x -> 240 source lines, 80x30 text
        +VSET OFS_DC0C,  $00    ; BORDER
        +VSET OFS_DC09,  $91    ; VIDEO: layer0 on, output mode 1 (VGA)
        +VSET OFS_CTRL,  $02    ; DCSEL=1
        +VSET OFS_DC09,  $00    ; HSTART
        +VSET OFS_DC0A,  160    ; HSTOP  (160*4 = 640)
        +VSET OFS_DC0B,  $00    ; VSTART
        +VSET OFS_DC0C,  240    ; VSTOP  (240*2 = 480)
        +VSET OFS_CTRL,  $00    ; back to DCSEL=0
        rts

; --- mode-specific strings ---

msg_title:
        !text "VERA INIT - VGA"
        !byte 13
        !text "---------------"
        !byte 13, 13, 0

vstr_mode:
        !text "VGA 640x480 60Hz", 0
