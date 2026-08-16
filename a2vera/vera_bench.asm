; vera_bench.asm: VERA throughput benchmark, Apple II+VERA
;
; Measures raw VRAM write throughput two ways, each timed over exactly
; 600 VSYNC edges (10.0 s at VERA's 60 Hz VGA output):
;
;   RUN 1 (BOXES): draw BOX_W x BOX_H filled boxes (default 32x32=1024B),
;     tiling across a 320x240 8bpp bitmap, counting completed boxes. VSYNC
;     is polled once per box, accurate only while one box draws in under
;     one frame (~16.7ms ~= 17000 cyc), so keep BOX_BYTES small (<= ~2500B,
;     that is, <= ~50x50). The default 32x32 (~12ms) has comfortable margin.
;
;   RUN 2 (RAW): contiguous full-screen fills (76800B each), polling VSYNC
;     every 256-byte page (~2.7ms << 16.7ms) so no edge is ever missed,
;     regardless of how long a single fill takes. Counts completed screens.
;
; For each run prints: count, total bytes written, and bytes/sec (=total/10).
;
; The fill loops use SELF-MODIFYING CODE + 8x LOOP UNROLLING: at startup the
; discovered VERA slot ($CN from the $0300 magic block) is patched into the
; hot STA instructions, turning them from indirect  sta (VERA_ZP),y  (6 cyc)
; into absolute  sta $CN03  (4 cyc), still hitting the same DATA0 register,
; so VERA's auto-increment is unchanged. Each fill body is then unrolled 8x
; via !rept, dropping the loop tax (dex+bne) from ~9 cyc/byte to ~4.6 cyc/byte.
; Setup/ADDR0 writes stay indirect (they're not the bottleneck).
;
; Requires an init program (INIT-VGA, INIT-NTSC or INIT-RGB) to have been BRUN
; first. It autodetects the slot, inits VERA, and publishes the slot in the
; $0300 magic block. This program does NO reset/video/palette setup (only the
; 8bpp bitmap-mode switch) and reuses the palette init already uploaded.

!cpu 6502

; --- Bitmap geometry (8bpp) -------------------------------------------------
BMP_WIDTH       = 320
BMP_HEIGHT      = 240
BMP_SIZE_BYTES  = 76800        ; 320*240, one full screen

; --- Box geometry (edit + re-assemble for a size-vs-throughput curve) -------
; MUST draw in under one video frame (~16.7ms ~= 17000 cyc ~= <=2500 bytes)
; or the per-box VSYNC poll would miss edges and the timing reads short.
BOX_W     = 32
BOX_H     = 32
BOX_BYTES = BOX_W * BOX_H      ; 1024

; --- Timing -----------------------------------------------------------------
; VERA's VGA output is 60 Hz, so 10.0 s = 600 VSYNC edges.
RUN_FRAMES = 600

; --- VERA addressing: slot-agnostic via the init program's magic block -----
VERA_ZP    = $0A               ; 2 bytes: runtime VERA base = $00/$CN
MAGIC_ADDR = $0300
MAGIC_B0   = $A2
MAGIC_B1   = $56

; VERA register offsets (Y indices into (VERA_ZP),Y)
OFS_ADDR0_L   = $00
OFS_ADDR0_M   = $01
OFS_ADDR0_H   = $02
OFS_DATA0     = $03
OFS_CTRL      = $05
OFS_ISR       = $07
OFS_DC_HSCALE = $0A
OFS_L0CFG     = $0D
OFS_L0MAP     = $0E
OFS_L0TILE    = $0F
OFS_L0_HSCR_L = $10
OFS_L0_HSCR_H = $11
OFS_L0_VSCR_L = $12
OFS_L0_VSCR_H = $13

; --- SMC: absolute VERA DATA0 store, patched at startup ---------------------
; Placeholder address whose LOW byte = DATA0 offset ($03) and whose HIGH byte
; is a throwaway ($01) we overwrite at runtime. Page $01 (not zero page) forces
; ACME to emit a 3-byte absolute STA, giving us a hi-byte operand to patch.
; After patch_smc, each  sta VDATA0  below becomes  sta $CN03  (4 cyc) where
; $CN is the slot init found. Auto-increment is unaffected (same reg).
VDATA0 = $0103

; Write a VERA register: (offset, immediate value) via (VERA_ZP),Y
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

        ; bake the slot into the hot fill loops (indirect -> absolute STA)
        jsr patch_smc

        ; Init already did reset, composer, and palette upload.
        ; Switch Layer 0 to 8bpp bitmap and clear the framebuffer.
        jsr enter_bitmap_mode
        jsr clear_bitmap

        ; ================= RUN 1: BOXES =================
        lda #<msg_run1
        sta ZP_PTR
        lda #>msg_run1
        sta ZP_PTR+1
        jsr a2_print

        jsr run_boxes
        jsr print_box_results

        ; ================= RUN 2: RAW FILL =================
        lda #<msg_run2
        sta ZP_PTR
        lda #>msg_run2
        sta ZP_PTR+1
        jsr a2_print

        jsr run_raw
        jsr print_raw_results

        ; done
        lda #<msg_done
        sta ZP_PTR
        lda #>msg_done
        sta ZP_PTR+1
        jsr a2_print

        ; wait for any key before returning to DOS (so results stay visible)
.keywait:
        jsr a2_keypressed
        beq .keywait
        jsr a2_clear_basic
        jmp $03D0               ; return to DOS (NEVER RTS from BRUN)

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
        +VSET OFS_CTRL,        $00   ; DCSEL=0
        +VSET OFS_DC_HSCALE,   $40   ; 320px wide (init left this at $80=640px)
        +VSET OFS_L0CFG,       $07   ; bitmap mode + 8bpp color depth
        +VSET OFS_L0MAP,       $00
        +VSET OFS_L0TILE,      $00
        +VSET OFS_L0_HSCR_L,   $00
        +VSET OFS_L0_HSCR_H,   $00
        +VSET OFS_L0_VSCR_L,   $00
        +VSET OFS_L0_VSCR_H,   $00
        rts

; =============================================================================
; CLEAR_BITMAP: zero-fill 76800 bytes (320x240, 1 byte/pixel) from VRAM $00000
; 76800 = 300 * 256: outer counts pages (300, 16-bit), inner writes 256 bytes
; per page as 32 groups of 8 (8x-unrolled SMC absolute stores).
; =============================================================================
!zone clear_bitmap
clear_bitmap:
        +VSET OFS_ADDR0_L, $00
        +VSET OFS_ADDR0_M, $00
        +VSET OFS_ADDR0_H, $10   ; bit16=0, stride=+1

        lda #<300
        sta cb_pages
        lda #>300
        sta cb_pages+1
        ; 256 bytes/page = 32 groups of 8 (8x-unrolled SMC absolute store)
.page:  ldx #(256/8)
        lda #$00
.byte_grp:
sclr_fill:
        sta VDATA0
        sta VDATA0
        sta VDATA0
        sta VDATA0
        sta VDATA0
        sta VDATA0
        sta VDATA0
        sta VDATA0
        dex
        bne .byte_grp

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
; WAIT_VSYNC: block until the next VSYNC edge, then clear it. Used to sync
; the start of each timed run to a frame boundary.
; =============================================================================
!zone wait_vsync
wait_vsync:
        ldy #OFS_ISR
.wv:    lda (VERA_ZP),y
        and #$01
        beq .wv
        lda #$01
        sta (VERA_ZP),y          ; clear VSYNC flag (write 1 to bit 0)
        rts

; =============================================================================
; CHECK_VSYNC: non-blocking: if the VSYNC flag is set, clear it and bump the
; 16-bit edge counter (frames_lo/hi). Called often inside the timed loops.
; =============================================================================
!zone check_vsync
check_vsync:
        ldy #OFS_ISR
        lda (VERA_ZP),y
        and #$01
        beq .cv_done
        lda #$01
        sta (VERA_ZP),y          ; clear
        inc frames_lo
        bne .cv_done
        inc frames_hi
.cv_done:
        rts

; =============================================================================
; FRAMES_GE: returns C=1 if frames_lo/hi >= RUN_FRAMES (600), else C=0.
; =============================================================================
!zone frames_ge
frames_ge:
        lda frames_hi
        cmp #>RUN_FRAMES         ; 600 = $0258, hi byte = $02
        bcc .fg_no               ; hi < 2 -> < 600
        bne .fg_yes              ; hi > 2 -> > 600
        lda frames_lo            ; hi == 2: decide on lo
        cmp #<RUN_FRAMES         ; lo < $58 ?
        bcc .fg_no               ; lo < $58 -> < 600
.fg_yes:
        sec
        rts
.fg_no:
        clc
        rts

; =============================================================================
; RUN_BOXES: draw BOX_W x BOX_H filled boxes (tiling, advancing position)
; for exactly RUN_FRAMES VSYNC edges. On exit: boxcount_* (24-bit completed
; boxes) and totalb_* (24-bit bytes written).
; =============================================================================
!zone run_boxes
run_boxes:
        lda #$00
        sta cur_x_lo
        sta cur_x_hi
        sta cur_y
        sta boxcount_0
        sta boxcount_1
        sta boxcount_2
        sta totalb_0
        sta totalb_1
        sta totalb_2
        sta frames_lo
        sta frames_hi
        lda #$01
        sta box_color            ; start color (palette entry 1)

        ; sync to a frame boundary, frames stays 0 across the sync edge
        +VSET OFS_ISR, $01       ; clear any stale VSYNC
        jsr wait_vsync           ; block to the next edge, clear it

.rb_loop:
        jsr draw_one_box

        ; boxcount++ (24-bit)
        inc boxcount_0
        bne .rb_bc
        inc boxcount_1
        bne .rb_bc
        inc boxcount_2
.rb_bc:
        ; totalb += BOX_BYTES (24-bit). BOX_BYTES=1024=$0400 (fits 16 bits)
        lda totalb_0
        clc
        adc #<BOX_BYTES
        sta totalb_0
        lda totalb_1
        adc #>BOX_BYTES
        sta totalb_1
        lda totalb_2
        adc #$00                 ; BOX_BYTES < $10000 -> byte2 gets carry only
        sta totalb_2

        ; advance box position: cur_x += BOX_W, if >= 320, wrap x and y+=BOX_H
        lda cur_x_lo
        clc
        adc #BOX_W
        sta cur_x_lo
        lda cur_x_hi
        adc #$00
        sta cur_x_hi
        ; if cur_x >= 320 ($0140): wrap
        lda cur_x_hi
        cmp #>320
        bcc .rb_noend            ; hi < 1 -> cur_x < 256 < 320
        bne .rb_wrapx            ; hi > 1 -> cur_x >= 512 > 320
        lda cur_x_lo             ; hi == 1
        cmp #<320
        bcc .rb_noend            ; lo < $40 -> cur_x < 320
.rb_wrapx:
        lda #$00
        sta cur_x_lo
        sta cur_x_hi
        lda cur_y
        clc
        adc #BOX_H
        sta cur_y
        cmp #BMP_HEIGHT          ; >= 240?
        bcc .rb_noend
        lda #$00
        sta cur_y
.rb_noend:
        inc box_color            ; cycle color for visual feedback

        jsr check_vsync
        jsr frames_ge
        bcc .rb_loop
        rts

; =============================================================================
; DRAW_ONE_BOX: fill a BOX_W x BOX_H box at (cur_x, cur_y) with box_color.
; Computes the row-0 base once (cur_y*320) and steps +320 per row. Each row:
; ADDR0 = row_base + cur_x (stride +1), then BOX_W byte writes via DATA0.
; This is the hot path and the optimization target for future builds.
; =============================================================================
!zone draw_one_box
draw_one_box:
        ; --- rbase (16-bit) + rbase_b16 = cur_y * 320 = (cur_y<<8) + (cur_y<<6)
        lda #$00
        sta rbase_lo             ; (cur_y<<8) low = 0
        lda cur_y
        sta rbase_hi             ; (cur_y<<8) high = cur_y
        lda #$00
        sta rbase_b16
        ; t = cur_y, then shift left 6 (= *64)
        lda cur_y
        sta t_lo
        lda #$00
        sta t_hi
        asl t_lo
        rol t_hi
        asl t_lo
        rol t_hi
        asl t_lo
        rol t_hi
        asl t_lo
        rol t_hi
        asl t_lo
        rol t_hi
        asl t_lo
        rol t_hi                 ; t = cur_y * 64
        ; rbase += t
        lda rbase_lo
        clc
        adc t_lo
        sta rbase_lo
        lda rbase_hi
        adc t_hi
        sta rbase_hi
        lda rbase_b16
        adc #$00
        sta rbase_b16            ; carry out -> bit16 (set when cur_y >= 205)

        lda #BOX_H
        sta rows_left
.drow:
        ; addr = rbase + cur_x
        lda rbase_lo
        clc
        adc cur_x_lo
        sta a_lo
        lda rbase_hi
        adc cur_x_hi
        sta a_hi
        lda rbase_b16
        adc #$00
        sta a_b16
        ; program ADDR0 = a (17-bit), stride +1
        ldy #OFS_ADDR0_L
        lda a_lo
        sta (VERA_ZP),y
        ldy #OFS_ADDR0_M
        lda a_hi
        sta (VERA_ZP),y
        ldy #OFS_ADDR0_H
        lda a_b16
        ora #$10                 ; bit16 in bit0, stride=+1 in bits 7:4
        sta (VERA_ZP),y
        ; write BOX_W bytes of box_color via DATA0 (auto-increment +1)
        ; BOX_W must be a multiple of 8 for the unrolled fill (32/8=4 groups)
        lda box_color
        ldx #(BOX_W/8)
.dbyte_grp:
sbox_fill:
        sta VDATA0              ; SMC absolute (sta $CN03 after patch_smc)
        sta VDATA0
        sta VDATA0
        sta VDATA0
        sta VDATA0
        sta VDATA0
        sta VDATA0
        sta VDATA0
        dex
        bne .dbyte_grp
        ; rbase += 320 (next row)
        lda rbase_lo
        clc
        adc #<320
        sta rbase_lo
        lda rbase_hi
        adc #>320
        sta rbase_hi
        lda rbase_b16
        adc #$00
        sta rbase_b16
        dec rows_left
        bne .drow
        rts

; =============================================================================
; RUN_RAW: contiguous full-screen fills (76800B) for RUN_FRAMES VSYNC edges.
; VSYNC is polled every 256-byte page (~2.7ms << 16.7ms frame) so no edge is
; ever missed. Completed screens counted in screen_*, bytes in totalb_*.
; A partial last screen is NOT counted.
; =============================================================================
!zone run_raw
run_raw:
        lda #$00
        sta screen_0
        sta screen_1
        sta screen_2
        sta totalb_0
        sta totalb_1
        sta totalb_2
        sta frames_lo
        sta frames_hi
        lda #$11                 ; start fill color (palette entry $11)
        sta raw_color

        +VSET OFS_ISR, $01       ; clear stale VSYNC
        jsr wait_vsync           ; sync to frame boundary

.rr_outer:
        ; ADDR0 = $00000, stride +1
        +VSET OFS_ADDR0_L, $00
        +VSET OFS_ADDR0_M, $00
        +VSET OFS_ADDR0_H, $10
        lda raw_color
        sta fill_color
        ; page counter = 300 (300*256 = 76800)
        lda #<300
        sta pages_lo
        lda #>300
        sta pages_hi
.rr_page:
        ldx #(256/8)            ; 32 groups of 8 = 256 bytes/page
        lda fill_color
.rr_grp:
sraw_fill:
        sta VDATA0              ; SMC absolute (sta $CN03 after patch_smc)
        sta VDATA0
        sta VDATA0
        sta VDATA0
        sta VDATA0
        sta VDATA0
        sta VDATA0
        sta VDATA0
        dex
        bne .rr_grp              ; 256 bytes written
        ; one page done: poll VSYNC, stop if time is up (partial screen uncounted)
        jsr check_vsync
        jsr frames_ge
        bcs .rr_timeup
        ; pages-- (16-bit), loop while != 0
        lda pages_lo
        bne .rr_declo
        dec pages_hi
.rr_declo:
        dec pages_lo
        lda pages_lo
        ora pages_hi
        bne .rr_page
        ; --- full screen complete: count it ---
        inc screen_0
        bne .rr_sc
        inc screen_1
        bne .rr_sc
        inc screen_2
.rr_sc:
        ; totalb += 76800 (= $12C00: byte0=$00, byte1=$2C, byte2=$01)
        lda totalb_0
        clc
        adc #<BMP_SIZE_BYTES
        sta totalb_0
        lda totalb_1
        adc #>BMP_SIZE_BYTES
        sta totalb_1
        lda totalb_2
        adc #$01                 ; BMP_SIZE_BYTES bit16 byte ($12C00 -> $01)
        sta totalb_2
        ; alternate color for the next screen
        lda raw_color
        clc
        adc #$10
        sta raw_color
        jmp .rr_outer
.rr_timeup:
        rts

; =============================================================================
; PATCH_SMC: self-modifying code. Reads the slot base ($CN) the init program
; left in VERA_ZP+1 and writes it into the hi-byte operand of every hot
; fill store (each  sta VDATA0  ->  sta $CN03), turning a 6-cycle indirect
; store into a 4-cycle absolute one. Each fill body is 8x-unrolled, so
; smc_table entries are (start_addr, count) block patches: patch_smc writes
; $CN at start, start+3, start+6, ... for count stores (stride 3 = sizeof sta).
; Runs once at startup, AFTER VERA_ZP is set and BEFORE the first patched
; instruction (clear_bitmap) executes.
; =============================================================================
!zone patch_smc
patch_smc:
        lda VERA_ZP+1            ; $C1..$C7
        sta ps_cn
        ldx #NPATCH
        lda #<smc_table
        sta ZP_PTR
        lda #>smc_table
        sta ZP_PTR+1
.ps_entry:
        ; read entry: start_addr (2 bytes) -> ZP_PTR2, count (1 byte) -> ps_cnt
        ldy #$00
        lda (ZP_PTR),y           ; start lo
        sta ZP_PTR2
        iny
        lda (ZP_PTR),y           ; start hi
        sta ZP_PTR2+1
        iny
        lda (ZP_PTR),y           ; count
        sta ps_cnt
.ps_block:
        lda ps_cn
        ldy #$00
        sta (ZP_PTR2),y          ; overwrite hi operand -> $CN
        lda ZP_PTR2              ; advance to next store (stride 3)
        clc
        adc #$03
        sta ZP_PTR2
        lda ZP_PTR2+1
        adc #$00
        sta ZP_PTR2+1
        dec ps_cnt
        bne .ps_block
        ; advance to next table entry (3 bytes: 2 addr + 1 count)
        lda ZP_PTR
        clc
        adc #$03
        sta ZP_PTR
        lda ZP_PTR+1
        adc #$00
        sta ZP_PTR+1
        dex
        bne .ps_entry
        rts

; =============================================================================
; 24-bit math: DIV10_24 (shift-and-subtract long division) + PRINT_DEC24.
; =============================================================================

; DIV10_24: unsigned 24-bit divide by 10. Input div_in+0..+2 (LE). The
; quotient is returned in div_in (LE) and the remainder in 'rem'. Standard
; shift-and-subtract: the dividend register doubles as the quotient register.
!zone div10_24
div10_24:
        lda #$00
        sta rem
        ldx #24
.dv_bit:
        asl div_in+0             ; shift dividend left, MSB -> carry
        rol div_in+1
        rol div_in+2             ; old bit23 -> carry
        rol rem                  ; rem = (rem<<1) | carry, stays < 20
        lda rem
        cmp #10
        bcc .dv_noq              ; rem < 10 -> no quotient bit
        sbc #10                  ; carry still set from cmp -> rem -= 10
        sta rem
        inc div_in+0             ; set quotient bit (LSB is 0 after the asl)
.dv_noq:
        dex
        bne .dv_bit
        rts

; PRINT_DEC24: print the 24-bit value in dec_in+0..+2 (LE) as decimal on the
; Apple II screen via COUT. Leading zeros are suppressed (but a zero value
; prints a single '0'). Uses ZP_PTR2 to walk the power table.
!zone print_dec24
print_dec24:
        lda #<pow10
        sta ZP_PTR2
        lda #>pow10
        sta ZP_PTR2+1
        lda #$00
        sta pd_leading           ; 0 = still inside the leading-zero run
        ldx #8                   ; 8 power entries (1e7 down to 1e0)
.pd_power:
        lda #$00
        sta pd_digit
.pd_sub:
        ; try: dec_in -= (ZP_PTR2) (3 bytes). If borrow, undo and stop
        sec
        ldy #$00
        lda dec_in+0
        sbc (ZP_PTR2),y
        sta dec_in+0
        iny
        lda dec_in+1
        sbc (ZP_PTR2),y
        sta dec_in+1
        iny
        lda dec_in+2
        sbc (ZP_PTR2),y
        sta dec_in+2
        bcc .pd_back             ; borrow -> didn't fit, undo
        inc pd_digit
        jmp .pd_sub
.pd_back:
        clc
        ldy #$00
        lda dec_in+0
        adc (ZP_PTR2),y
        sta dec_in+0
        iny
        lda dec_in+1
        adc (ZP_PTR2),y
        sta dec_in+1
        iny
        lda dec_in+2
        adc (ZP_PTR2),y
        sta dec_in+2
        ; emit the digit (unless still leading and digit==0)
        lda pd_leading
        bne .pd_emit
        lda pd_digit
        beq .pd_skip             ; leading zero -> suppress
        inc pd_leading           ; first nonzero -> start emitting
.pd_emit:
        lda pd_digit
        ora #$B0                 ; '0'..'9' with high bit set for COUT
        stx pd_savex             ; COUT may clobber X
        jsr COUT
        ldx pd_savex
.pd_skip:
        ; advance power pointer by 3
        lda ZP_PTR2
        clc
        adc #$03
        sta ZP_PTR2
        lda ZP_PTR2+1
        adc #$00
        sta ZP_PTR2+1
        dex
        bne .pd_power
        ; if nothing was emitted (value was 0), print a single '0'
        lda pd_leading
        bne .pd_done
        lda #$B0
        jsr COUT
.pd_done:
        rts

; =============================================================================
; Result printing. Macros print one labeled value (count / bytes / rate) per
; line via a2_print (label) + print_dec24 (number) + COUT (CR). PRINTRATE
; divides the source by 10 first.
; =============================================================================

!macro PRINTVAL label, s0, s1, s2 {
        lda #<label
        sta ZP_PTR
        lda #>label
        sta ZP_PTR+1
        jsr a2_print
        lda s0
        sta dec_in+0
        lda s1
        sta dec_in+1
        lda s2
        sta dec_in+2
        jsr print_dec24
        lda #$8D                 ; CR (high bit set)
        jsr COUT
}

!macro PRINTRATE label, s0, s1, s2 {
        lda #<label
        sta ZP_PTR
        lda #>label
        sta ZP_PTR+1
        jsr a2_print
        lda s0
        sta div_in+0
        lda s1
        sta div_in+1
        lda s2
        sta div_in+2
        jsr div10_24
        lda div_in+0
        sta dec_in+0
        lda div_in+1
        sta dec_in+1
        lda div_in+2
        sta dec_in+2
        jsr print_dec24
        lda #$8D
        jsr COUT
}

!zone print_box_results
print_box_results:
        +PRINTVAL lab_boxes, boxcount_0, boxcount_1, boxcount_2
        +PRINTVAL lab_bytes, totalb_0, totalb_1, totalb_2
        +PRINTRATE lab_rate, totalb_0, totalb_1, totalb_2
        rts

!zone print_raw_results
print_raw_results:
        +PRINTVAL lab_fills, screen_0, screen_1, screen_2
        +PRINTVAL lab_bytes, totalb_0, totalb_1, totalb_2
        +PRINTRATE lab_rate, totalb_0, totalb_1, totalb_2
        rts


!source "a2vera/vera_common.inc"

; =============================================================================
; Data: messages + scratch variables. All absolute (non-ZP). The only thing
; in zero page is VERA_ZP ($0A) plus vera_common.inc's ZP_PTR/ZP_PTR2.
; =============================================================================

; --- messages (Apple II's own screen, <= 40 cols) ---------------------------
msg_start:
        !text "VERA BENCHMARK"
        !byte 13
        !text "10S, 8BPP, 320X240"
        !byte 13, 0

msg_run1:
        !text "BOXES 32X32"          ; NOTE: must match BOX_W/BOX_H above
        !byte 13, 0

msg_run2:
        !text "RAW FILL"
        !byte 13, 0

msg_done:
        !text "DONE. PRESS ANY KEY."
        !byte 13, 0

msg_nomagic:
        !text "VERA MODULE MUST BE INITIALIZED"
        !byte 13
        !text "BEFORE RUNNING THIS PROGRAM."
        !byte 13, 0

; result-line labels (printed before each number by PRINTVAL/PRINTRATE)
lab_boxes: !text "BOXES ", 0
lab_fills: !text "FILLS ", 0
lab_bytes: !text "BYTES ", 0
lab_rate:  !text "BYTES/S ", 0

; --- power-of-10 table for print_dec24 (8 entries x 3 bytes, LE) -----------
; covers the full 24-bit range (0 .. 16777215). Our values peak near ~1.7M.
pow10:
        !byte $80,$96,$98    ; 10000000
        !byte $40,$42,$0F    ; 1000000
        !byte $A0,$86,$01    ; 100000
        !byte $10,$27,$00    ; 10000
        !byte $E8,$03,$00    ; 1000
        !byte $64,$00,$00    ; 100
        !byte $0A,$00,$00    ; 10
        !byte $01,$00,$00    ; 1

; --- SMC patch table (block entries: start_addr + count) --------------------
; Each entry = { !word start_addr, !byte count } where start_addr points at
; the hi-byte operand of the first  sta VDATA0  in an 8x-unrolled block, and
; count is the number of stores (8). patch_smc writes $CN at start_addr,
; start_addr+3, start_addr+6, ... (stride 3 = sizeof absolute sta).
NPATCH = 3
smc_table:
        !word sclr_fill+2
        !byte 8
        !word sbox_fill+2
        !byte 8
        !word sraw_fill+2
        !byte 8
ps_cn:  !byte 0
ps_cnt: !byte 0

; --- timing + counters ------------------------------------------------------
frames_lo:  !byte 0
frames_hi:  !byte 0

boxcount_0: !byte 0
boxcount_1: !byte 0
boxcount_2: !byte 0

screen_0:   !byte 0
screen_1:   !byte 0
screen_2:   !byte 0

totalb_0:   !byte 0
totalb_1:   !byte 0
totalb_2:   !byte 0

; --- box-draw state ---------------------------------------------------------
cur_x_lo:   !byte 0
cur_x_hi:   !byte 0
cur_y:      !byte 0
box_color:  !byte 0
rows_left:  !byte 0
rbase_lo:   !byte 0
rbase_hi:   !byte 0
rbase_b16:  !byte 0
t_lo:       !byte 0
t_hi:       !byte 0
a_lo:       !byte 0
a_hi:       !byte 0
a_b16:      !byte 0

; --- raw-fill state ---------------------------------------------------------
pages_lo:   !byte 0
pages_hi:   !byte 0
fill_color: !byte 0
raw_color:  !byte 0

; --- clear_bitmap 16-bit page counter ---------------------------------------
cb_pages:   !byte 0, 0

; --- print_dec24 / div10_24 scratch -----------------------------------------
dec_in:     !byte 0, 0, 0
div_in:     !byte 0, 0, 0
rem:        !byte 0
pd_leading: !byte 0
pd_digit:   !byte 0
pd_savex:   !byte 0
