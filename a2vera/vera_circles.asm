; vera_circles.asm: Filled-circle benchmark, Apple II+VERA
;
; Continuously draws filled circles of random size (20-80px radius), random
; position, and random color on a 320x240 8bpp (256-color) VERA bitmap,
; until a key is pressed. Ported from the C64 and AGFA 68020 versions, which
; use the same midpoint/Bresenham filled-circle algorithm (no hardware
; multiply needed).
;
; PRNG seed: the Apple II has no free-running timer, so the seed comes from
; VERA's current-scanline register (offset $08, read-only), which reflects
; VERA's internal timing at the exact moment the program reaches seed_rng.
; It varies run to run with disk load time and DOS internal state.

!cpu 6502

; --- Bitmap geometry (8bpp) --------------------------------------------------

BMP_WIDTH       = 320
BMP_HEIGHT      = 240
BMP_STRIDE      = 320
BMP_SIZE_BYTES  = 76800        ; 320*240

; --- Circle limits ------------------------------------------------------------

MIN_RADIUS      = 20
MAX_RADIUS      = 80

; --- VERA addressing: slot-agnostic via the init program's magic block ------
; Requires an init program (INIT-VGA, INIT-NTSC or INIT-RGB) to have been
; BRUN first. It autodetects VERA's slot, initializes it (composer, palette,
; font) and publishes the slot at $0300:
; $0300=$A2, $0301=$56, $0303=base hi ($C1..$C7). We read the base and address
; VERA through a runtime zero-page pointer (VERA_ZP) with (ptr),Y, so this runs
; in WHATEVER slot init found. We do NO reset/video/palette setup (only the
; bitmap-mode switch) and reuse the palette init already uploaded.
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
OFS_SCANLN  = $08             ; current scanline lo (read), PRNG seed
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
        jsr a2_print            ; print on Apple II's own screen

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
        ; that palette, fade to black, switch to 8bpp bitmap + clear it,
        ; then fade back up to reveal the cleared screen.
        jsr save_pal_orig       ; palette_data -> pal_orig (fade_up target)
        jsr fade_to_black       ; fade IN (1/2): darken before drawing
        jsr enter_bitmap_mode
        jsr clear_bitmap
        jsr fade_up             ; fade IN (2/2): bring palette back up

        jsr seed_rng

        lda #<msg_running
        sta ZP_PTR
        lda #>msg_running
        sta ZP_PTR+1
        jsr a2_print

!zone main_loop
main_loop:
        jsr a2_keypressed
        bne .key_exit           ; Z=0 means key pressed -> exit

        jsr draw_random_circle
        jmp main_loop

.key_exit:
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
        jmp $03D0               ; return to DOS (never RTS)

no_magic:
        lda #<msg_nomagic
        sta ZP_PTR
        lda #>msg_nomagic
        sta ZP_PTR+1
        jsr a2_print
        jsr a2_clear_basic
        jmp $03D0


; =============================================================================
; ENTER_BITMAP_MODE: Layer 0 = 320x240 8bpp bitmap @ VRAM $00000
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
; CLEAR_BITMAP: write 76800 zero bytes starting at VRAM $00000
; Same indirect-addressing idiom as copy_pages_to_vera, but the source is a
; constant $00 instead of a RAM pointer. 76800 = 300 pages of 256 bytes.
; =============================================================================
!zone clear_bitmap
clear_bitmap:
        +VSET OFS_ADDR0_L, $00
        +VSET OFS_ADDR0_M, $00
        +VSET OFS_ADDR0_H, $10  ; bit16=0, stride=+1

        lda #$2C
        sta clear_pages_lo      ; 76800 / 256 = 300 = $012C
        lda #$01
        sta clear_pages_hi
.outer:
        ldx #$00                ; X counts the 256-byte page
.inner: lda #$00
cbm_st: sta VDATA0              ; DATA0, absolute (patched by patch_smc)
        inx
        bne .inner
        ; decrement 16-bit page counter (clear_pages_hi:clear_pages_lo)
        lda clear_pages_lo
        bne .dec_lo
        dec clear_pages_hi
