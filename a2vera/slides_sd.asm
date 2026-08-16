; slides_sd.asm: SD-card slideshow on VERA
;
; Streams SLIDE1.BIN .. SLIDE4.BIN from the SD card's root directory to VERA's
; 320x240 8bpp bitmap, one at a time. Any key advances, ESC quits, and the
; show wraps from slide 4 back to slide 1.
;
; Each file is 77312 bytes: a 512-byte VERA palette followed by the 76800-byte
; bitmap. Every slide therefore brings its own 256 colors, which is what makes
; photographs look right. The built-in palette reaches only ~56 of 256 entries
; on a photo and bands badly.
;
; NOTE ON EXIT: the bitmap occupies VRAM $00000 upward, which is where the
; text tilemap and font live. Displaying a slide destroys both, so there is no
; text mode to return to. BRUN an init program afterwards to rebuild it.
;
; Ends with JMP $03D0 (never RTS from a BRUN'd program).
;
; Run: BRUN INIT-VGA (or INIT-NTSC / INIT-RGB), then BRUN SLIDES

!cpu 6502

VERA_ZP     = $0A
MAGIC_ADDR  = $0300
MAGIC_B0    = $A2
MAGIC_B1    = $56

COUT        = $FDED
PRBYTE      = $FDDA
HOME        = $FC58
KBD         = $C000
KBDSTRB     = $C010

OFS_CTRL      = $05
OFS_DC_HSCALE = $0A
OFS_L0CFG     = $0D
OFS_L0MAP     = $0E
OFS_L0TILE    = $0F
OFS_L0_HSCR_L = $10
OFS_L0_HSCR_H = $11
OFS_L0_VSCR_L = $12
OFS_L0_VSCR_H = $13

NUM_SLIDES  = 4
NAME_LEN    = 11                ; FAT 8.3 names are 11 bytes, space padded

!macro VSET ofs, val {
        ldy #ofs
        lda #val
        sta (VERA_ZP),y
}

* = $0800

start:
        jsr HOME
        lda #<msg_title
        sta ZP_PTR
        lda #>msg_title
        sta ZP_PTR+1
        jsr a2_print

        ; --- locate-or-die ---
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
        jsr enter_bitmap_mode

        lda #$00
        sta cur_slide
show_loop:
        ; --- "SLIDE n OF 4" ---
        lda #<msg_slide
        sta ZP_PTR
        lda #>msg_slide
        sta ZP_PTR+1
        jsr a2_print
        lda cur_slide
        clc
        adc #$B1                 ; 0 -> '1' with the high bit set
        jsr COUT
        lda #$8D
        jsr COUT

        ; --- ZP_PTR = &slide_names[cur_slide * NAME_LEN] ---
        lda #<slide_names
        sta ZP_PTR
        lda #>slide_names
        sta ZP_PTR+1
        ldx cur_slide
        beq .have_name
.addname:
        clc
        lda ZP_PTR
        adc #NAME_LEN
        sta ZP_PTR
        bcc .nocarry
        inc ZP_PTR+1
.nocarry:
        dex
        bne .addname
.have_name:
        jsr fat_find
        bcc .found
        ; fat_find returns carry set for two unrelated reasons: the name really
        ; is not in the root directory (SDERR_FIND), or a directory sector read
        ; failed on the way through it (SDERR_READ, set by sd_read_block and
        ; passed through fat_find's .err exit untouched). Printing "NOT FOUND"
        ; for both hid a run of read errors on the IIe as three missing files.
        lda sd_last_err
        cmp #SDERR_FIND
        beq .really_missing
        jmp fail
.really_missing:
        lda #<msg_nofile
        sta ZP_PTR
        lda #>msg_nofile
        sta ZP_PTR+1
        jsr a2_print
        jmp .next_slide
.found:
        ; VRAM dest = $00000, increment 1 (H = $10)
        lda #$00
        sta ld_vaddr+0
        sta ld_vaddr+1
        lda #$10
        sta ld_vaddr+2
        jsr fat_load_vram_pal
        bcc .shown
        jmp fail
.shown:
        ; --- wait for a key: ESC quits, anything else advances ---
.waitkey:
        lda KBD
        bpl .waitkey
        sta KBDSTRB
        and #$7F
        cmp #$1B                 ; ESC
        beq done
.next_slide:
        inc cur_slide
        lda cur_slide
        cmp #NUM_SLIDES
        bcc .more
        lda #$00
        sta cur_slide
.more:
        jmp show_loop

done:
        lda #<msg_done
        sta ZP_PTR
        lda #>msg_done
        sta ZP_PTR+1
        jsr a2_print
        jsr a2_clear_basic
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

; =============================================================================
; ENTER_BITMAP_MODE: Layer 0: 320x240, 8bpp, bitmap base VRAM $00000
; =============================================================================
!zone enter_bitmap_mode
enter_bitmap_mode:
        +VSET OFS_CTRL,      $00
        +VSET OFS_DC_HSCALE, $40   ; 320px wide
        +VSET OFS_L0CFG,     $07   ; bitmap mode + 8bpp
        +VSET OFS_L0MAP,     $00
        +VSET OFS_L0TILE,    $00
        +VSET OFS_L0_HSCR_L, $00
        +VSET OFS_L0_HSCR_H, $00
        +VSET OFS_L0_VSCR_L, $00
        +VSET OFS_L0_VSCR_H, $00
        rts

!source "a2vera/vera_sd.inc"
!source "a2vera/vera_common.inc"

; =============================================================================
; Data
; =============================================================================
msg_title:   !text "VERA SD SLIDESHOW", 13
             !text "KEY = NEXT, ESC = QUIT", 13, 0
msg_nomagic: !text "BRUN AN INIT PROGRAM FIRST.", 13, 0
msg_slide:   !text "LOADING SLIDE ", 0
msg_nofile:  !text "NOT FOUND, SKIPPING.", 13, 0
msg_done:    !text "DONE. BRUN AN INIT TO GET TEXT BACK.", 13, 0
msg_fail:    !text "SD ERROR=", 0

; Four 8.3 names, 11 bytes each, space padded. Order matters: the index into
; this table is the slide number.
slide_names:
        !text "SLIDE1  BIN"
        !text "SLIDE2  BIN"
        !text "SLIDE3  BIN"
        !text "SLIDE4  BIN"

cur_slide:   !byte 0
