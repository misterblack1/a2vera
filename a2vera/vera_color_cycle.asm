; vera_color_cycle.asm: 256-color grid with palette cycling, Apple II+VERA
;
; Ported from the C64 and AGFA 68k versions. Draws a 16x16 grid of 256 filled
; boxes (one per palette index 0-255) on an 8bpp 320x240 bitmap (VERA Layer
; 0), fades it in, then continuously cycles every palette entry's 12-bit RGB
; value (+1 per step, wrapping) for a rotating-rainbow effect until a key is
; pressed.

!cpu 6502

; --- VERA addressing: slot-agnostic via the init program's magic block ------
; Requires an init program (INIT-VGA, INIT-NTSC or INIT-RGB) to have been BRUN
; first. It autodetects VERA's slot, initializes it, and publishes the slot at
; $0300: $0300=$A2, $0301=$56, $0303=base hi ($C1..$C7). We read the base and
; address VERA through a runtime zero-page pointer (VERA_ZP) with (ptr),Y, so
; this runs in WHATEVER slot init found.
; We do NO reset/video setup. The palette IS cycled here, so this carries its
; own indirect palette upload (vera_common.inc's is slot-4 absolute).
VERA_ZP     = $0A             ; 2 bytes: runtime VERA base = $00/$CN
MAGIC_ADDR  = $0300
MAGIC_B0    = $A2
MAGIC_B1    = $56

; VERA register offsets (Y indices into (VERA_ZP),Y)
OFS_ADDR0_L = $00
OFS_ADDR0_M = $01
OFS_ADDR0_H = $02
OFS_DATA0   = $03
OFS_CTRL    = $05
OFS_DC_HSCALE = $0A
OFS_L0CFG   = $0D
OFS_L0MAP   = $0E
OFS_L0TILE  = $0F
OFS_L0_HSCR_L = $10
OFS_L0_HSCR_H = $11
OFS_L0_VSCR_L = $12
OFS_L0_VSCR_H = $13

; --- SMC: absolute VERA DATA0 store, patched at startup ---------------------
; DATA0 must NEVER be written with `sta (VERA_ZP),Y`. An indexed write does a
; dummy READ of the target first, and reading DATA0 auto-increments ADDR0, so
; every byte advances the pointer twice and lands on the wrong address.
; Writing $11 $22 $33 $44 to VRAM 0 lands as 00 11 00 22 00 33 00 44 with the
; indexed form. Full note in vera_common.inc.
; Placeholder low byte = DATA0 offset ($03). High byte $01 is a throwaway that
; forces ACME to emit a 3-byte absolute STA, giving us an operand to patch.
; patch_smc rewrites it to $CN03 for the detected slot. 4 cycles, frees Y.
VDATA0 = $0103

; Write a VERA register: (offset, immediate value) via (VERA_ZP),Y
; Safe for every register EXCEPT DATA0/DATA1 (see VDATA0 above).
!macro VSET ofs, val {
        ldy #ofs
        lda #val
        sta (VERA_ZP),y
}

* = $0800

start:
        jsr $FC58               ; HOME: clear Apple II text screen

        lda #<msg_start
        sta ZP_PTR
        lda #>msg_start
        sta ZP_PTR+1
        jsr a2_print

        ; --- require the init program's magic block (VERA already up) ---
        lda MAGIC_ADDR
        cmp #MAGIC_B0
        bne .badmagic
        lda MAGIC_ADDR+1
        cmp #MAGIC_B1
        beq .magic_ok
.badmagic:
        jmp no_magic
.magic_ok:
        lda MAGIC_ADDR+3        ; VERA base hi ($C1..$C7)
        sta VERA_ZP+1
        lda #$00
        sta VERA_ZP
        jsr patch_smc           ; MUST precede any DATA0 write

        ; Init already did reset, composer, and palette upload. Snapshot
        ; that palette, fade to black, switch to 8bpp bitmap + draw the grid,
        ; then fade back up to reveal it. The cycle then re-uploads the
        ; palette every frame.
        jsr save_pal_orig       ; palette_data -> pal_orig (fade_up target)
        jsr fade_to_black       ; fade IN (1/2): darken before drawing
        jsr enter_bitmap_mode
        jsr clear_bitmap
        jsr draw_grid
        jsr fade_up             ; fade IN (2/2): bring palette back up

        lda #<msg_cycle
        sta ZP_PTR
        lda #>msg_cycle
        sta ZP_PTR+1
        jsr a2_print

        jsr color_cycle_loop

        jsr fade_to_black       ; fade OUT: darken screen before exit
        lda #<msg_stopped
        sta ZP_PTR
        lda #>msg_stopped
        sta ZP_PTR+1
        jsr a2_print

        lda #<msg_font_erased
        sta ZP_PTR
        lda #>msg_font_erased
        sta ZP_PTR+1
        jsr a2_print

        jsr a2_clear_basic
        jmp $03D0               ; return to DOS (never RTS, see dev guide)

no_magic:
        lda #<msg_nomagic
        sta ZP_PTR
        lda #>msg_nomagic
        sta ZP_PTR+1
        jsr a2_print
        jsr a2_clear_basic
        jmp $03D0

; =============================================================================
; ENTER_BITMAP_MODE: Layer 0: 320x240, 8bpp, bitmap base at VRAM $00000
; =============================================================================
!zone enter_bitmap_mode
enter_bitmap_mode:
        +VSET OFS_CTRL,      $00   ; DCSEL=0
        +VSET OFS_DC_HSCALE, $40   ; 320px wide (init left this at $80=640px)
        +VSET OFS_L0CFG,     $07   ; bitmap mode + 8bpp color depth
        +VSET OFS_L0MAP,     $00
        +VSET OFS_L0TILE,    $00
        +VSET OFS_L0_HSCR_L, $00
        +VSET OFS_L0_HSCR_H, $00
        +VSET OFS_L0_VSCR_L, $00
        +VSET OFS_L0_VSCR_H, $00
        rts

; =============================================================================
; CLEAR_BITMAP: zero-fill 76800 bytes (320x240, 1 byte/pixel) from VRAM $00000
; 76800 = 300 * 256: outer loop counts pages (300), inner loop counts bytes
; within a page (256, via 8-bit Y wraparound).
; =============================================================================
!zone clear_bitmap
clear_bitmap:
        +VSET OFS_ADDR0_L, $00
        +VSET OFS_ADDR0_M, $00
        +VSET OFS_ADDR0_H, $10  ; bit16=0, stride=+1

        lda #<300
        sta cb_pages
        lda #>300
        sta cb_pages+1
.page:  ldx #$00                ; X counts each 256-byte page
.byte:  lda #$00
cb_st:  sta VDATA0              ; DATA0, absolute (patched by patch_smc)
        inx
        bne .byte

        lda cb_pages
        bne .dec_lo
        dec cb_pages+1
.dec_lo:
        dec cb_pages
        lda cb_pages
        ora cb_pages+1
        bne .page
        rts

; =============================================================================
; DRAW_GRID: 16x16 grid of filled boxes, one per palette index 0-255.
; col = index & 15, row = index >> 4 (16 is a power of 2, no divide needed)
; x1 = 8 + col*19 (lookup table), x2 = x1+17
; y1 = row*15 (lookup table), y2 = y1+13
; =============================================================================
!zone draw_grid
draw_grid:
        lda #$00
        sta grid_index
.box_loop:
        lda grid_index
        and #$0F                ; col = index mod 16
        tax
        lda col_x1_lo,x
        sta box_x1
        lda col_x1_hi,x
        sta box_x1+1
        lda col_x2_lo,x
        sta box_x2
        lda col_x2_hi,x
        sta box_x2+1

        lda grid_index
        lsr
        lsr
        lsr
        lsr                     ; row = index / 16
        tax
        lda row_y1,x
        sta box_y1
        clc
        adc #13
        sta box_y2

        lda grid_index
        sta box_color

        jsr fill_box

        inc grid_index
        bne .box_loop           ; wraps to 0 after 255 -> loop exits
        rts

; =============================================================================
; FILL_BOX: fill rows box_y1..box_y2 (inclusive) over columns
; box_x1..box_x2 (inclusive) with box_color, one fill_span call per row.
; =============================================================================
!zone fill_box
fill_box:
        lda box_y1
        sta fb_row
.row_loop:
        lda fb_row
        sta span_y
        jsr fill_span

        lda fb_row
        cmp box_y2
        beq .done
        inc fb_row
        jmp .row_loop
.done:
        rts

; =============================================================================
; FILL_SPAN: 8bpp linear fill: VERA_ADDR0 = span_y*320 + box_x1 (stride +1),
; write box_color (box_x2-box_x1+1) times.
; span_y*320 computed as (y<<8)+(y<<6) (shift+add, y ranges 0-239).
; Rows >= 205 have y*320 > 65535 so bit16 of the VRAM address must be set.
; fs_bit16 tracks the carry through both 16-bit additions.
; =============================================================================
!zone fill_span
fill_span:
        ; row_base (17-bit) = span_y * 320 = (span_y<<8) + (span_y<<6)
        lda #$00
        sta fs_addr              ; low byte of y<<8 contribution is always 0
        lda span_y
        sta fs_addr+1            ; fs_addr = y<<8

        lda span_y
        sta fs_tmp
        lda #$00
        sta fs_tmp+1
        asl fs_tmp
        rol fs_tmp+1
        asl fs_tmp
        rol fs_tmp+1
        asl fs_tmp
        rol fs_tmp+1
        asl fs_tmp
        rol fs_tmp+1
        asl fs_tmp
        rol fs_tmp+1
        asl fs_tmp
        rol fs_tmp+1             ; fs_tmp = y<<6

        lda fs_addr
        clc
        adc fs_tmp
        sta fs_addr
        lda fs_addr+1
        adc fs_tmp+1
        sta fs_addr+1            ; fs_addr = y*320 (low 16 bits)
        lda #$00
        adc #$00
        sta fs_bit16             ; carry out = VRAM bit16 from y*320

        ; address = row_base + box_x1 (box_x1 is 16-bit, up to 310)
        lda fs_addr
        clc
        adc box_x1
        sta fs_addr
        lda fs_addr+1
        adc box_x1+1
        sta fs_addr+1
        lda fs_bit16
        adc #$00
        sta fs_bit16             ; propagate any carry from x1 add into bit16

        ldy #OFS_ADDR0_L
        lda fs_addr
        sta (VERA_ZP),y
        ldy #OFS_ADDR0_M
        lda fs_addr+1
        sta (VERA_ZP),y
        ldy #OFS_ADDR0_H
        lda fs_bit16
        ora #$10                 ; stride=+1 in bits 7:4, bit16 in bit 0
        sta (VERA_ZP),y

        ; count = box_x2 - box_x1 + 1 (fits in a byte: max width 18)
        lda box_x2
        sec
        sbc box_x1
        sta fs_count
        lda box_x2+1
        sbc box_x1+1
        ; high byte of the width difference is always 0 for our boxes,
        ; ignored deliberately (max width is 18, well under 256)
        inc fs_count

        lda box_color
.fill_loop:
fs_st:  sta VDATA0              ; DATA0, absolute (patched by patch_smc)
        dec fs_count
        bne .fill_loop
        rts

; =============================================================================
; COLOR_CYCLE_LOOP: until a key is pressed: bump palette_data entries
; 1-255 (12-bit RGB +1, wrapping), reupload via upload_palette_data.
; Entry 0 (black) is left untouched, matching the AGFA original.
; =============================================================================
!zone color_cycle_loop
color_cycle_loop:
.loop:
        jsr a2_keypressed
        bne .done                ; Z=0 means key pressed

        jsr cycle_palette
        jsr upload_palette_data  ; vera_common.inc's slot-agnostic uploader

        jmp .loop
.done:
        rts

; =============================================================================
; CYCLE_PALETTE: entries 1-255: treat the 2 bytes as a 12-bit value
; (byte0 | ((byte1 & $0F) << 8)), add 1, mask to 12 bits, write back.
; =============================================================================
!zone cycle_palette
cycle_palette:
        lda #<(palette_data+2)
        sta ZP_PTR
        lda #>(palette_data+2)
        sta ZP_PTR+1
        ldx #255                 ; entries 1..255
.entry:
        ldy #$00
        lda (ZP_PTR),y           ; byte0
        sta cp_lo
        ldy #$01
        lda (ZP_PTR),y           ; byte1 (top nibble already always 0)
        sta cp_hi

        inc cp_lo
        bne .no_carry
        inc cp_hi
        lda cp_hi                ; reload incremented value (C64 bug fix:
        and #$0F                 ; old code masked A which still held the
        sta cp_hi                ; pre-increment byte1, red never advanced)
.no_carry:

        ldy #$00
        lda cp_lo
        sta (ZP_PTR),y
        ldy #$01
        lda cp_hi
        sta (ZP_PTR),y

        lda ZP_PTR
        clc
        adc #2
        sta ZP_PTR
        bcc .noof
        inc ZP_PTR+1
.noof:
        dex
        beq .done
        jmp .entry               ; loop body > 127 bytes, BNE can't reach
.done:
        rts

; =============================================================================
; PATCH_SMC: point every absolute DATA0 store at the detected slot.
; Call once, after VERA_ZP is loaded, before any DATA0 write. Only the high
; operand byte varies. The low byte ($03 = DATA0) is fixed at assembly time.
; =============================================================================
!zone patch_smc
patch_smc:
        lda VERA_ZP+1            ; $C1..$C7
        sta cb_st+2              ; clear_bitmap
        sta fs_st+2              ; fill_span
        rts

!source "a2vera/vera_common.inc"

; =============================================================================
; Data
; =============================================================================

; Printed on the Apple II's OWN screen via COUT, the only part of this
; program visible when sanity-testing in AppleWin (no VERA emulation).
msg_start:
        !text "256-COLOR GRID WITH PALETTE CYCLING."
        !byte 13
        !text "SETTING UP VERA 8BPP BITMAP (320X240)."
        !byte 13, 0

msg_cycle:
        !text "256-COLOR GRID WITH PALETTE CYCLING."
        !byte 13
        !text "PRESS ANY KEY TO EXIT."
        !byte 13, 0

msg_stopped:
        !text "STOPPED."
        !byte 13, 0

msg_font_erased:
        !text "FONT ERASED. RUN VERA INIT."
        !byte 13, 0

msg_nomagic:
        !text "VERA MODULE MUST BE INITIALIZED"
        !byte 13
        !text "BEFORE RUNNING THIS PROGRAM."
        !byte 13, 0

; --- Grid layout lookup tables (col/row range 0-15, avoids MULU) -----------
; col_x1 = 8 + col*19, col_x2 = col_x1 + 17, row_y1 = row*15
col_x1_lo:
        !byte <8, <27, <46, <65, <84, <103, <122, <141
        !byte <160, <179, <198, <217, <236, <255, <274, <293
col_x1_hi:
        !byte >8, >27, >46, >65, >84, >103, >122, >141
        !byte >160, >179, >198, >217, >236, >255, >274, >293
col_x2_lo:
        !byte <25, <44, <63, <82, <101, <120, <139, <158
        !byte <177, <196, <215, <234, <253, <272, <291, <310
col_x2_hi:
        !byte >25, >44, >63, >82, >101, >120, >139, >158
        !byte >177, >196, >215, >234, >253, >272, >291, >310
row_y1:
        !byte 0, 15, 30, 45, 60, 75, 90, 105
        !byte 120, 135, 150, 165, 180, 195, 210, 225

; --- Working storage --------------------------------------------------------

grid_index:  !byte 0     ; 0-255, current box / palette index during draw_grid
box_x1:      !word 0     ; 16-bit: column lookups can exceed 255 (up to 310)
box_x2:      !word 0
box_y1:      !byte 0     ; rows only run 0-239, fits in a byte
box_y2:      !byte 0
box_color:   !byte 0

fb_row:      !byte 0     ; fill_box's current row counter

span_y:      !byte 0     ; fill_span's row argument
fs_addr:     !word 0     ; fill_span's computed VRAM byte address (low 16 bits)
fs_bit16:    !byte 0     ; fill_span's VRAM address bit 16 (rows >= 205 need this)
fs_tmp:      !word 0     ; fill_span's y<<6 scratch
fs_count:    !byte 0     ; fill_span's remaining-bytes counter

cb_pages:    !word 0     ; clear_bitmap's remaining-pages counter (300, 16-bit)

cp_lo:       !byte 0     ; cycle_palette scratch: 12-bit value low byte
cp_hi:       !byte 0     ; cycle_palette scratch: 12-bit value high nibble