.dec_lo:
        dec clear_pages_lo
        lda clear_pages_lo
        ora clear_pages_hi
        bne .outer
        rts


; =============================================================================
; SEED_RNG: seed xorshift32 state from VERA's current-scanline register.
; The Apple II has no jiffy clock or free-running timer. VERA's scanline
; counter (offset $08, read-only) reflects VERA's internal display timing
; at the exact moment we read it. Combined with fixed nonzero bytes to
; guarantee a valid (nonzero) seed regardless of scanline value.
; =============================================================================
!zone seed_rng
seed_rng:
        ldy #OFS_SCANLN
        lda (VERA_ZP),y         ; current scanline low byte (0-255)
        sta rng0
        lda #$AD
        sta rng1
        lda #$BE
        sta rng2
        lda #$EF
        sta rng3

        ; If all four bytes happen to be zero (scanline was $00 and the
        ; fixed bytes XOR'd to zero, which can't happen with these constants,
        ; but belt-and-suspenders), fall back.
        lda rng0
        ora rng1
        ora rng2
        ora rng3
        bne .seeded
        lda #$EF
        sta rng0
.seeded:
        rts


; =============================================================================
; RNG_NEXT: xorshift32: x ^= x<<13; x ^= x>>17; x ^= x<<5
; In/out: rng_state (rng0..rng3, little-endian). Result also left in
; rng0..rng3 after return (callers read whichever bytes they need).
; =============================================================================
!zone rng_next
rng_next:
        ; --- x ^= x << 13  (= shift left 8, then shift left 5) ---
        ; shift-left-8 on a 32-bit value is just a byte move (with the
        ; vacated low byte becoming 0).
        lda rng2
        sta rng_t3
        lda rng1
        sta rng_t2
        lda rng0
        sta rng_t1
        lda #$00
        sta rng_t0
        ; now shift rng_t (=x<<8) left by 5 more bits -> total <<13
        ldx #5
.sl5:   asl rng_t0
        rol rng_t1
        rol rng_t2
        rol rng_t3
        dex
        bne .sl5
        ; x ^= (x<<13)
        lda rng0
        eor rng_t0
        sta rng0
        lda rng1
        eor rng_t1
        sta rng1
        lda rng2
        eor rng_t2
        sta rng2
        lda rng3
        eor rng_t3
        sta rng3

        ; --- x ^= x >> 17  (= shift right 16, then shift right 1) ---
        ; shift-right-16 is a byte move: low word <- high word, high word <- 0
        lda rng2
        sta rng_t0
        lda rng3
        sta rng_t1
        lda #$00
        sta rng_t2
        sta rng_t3
        ; shift rng_t right by 1 more bit -> total >>17
        lsr rng_t3
        ror rng_t2
        ror rng_t1
        ror rng_t0
        ; x ^= (x>>17)
        lda rng0
        eor rng_t0
        sta rng0
        lda rng1
        eor rng_t1
        sta rng1
        lda rng2
        eor rng_t2
        sta rng2
        lda rng3
        eor rng_t3
        sta rng3

        ; --- x ^= x << 5 ---
        lda rng0
        sta rng_t0
        lda rng1
        sta rng_t1
        lda rng2
        sta rng_t2
        lda rng3
        sta rng_t3
        ldx #5
.sl5b:  asl rng_t0
        rol rng_t1
        rol rng_t2
        rol rng_t3
        dex
        bne .sl5b
        lda rng0
        eor rng_t0
        sta rng0
        lda rng1
        eor rng_t1
        sta rng1
        lda rng2
        eor rng_t2
        sta rng2
        lda rng3
        eor rng_t3
        sta rng3

        rts


