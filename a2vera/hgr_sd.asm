; hgr_sd.asm: load an Apple II hi-res image off the SD card and display it
;
; Reads LINE.HGR (8192 bytes, Apple II hi-res layout) from the SD card's root
; directory straight into hi-res page 1 at $2000, then shows it.
;
; VERA is still required even though nothing is drawn on it: the SD card hangs
; off VERA's SPI controller, so VERA_ZP has to be valid. BRUN an init program
; first.
; The picture itself is pure Apple II video and never touches VRAM.
;
; This program loads at $4000, ABOVE hi-res page 1. Loading at $0800 would
; work today but leaves only ~6KB before $2000, and the moment the code grew
; past that it would be quietly overwritten by the very image it just loaded.
; Sitting above the buffer removes the hazard entirely.
;
; The image file is a raw dump of hi-res page 1, row interleave already
; applied, so the loader is a straight copy with no unscrambling to do.
;
; Run: BRUN INIT-VGA (or INIT-NTSC / INIT-RGB), then BRUN HGR-SD

!cpu 6502

VERA_ZP     = $0A               ; SD access needs VERA's base, not its display
MAGIC_ADDR  = $0300
MAGIC_B0    = $A2
MAGIC_B1    = $56

COUT        = $FDED
PRBYTE      = $FDDA
HOME        = $FC58
KBD         = $C000
KBDSTRB     = $C010

TXTCLR      = $C050             ; graphics on
TXTSET      = $C051             ; text on
MIXCLR      = $C052             ; full screen
TXTPAGE1    = $C054
HIRESSET    = $C057

HGR_PAGE1   = $2000

* = $4000

start:
        jsr HOME
        lda #<msg_title
        sta ZP_PTR
        lda #>msg_title
        sta ZP_PTR+1
        jsr a2_print

        ; --- locate-or-die: VERA must be initialized for SPI ---
        lda MAGIC_ADDR
        cmp #MAGIC_B0
        bne .nomagic
        lda MAGIC_ADDR+1
        cmp #MAGIC_B1
        beq .magic_ok
.nomagic:
        lda #<msg_nomagic
        sta ZP_PTR
        lda #>msg_nomagic
        sta ZP_PTR+1
        jsr a2_print
        jmp $03D0
.magic_ok:
        lda MAGIC_ADDR+3
        sta VERA_ZP+1
        lda #$00
        sta VERA_ZP

        jsr sd_clock_from_magic  ; speed init qualified for this slot
        jsr sd_init
        bcc .init_ok
        jmp fail
.init_ok:
        jsr fat_mount
        bcc .mnt_ok
        jmp fail
.mnt_ok:
        lda #<name_pic
        sta ZP_PTR
        lda #>name_pic
        sta ZP_PTR+1
        jsr fat_find
        bcc .found
        lda #<msg_nofile
        sta ZP_PTR
        lda #>msg_nofile
        sta ZP_PTR+1
        jsr a2_print
        jmp $03D0
.found:
        ; Refuse anything that is not exactly one hi-res buffer. Loading a
        ; longer file would run straight past $3FFF into program territory.
        lda file_size+0
        bne .badsize
        lda file_size+1
        cmp #$20                 ; 8192 = $00002000
        bne .badsize
        lda file_size+2
        bne .badsize
        lda file_size+3
        bne .badsize

        lda #<msg_load
        sta ZP_PTR
        lda #>msg_load
        sta ZP_PTR+1
        jsr a2_print

        lda #<HGR_PAGE1          ; fat_load_ram streams into (ZP_PTR)
        sta ZP_PTR
        lda #>HGR_PAGE1
        sta ZP_PTR+1
        jsr fat_load_ram
        bcs fail

        ; --- full-screen hi-res page 1 ---
        lda TXTCLR
        lda MIXCLR
        lda TXTPAGE1
        lda HIRESSET
.wait:
        lda KBD
        bpl .wait
        sta KBDSTRB

        lda TXTSET
        jsr HOME
        jsr a2_clear_basic
        jmp $03D0

.badsize:
        lda #<msg_badsize
        sta ZP_PTR
        lda #>msg_badsize
        sta ZP_PTR+1
        jsr a2_print
        jmp $03D0

fail:
        lda #<msg_fail
        sta ZP_PTR
        lda #>msg_fail
        sta ZP_PTR+1
        jsr a2_print
        lda sd_last_err
        jsr PRBYTE
        lda #$8D
        jsr COUT
        jsr a2_clear_basic
        jmp $03D0

!source "a2vera/vera_sd.inc"
!source "a2vera/vera_common.inc"

; =============================================================================
; Data
; =============================================================================
msg_title:   !text "HI-RES SD VIEWER", 13, 0
msg_nomagic: !text "BRUN AN INIT PROGRAM FIRST.", 13, 0
msg_load:    !text "LOADING LINE.HGR...", 13, 0
msg_nofile:  !text "LINE.HGR NOT FOUND ON CARD.", 13, 0
msg_badsize: !text "NOT 8192 BYTES - NOT A HGR IMAGE.", 13, 0
msg_fail:    !text "SD ERROR=", 0

; 8.3 name, space-padded to 11 bytes: "LINE" + 4 spaces + "HGR"
name_pic:    !text "LINE    HGR"
