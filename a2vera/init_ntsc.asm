; init_ntsc.asm: VERA autodetect + init, NTSC composite / S-video output
;
; One of three interchangeable init programs. INIT-VGA, INIT-NTSC and
; INIT-RGB share vera_init_core.inc and differ only in the display
; composer setup below. Pick whichever matches the monitor and BRUN it
; once after boot, then run any of the other VERA programs.
;
; Run: BRUN INIT-NTSC
;
; 80-column text is past what composite can resolve, so the console and
; VERACON will smear on a composite monitor. S-video is noticeably better,
; and the bitmap programs are 320 pixels wide and look fine either way.

!cpu 6502

* = $0800

!source "a2vera/vera_init_core.inc"

MODE_ID = MODE_NTSC

; =============================================================================
; V_VIDEO_SETUP: NTSC 240p, 80x30 text
;
; 240P (DC_VIDEO bit 3) draws 263 progressive lines per field instead of
; 262.5 interlaced. Both fields then land on the same scanlines, so what
; reaches the screen is the even half of the 640x480 frame. VSCALE stays
; at 2x, which puts each source line on one even and one odd frame line,
; so every one of the 240 source lines survives that halving. Leaving
; VSCALE alone is also what keeps the bitmap programs looking the same
; here as they do on VGA, since they set HSCALE but inherit VSCALE.

;
; Interlaced 480i is the alternative (clear bit 3). It doubles vertical
; resolution and makes 8-pixel text flicker, which is a bad trade.
;
; Bit 2 is Chroma Disable, left clear for color. Set it for a sharper
; monochrome picture on a composite monitor.
; =============================================================================
!zone v_video_setup
v_video_setup:
        +VSET OFS_CTRL,  $00    ; DCSEL=0
        +VSET OFS_DC0A,  $80    ; HSCALE 1:1
        +VSET OFS_DC0B,  $40    ; VSCALE 2x -> 240 source lines, 80x30 text
        +VSET OFS_DC0C,  $00    ; BORDER
        +VSET OFS_DC09,  $9A    ; VIDEO: layer0 on, 240P, output mode 2 (NTSC)
        +VSET OFS_CTRL,  $02    ; DCSEL=1
        +VSET OFS_DC09,  $00    ; HSTART
        +VSET OFS_DC0A,  160    ; HSTOP  (160*4 = 640)
        +VSET OFS_DC0B,  $00    ; VSTART
        +VSET OFS_DC0C,  240    ; VSTOP  (240*2 = 480)
        +VSET OFS_CTRL,  $00    ; back to DCSEL=0
        rts

; --- mode-specific strings ---

msg_title:
        !text "VERA INIT - NTSC COMPOSITE"
        !byte 13
        !text "--------------------------"
        !byte 13, 13, 0

vstr_mode:
        !text "NTSC composite 240p", 0