; =============================================================================
; MOD16: 16-bit repeated-subtraction modulo (stands in for 68k's DIVU,
; which the 6502 doesn't have). Used once per circle to pick a random
; coordinate within a range. It doesn't need to be fast.
; In:  mod_a_lo/hi = dividend, mod_b_lo/hi = divisor (> 0)
; Out: mod_a_lo/hi = dividend mod divisor
; =============================================================================
!zone mod16
mod16:
.loop:
        ; if mod_a < mod_b, done
        lda mod_a_hi
        cmp mod_b_hi
        bcc .done               ; a_hi < b_hi -> a < b
        bne .sub                ; a_hi > b_hi -> a >= b, subtract
        lda mod_a_lo
        cmp mod_b_lo
        bcc .done               ; hi equal, a_lo < b_lo -> a < b
.sub:
        lda mod_a_lo
        sec
        sbc mod_b_lo
        sta mod_a_lo
        lda mod_a_hi
        sbc mod_b_hi
        sta mod_a_hi
        jmp .loop
.done:
        rts


; =============================================================================
; DRAW_RANDOM_CIRCLE: pick random radius/center/color, draw one filled
; circle. Direct port of the AGFA DRAW_RANDOM_CIRCLE, with DIVU replaced by
; mod16 (see above).
; =============================================================================
!zone draw_random_circle
draw_random_circle:
        ; color = rng_byte + 1 (8-bit wraparound, matches the AGFA .b math)
        jsr rng_next
        lda rng0
        clc
        adc #1
        sta circ_color

        ; radius_pre = zext16(rng_byte) + 1   (range 1..256)
        jsr rng_next
        lda rng0
        sta circ_radius_lo
        lda #$00
        sta circ_radius_hi
        inc circ_radius_lo
        bne .noinc
        inc circ_radius_hi
.noinc:
        ; radius = radius_pre + (MIN_RADIUS-1), clamp to MAX_RADIUS
        lda circ_radius_lo
        clc
        adc #(MIN_RADIUS-1)
        sta circ_radius_lo
        lda circ_radius_hi
        adc #$00
        sta circ_radius_hi
        ; if radius > MAX_RADIUS (that is, hi!=0 or lo>MAX_RADIUS), clamp
        lda circ_radius_hi
        bne .clamp
        lda circ_radius_lo
        cmp #(MAX_RADIUS+1)
        bcc .rad_ok             ; lo < 81 -> within range, no clamp
.clamp:
        lda #MAX_RADIUS
        sta circ_radius_lo
        lda #$00
        sta circ_radius_hi
.rad_ok:
        ; radius fits in a byte (20..80), keep a byte copy for later use
        lda circ_radius_lo
        sta circ_radius

        ; --- pick cx ---
        ; range = BMP_WIDTH - 2*radius (16-bit). If <= 0, cx = BMP_WIDTH/2
        lda #<BMP_WIDTH
        sta mod_b_lo
        lda #>BMP_WIDTH
        sta mod_b_hi
        lda mod_b_lo
        sec
        sbc circ_radius_lo
        sta mod_b_lo
        lda mod_b_hi
        sbc circ_radius_hi
        sta mod_b_hi
        lda mod_b_lo
        sec
        sbc circ_radius_lo
        sta mod_b_lo
        lda mod_b_hi
        sbc circ_radius_hi
        sta mod_b_hi
        ; mod_b = range, check <= 0 (hi bit set, that is, negative as signed16,
        ; or both bytes zero)
        lda mod_b_hi
        bmi .cx_zero
        ora mod_b_lo
        beq .cx_zero

        jsr rng_next
        lda rng0
        sta mod_a_lo
        lda rng1
        sta mod_a_hi
        jsr mod16
        lda mod_a_lo
        clc
        adc circ_radius_lo
        sta circ_cx_lo
        lda mod_a_hi
        adc circ_radius_hi
        sta circ_cx_hi
        jmp .cx_done
.cx_zero:
        lda #<(BMP_WIDTH/2)
        sta circ_cx_lo
        lda #>(BMP_WIDTH/2)
        sta circ_cx_hi
.cx_done:

        ; --- pick cy ---
        lda #<BMP_HEIGHT
        sta mod_b_lo
        lda #>BMP_HEIGHT
        sta mod_b_hi
        lda mod_b_lo
        sec
        sbc circ_radius_lo
        sta mod_b_lo
        lda mod_b_hi
        sbc circ_radius_hi
        sta mod_b_hi
        lda mod_b_lo
        sec
        sbc circ_radius_lo
        sta mod_b_lo
        lda mod_b_hi
        sbc circ_radius_hi
        sta mod_b_hi
        lda mod_b_hi
        bmi .cy_zero
        ora mod_b_lo
        beq .cy_zero

        jsr rng_next
        lda rng0
        sta mod_a_lo
        lda rng1
        sta mod_a_hi
        jsr mod16
        lda mod_a_lo
        clc
        adc circ_radius_lo
        sta circ_cy_lo
        lda mod_a_hi
        adc circ_radius_hi
        sta circ_cy_hi
        jmp .cy_done
.cy_zero:
        lda #<(BMP_HEIGHT/2)
        sta circ_cy_lo
        lda #>(BMP_HEIGHT/2)
        sta circ_cy_hi
.cy_done:

        jsr draw_filled_circle
        rts


; =============================================================================
; DRAW_FILLED_CIRCLE: midpoint/Bresenham filled circle, direct port of the
; AGFA algorithm (no multiply, adds/subtracts/shifts only).
;
; In: circ_cx_lo/hi, circ_cy_lo/hi, circ_radius_lo/hi, circ_color
;
;   dx = 0, dy = radius, d = 1 - radius
;   loop while dx <= dy:
;     span y=cy-dy, x=cx-dx..cx+dx
;     span y=cy+dy, x=cx-dx..cx+dx
;     span y=cy-dx, x=cx-dy..cx+dy
;     span y=cy+dx, x=cx-dy..cx+dy
;     dx++
;     if d < 0: d += 2*dx_old + 1
;     else:     dy--; d += 2*(dx_old - dy) + 1
; =============================================================================
!zone draw_filled_circle
draw_filled_circle:
        lda circ_radius_lo
        sta mp_dy_lo
        lda circ_radius_hi
        sta mp_dy_hi
        lda #$00
        sta mp_dx_lo
        sta mp_dx_hi

        ; d = 1 - radius
        lda #1
        sec
        sbc circ_radius_lo
        sta mp_d_lo
        lda #0
        sbc circ_radius_hi
        sta mp_d_hi

.mp_loop:
        ; while dx <= dy
        lda mp_dx_hi
        cmp mp_dy_hi
        bne .cmp_done
        lda mp_dx_lo
        cmp mp_dy_lo
.cmp_done:
        ; carry clear means dx > dy (borrow occurred) -> done
        bcc .continue
        beq .continue            ; dx == dy still valid (<=)
        jmp .mp_done
.continue:

        ; span 1: y = cy - dy, x1 = cx - dx, x2 = cx + dx
        lda circ_cx_lo
        sec
        sbc mp_dx_lo
        sta span_x1_lo
        lda circ_cx_hi
        sbc mp_dx_hi
        sta span_x1_hi
        lda circ_cx_lo
        clc
        adc mp_dx_lo
        sta span_x2_lo
        lda circ_cx_hi
        adc mp_dx_hi
        sta span_x2_hi
        lda circ_cy_lo
        sec
        sbc mp_dy_lo
        sta span_y_lo
        lda circ_cy_hi
        sbc mp_dy_hi
        sta span_y_hi
        jsr fill_span_8

        ; span 2: y = cy + dy, x1 = cx - dx, x2 = cx + dx
        lda circ_cx_lo
        sec
        sbc mp_dx_lo
        sta span_x1_lo
        lda circ_cx_hi
        sbc mp_dx_hi
        sta span_x1_hi
        lda circ_cx_lo
        clc
        adc mp_dx_lo
        sta span_x2_lo
        lda circ_cx_hi
        adc mp_dx_hi
        sta span_x2_hi
        lda circ_cy_lo
        clc
        adc mp_dy_lo
        sta span_y_lo
        lda circ_cy_hi
        adc mp_dy_hi
        sta span_y_hi
        jsr fill_span_8

        ; span 3: y = cy - dx, x1 = cx - dy, x2 = cx + dy
        lda circ_cx_lo
        sec
        sbc mp_dy_lo
        sta span_x1_lo
        lda circ_cx_hi
        sbc mp_dy_hi
        sta span_x1_hi
        lda circ_cx_lo
        clc
        adc mp_dy_lo
        sta span_x2_lo
        lda circ_cx_hi
        adc mp_dy_hi
        sta span_x2_hi
        lda circ_cy_lo
        sec
        sbc mp_dx_lo
        sta span_y_lo
        lda circ_cy_hi
        sbc mp_dx_hi
        sta span_y_hi
        jsr fill_span_8

        ; span 4: y = cy + dx, x1 = cx - dy, x2 = cx + dy
        lda circ_cx_lo
        sec
        sbc mp_dy_lo
        sta span_x1_lo
        lda circ_cx_hi
        sbc mp_dy_hi
        sta span_x1_hi
        lda circ_cx_lo
        clc
        adc mp_dy_lo
        sta span_x2_lo
        lda circ_cx_hi
        adc mp_dy_hi
        sta span_x2_hi
        lda circ_cy_lo
        clc
        adc mp_dx_lo
        sta span_y_lo
        lda circ_cy_hi
        adc mp_dx_hi
        sta span_y_hi
        jsr fill_span_8

        ; dx_old = dx (before increment), saved for the decision update
        lda mp_dx_lo
        sta mp_dxold_lo
        lda mp_dx_hi
        sta mp_dxold_hi

        ; dx++
        inc mp_dx_lo
        bne .noincdx
        inc mp_dx_hi
.noincdx:

        ; if d < 0 (mp_d_hi bit7 set): d += 2*dx_old + 1
        lda mp_d_hi
        bmi .d_neg
        jmp .d_pos
.d_neg:
        lda mp_dxold_lo
        sta mp_tmp_lo
        lda mp_dxold_hi
        sta mp_tmp_hi
        asl mp_tmp_lo
        rol mp_tmp_hi             ; mp_tmp = 2*dx_old
        lda mp_tmp_lo
        clc
        adc #1
        sta mp_tmp_lo
        lda mp_tmp_hi
        adc #0
        sta mp_tmp_hi             ; mp_tmp = 2*dx_old + 1
        lda mp_d_lo
        clc
        adc mp_tmp_lo
        sta mp_d_lo
        lda mp_d_hi
        adc mp_tmp_hi
        sta mp_d_hi
        jmp .mp_update_done
.d_pos:
        ; dy--
        lda mp_dy_lo
        bne .nodecdy
        dec mp_dy_hi
.nodecdy:
        dec mp_dy_lo
        ; mp_tmp = dx_old - dy  (signed 16-bit subtraction)
        lda mp_dxold_lo
        sec
        sbc mp_dy_lo
        sta mp_tmp_lo
        lda mp_dxold_hi
        sbc mp_dy_hi
        sta mp_tmp_hi
        asl mp_tmp_lo
        rol mp_tmp_hi             ; mp_tmp = 2*(dx_old - dy)
        lda mp_tmp_lo
        clc
        adc #1
        sta mp_tmp_lo
        lda mp_tmp_hi
        adc #0
        sta mp_tmp_hi             ; + 1
        lda mp_d_lo
        clc
        adc mp_tmp_lo
        sta mp_d_lo
        lda mp_d_hi
        adc mp_tmp_hi
        sta mp_d_hi
.mp_update_done:
        jmp .mp_loop

.mp_done:
        rts


; =============================================================================
; FILL_SPAN_8: 8bpp horizontal span fill, 1 byte per pixel.
; In: span_x1_lo/hi, span_x2_lo/hi, span_y_lo/hi, circ_color
; Fills the inclusive span [x1,x2] on scanline y. x1/x2 are swapped first if
; x1 > x2. Address = y*BMP_STRIDE + x1, with y*320 computed as
; (y<<8) + (y<<6), shifts and adds only, since y is a fixed-stride
; multiply, not a generic one.
; =============================================================================
!zone fill_span_8
fill_span_8:
        ; ensure x1 <= x2 (swap if needed)
        lda span_x1_hi
        cmp span_x2_hi
        bne .chkswap
        lda span_x1_lo
        cmp span_x2_lo
.chkswap:
        bcc .ordered              ; x1 < x2 (or hi byte already decided <)
        beq .ordered              ; x1 == x2
        ; swap
        lda span_x1_lo
        ldx span_x2_lo
        sta span_x2_lo
        stx span_x1_lo
        lda span_x1_hi
        ldx span_x2_hi
        sta span_x2_hi
        stx span_x1_hi
.ordered:

        ; span clipping: skip entirely off-bitmap spans, then clamp to
        ; [0, BMP_WIDTH-1] / [0, BMP_HEIGHT-1]. Circles near the edge can
        ; otherwise produce negative or >=320/>=240 coordinates.
        ; (long-branch workaround throughout: .done is >127 bytes away)
        lda span_y_hi
        bpl .y_not_neg            ; y < 0 -> off-bitmap, skip
        jmp .done
.y_not_neg:
        lda span_y_lo
        cmp #BMP_HEIGHT
        bcc .y_in_range           ; y >= 240 -> off-bitmap (hi already 0)
        jmp .done
.y_in_range:
        lda span_y_hi
        beq .y_ok                 ; y_hi nonzero and not caught above -> too big
        jmp .done
.y_ok:

        ; if x2 < 0, nothing visible
        lda span_x2_hi
        bpl .x2_not_neg
        jmp .done
.x2_not_neg:

        ; clamp x1 to 0 if negative
        lda span_x1_hi
        bpl .x1ok
        lda #$00
        sta span_x1_lo
        sta span_x1_hi
.x1ok:
        ; clamp x2 to BMP_WIDTH-1 (319=$013F) if x2 >= BMP_WIDTH (320=$0140).
        ; Must be a proper 16-bit compare: hi==$01 is valid if lo < $40.
        lda span_x2_hi
        cmp #>BMP_WIDTH           ; compare hi with $01
        bcc .x2ok                 ; hi < $01 -> x2 < 256 -> in range
        bne .clampx2              ; hi > $01 -> x2 >= 512 -> clamp
        lda span_x2_lo            ; hi == $01: valid only when lo < $40
        cmp #<BMP_WIDTH
        bcc .x2ok                 ; lo < $40 -> x2 < 320 -> in range
.clampx2:
        lda #<(BMP_WIDTH-1)
        sta span_x2_lo
        lda #>(BMP_WIDTH-1)
        sta span_x2_hi
.x2ok:
        ; if (after clamping) x1 > x2, nothing to draw
        lda span_x1_hi
        cmp span_x2_hi
        bne .chkempty
        lda span_x1_lo
        cmp span_x2_lo
.chkempty:
        bcc .notempty
        beq .notempty
        jmp .done
.notempty:

        ; count = x2 - x1 + 1
        lda span_x2_lo
        sec
        sbc span_x1_lo
        sta fs_count_lo
        lda span_x2_hi
        sbc span_x1_hi
        sta fs_count_hi
        inc fs_count_lo
        bne .nocarry
        inc fs_count_hi
.nocarry:

        ; addr16 = (y<<8) + (y<<6) + x1   (low 16 bits, bit16 handled below)
        lda span_y_lo              ; y is 0..239, fits a byte
        sta fs_addr_hi             ; y<<8 -> just place y in high byte
        lda #$00
        sta fs_addr_lo

        ; fs_tmp (16-bit) = y << 6
        lda span_y_lo
        sta fs_tmp_lo
        lda #$00
        sta fs_tmp_hi
        asl fs_tmp_lo
        rol fs_tmp_hi
        asl fs_tmp_lo
        rol fs_tmp_hi
        asl fs_tmp_lo
        rol fs_tmp_hi
        asl fs_tmp_lo
        rol fs_tmp_hi
        asl fs_tmp_lo
        rol fs_tmp_hi
        asl fs_tmp_lo
        rol fs_tmp_hi              ; fs_tmp = y*64

        lda fs_addr_lo
        clc
        adc fs_tmp_lo
        sta fs_addr_lo
        lda fs_addr_hi
        adc fs_tmp_hi
        sta fs_addr_hi             ; fs_addr = y*320 (low 16 bits only)
        lda #$00
        adc #$00
        sta fs_addr_bit16          ; carry out from y*320 = VRAM bit16 (set when y >= 205)

        lda fs_addr_lo
        clc
        adc span_x1_lo
        sta fs_addr_lo
        lda fs_addr_hi
        adc span_x1_hi
        sta fs_addr_hi             ; fs_addr += x1
        lda fs_addr_bit16
        adc #$00
        sta fs_addr_bit16          ; propagate any carry from x1 add into bit16

        ; program VERA_ADDR0 = fs_addr (17-bit), stride +1
        ldy #OFS_CTRL
        lda #$00
        sta (VERA_ZP),y
        ldy #OFS_ADDR0_L
        lda fs_addr_lo
        sta (VERA_ZP),y
        ldy #OFS_ADDR0_M
        lda fs_addr_hi
        sta (VERA_ZP),y
        ldy #OFS_ADDR0_H
        lda fs_addr_bit16
        ora #$10                   ; bit16 in bit0, stride=+1 in bits4-7
        sta (VERA_ZP),y

        lda circ_color
        sta fs_color

        ; write count bytes of color (count = fs_count, 1..320, never 0)
        lda fs_count_hi
        beq .lastpage
        ; full 256-byte pages first (X counts each page)
.pageloop:
        ldx #$00
.byteloop:
        lda fs_color
fsp_st: sta VDATA0                 ; DATA0, absolute (patched by patch_smc)
        inx
        bne .byteloop
        dec fs_count_hi
        bne .pageloop
.lastpage:
        ldx fs_count_lo
        beq .done
.tailloop:
        lda fs_color
fst_st: sta VDATA0                 ; DATA0, absolute (patched by patch_smc)
        dex
        bne .tailloop

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
        sta cbm_st+2             ; clear_bitmap
        sta fsp_st+2             ; fill_span, full pages
        sta fst_st+2             ; fill_span, tail
        rts

!source "a2vera/vera_common.inc"

; =============================================================================
; Data
; =============================================================================

; Printed on the Apple II's OWN screen via COUT. Messages kept <= 40 chars.
msg_start:
        !text "VERA CIRCLE BENCHMARK."
        !byte 13
        !text "8BPP BITMAP MODE (320X240) ON VERA."
        !byte 13, 0

msg_running:
        !text "CIRCLES RUNNING. PRESS ANY KEY."
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

; --- PRNG state (xorshift32), little-endian, absolute (not zero page) -------
rng0: !byte 0
rng1: !byte 0
rng2: !byte 0
rng3: !byte 0

; scratch for rng_next's shifted copies
rng_t0: !byte 0
rng_t1: !byte 0
rng_t2: !byte 0
rng_t3: !byte 0

; --- mod16 operands -----------------------------------------------------------
mod_a_lo: !byte 0
mod_a_hi: !byte 0
mod_b_lo: !byte 0
mod_b_hi: !byte 0

; --- clear_bitmap page counter -----------------------------------------------
clear_pages_lo: !byte 0
clear_pages_hi: !byte 0

; --- random circle parameters -------------------------------------------------
circ_radius_lo: !byte 0
circ_radius_hi: !byte 0
circ_radius:    !byte 0   ; byte copy, 20..80
circ_cx_lo: !byte 0
circ_cx_hi: !byte 0
circ_cy_lo: !byte 0
circ_cy_hi: !byte 0
circ_color: !byte 0

; --- midpoint circle algorithm working state ---------------------------------
mp_dx_lo: !byte 0
mp_dx_hi: !byte 0
mp_dy_lo: !byte 0
mp_dy_hi: !byte 0
mp_dxold_lo: !byte 0
mp_dxold_hi: !byte 0
mp_d_lo: !byte 0
mp_d_hi: !byte 0
mp_tmp_lo: !byte 0
mp_tmp_hi: !byte 0

; --- span-fill working state --------------------------------------------------
span_x1_lo: !byte 0
span_x1_hi: !byte 0
span_x2_lo: !byte 0
span_x2_hi: !byte 0
span_y_lo: !byte 0
span_y_hi: !byte 0

fs_count_lo: !byte 0
fs_count_hi: !byte 0
fs_addr_lo: !byte 0
fs_addr_hi: !byte 0
fs_addr_bit16: !byte 0
fs_tmp_lo: !byte 0
fs_tmp_hi: !byte 0
fs_color: !byte 0
