; vera_common.inc: Shared VERA + Apple II Monitor helpers for a2vera programs
;
; !source this into a program with `!source "a2vera/vera_common.inc"`.
; Ported from the C64 and AGFA 68020 versions. The VERA chip and VRAM layout
; are identical on every host, only the address map, zero-page conventions,
; and ROM API differ.
;
; Scoped narrowly to hardware plumbing only (register access, VGA composer
; setup, palette upload/fade, generic page copy, Apple II text output +
; non-blocking keypress). Demo-specific content (shape drawing, circle
; algorithms, PRNG, audio, grid drawing, color cycling) stays in each
; program.
;
; Constraints baked into this file:
;   - VERA base is DYNAMIC: every VERA access here goes through (VERA_ZP),Y
;     indirect, where VERA_ZP ($0A/$0B) holds $CN00 for whatever slot
;     the init program autodetected. The caller MUST set VERA_ZP before
;     any routine below that touches VERA (save_pal_orig is RAM-only and
;     does not need it, upload_palette_data, fade_to_black, fade_up do).
;   - VGA mode only, 640x480 / 80x30 text grid, the documented AGFA
;     factory default. Every register value here is hardcoded, no NVRAM.
;   - The Apple II's own screen is a status console only (Monitor COUT).
;     Real graphics/audio happen on VERA's VGA output.
;   - VSYNC IRQ timing is NOT used by anything in this file. The VERA IRQ
;     line is wired to the Apple II IRQ line. Timed programs poll VERA_ISR
;     (offset $07, bit 0) or install their own ISR. This file's
;     fade_to_black/fade_up just run their 16 steps back to back, as fast
;     as the CPU allows.
;
; Zero page: only ZP_PTR ($06/$07) and ZP_PTR2 ($08/$09) are used, the
; classic Apple II Monitor/Apple-assembly-pak safe indirect-pointer cells.
; Avoid $24/$25 (CH/CV cursor), $26/$27 (GBAS graphics base), $28-$2F
; (text window/scroll pointers), $3C-$3F (Monitor scratch). If your demo
; needs more scratch bytes, use labeled absolute storage (my_var: !byte 0)
; in your data section. The 6502 doesn't need zero page for plain LDA/STA.

!cpu 6502

; --- VERA register offset map (reference only, routines use inline literals) -
; VERA is addressed at runtime via (VERA_ZP),Y with Y = offset. VERA_ZP is
; NOT defined here. Each client defines it (= $0A) and loads $CN00 into it
; after the magic-block check. Offsets (same on every host):
;   $00 ADDR0_L   $01 ADDR0_M   $02 ADDR0_H   $03 DATA0   $04 DATA1
;   $05 CTRL      $06 IEN       $07 ISR       $08 IRQLINE_L (w) / scanline (r)
;   $09-$0C DC_VIDEO / DC_HSCALE / DC_VSCALE / DC_BORDER (DCSEL=0)
;          or DC_HSTART / DC_HSTOP / DC_VSTART / DC_VSTOP (DCSEL=1)
;   $0D L0_CONFIG  $0E L0_MAPBASE  $0F L0_TILEBASE
;   $10/$11 L0_HSCROLL_L/H    $12/$13 L0_VSCROLL_L/H
;   $14-$17 L1_* (mirror of $0D-$10)    $1B AUDIO_CTRL

; --- Apple II hardware + Monitor ROM ------------------------------------------

KBD              = $C000       ; read: last key | $80 if pressed
KBDSTRB          = $C010       ; write any value: clear keyboard strobe
COUT             = $FDED       ; Monitor char-out: A = char (high bit set), via CSW hook

; --- Zero page ---------------------------------------------------------------

ZP_PTR    = $06   ; 2 bytes: indirect-addressing pointer (copy/print/fade)
ZP_PTR2   = $08   ; 2 bytes: second indirect pointer, used only by fade_up

; NOTE: this ACME build needs an explicit !zone before each routine that
; uses local (dot-prefixed) labels. Plain global labels do NOT reset
; local-label scope by themselves. Without the !zone you get "Symbol already
; defined" as soon as two routines reuse a name like .loop or .done.
; Carry this pattern into every demo-specific routine you write too.

; =============================================================================
; FADE_TO_BLACK / FADE_UP: 16 steps, mutating palette_data in place and
; uploading it to VERA after every step. No VSYNC wait, so it runs as fast as
; the CPU allows (this file does not install an ISR, timed programs handle
; their own VSYNC gating at the call site if they want it).
; Entry 0 is skipped (stays black), same as the AGFA version.
;
; The outer 16-step counter uses a memory byte (fade_steps_left), not X.
; fade_to_black_1/fade_up_1 (and upload_palette_data, which they call)
; always return with X=0, since their own inner loops only exit when X hits 0.
; An outer `ldx #16` with a `dex` after the JSR would never terminate: the
; dex would always see X=0 and produce $FF. If you add another routine with
; an outer "call this N times" loop around something that uses X internally,
; use a memory counter, not X.
; =============================================================================

; =============================================================================
; SAVE_PAL_ORIG: copy palette_data -> pal_orig (call once before fading,
; so fade_up has an undamaged target to fade back up to). Pure RAM->RAM
; copy, no VERA access. Clobbers A/X/Y and ZP_PTR/ZP_PTR2.
; =============================================================================
!zone save_pal_orig
save_pal_orig:
        lda #<palette_data
        sta ZP_PTR
        lda #>palette_data
        sta ZP_PTR+1
        lda #<pal_orig
        sta ZP_PTR2
        lda #>pal_orig
        sta ZP_PTR2+1
        ldx #2                   ; 2 pages = 512 bytes
.page:  ldy #$00
.byte:  lda (ZP_PTR),y
        sta (ZP_PTR2),y          ; use indirect so dest page advances too
        iny
        bne .byte
        inc ZP_PTR+1
        inc ZP_PTR2+1
        dex
        bne .page
        rts

; =============================================================================
!zone fade_to_black
fade_to_black:
        lda #16
        sta fade_steps_left
.fb_step:
        jsr fade_to_black_1
        dec fade_steps_left
        bne .fb_step
        rts

fade_to_black_1:
        lda #<(palette_data+2)
        sta ZP_PTR
        lda #>(palette_data+2)
        sta ZP_PTR+1
        ldx #255                 ; entries 1..255
.fb_entry:
        ldy #$00
        lda (ZP_PTR),y          ; byte0 = [G|B]
        sta pal_tmp0
        ldy #$01
        lda (ZP_PTR),y          ; byte1 = [-|R]
        sta pal_tmp1

        lda pal_tmp0
        and #$0F                ; blue
        beq .b_done
        sec
        sbc #1
.b_done: sta pal_tmp2

        lda pal_tmp0
        lsr
        lsr
        lsr
        lsr                     ; green
        beq .g_done
        sec
        sbc #1
.g_done: sta pal_tmp3

        lda pal_tmp1
        and #$0F                ; red
        beq .r_done
        sec
        sbc #1
.r_done: sta pal_tmp4

        lda pal_tmp3
        asl
        asl
        asl
        asl
        ora pal_tmp2
        ldy #$00
        sta (ZP_PTR),y
        lda pal_tmp4
        ldy #$01
        sta (ZP_PTR),y

        lda ZP_PTR
        clc
        adc #2
        sta ZP_PTR
        bcc .noof
        inc ZP_PTR+1
.noof:
        dex
        bne .fb_entry

        jsr upload_palette_data
        rts

!zone fade_up
fade_up:
        lda #16
        sta fade_steps_left
.fu_step:
        jsr fade_up_1
        dec fade_steps_left
        bne .fu_step
        rts

fade_up_1:
        lda #<(palette_data+2)
        sta ZP_PTR
        lda #>(palette_data+2)
        sta ZP_PTR+1
        lda #<(pal_orig+2)
        sta ZP_PTR2
        lda #>(pal_orig+2)
        sta ZP_PTR2+1
        ldx #255
.fu_entry:
        ldy #$00
        lda (ZP_PTR),y
        sta pal_tmp0             ; current byte0
        lda (ZP_PTR2),y
        sta pal_tmp1             ; target byte0
        ldy #$01
        lda (ZP_PTR),y
        sta pal_tmp5             ; current byte1
        lda (ZP_PTR2),y
        sta pal_tmp6             ; target byte1

        lda pal_tmp0
        and #$0F
        sta pal_tmp2             ; current blue
        lda pal_tmp1
        and #$0F
        cmp pal_tmp2
        beq .b_ok
        bcc .b_ok                ; target <= current -> already there
        inc pal_tmp2
.b_ok:

        lda pal_tmp0
        lsr
        lsr
        lsr
        lsr
        sta pal_tmp3             ; current green
        lda pal_tmp1
        lsr
        lsr
        lsr
        lsr
        cmp pal_tmp3
        beq .g_ok
        bcc .g_ok
        inc pal_tmp3
.g_ok:

        lda pal_tmp5
        and #$0F
        sta pal_tmp4             ; current red
        lda pal_tmp6
        and #$0F
        cmp pal_tmp4
        beq .r_ok
        bcc .r_ok
        inc pal_tmp4
.r_ok:

        lda pal_tmp3
        asl
        asl
        asl
        asl
        ora pal_tmp2
        ldy #$00
        sta (ZP_PTR),y
        lda pal_tmp4
        ldy #$01
        sta (ZP_PTR),y

        lda ZP_PTR
        clc
        adc #2
        sta ZP_PTR
        bcc .noof1
        inc ZP_PTR+1
.noof1:
        lda ZP_PTR2
        clc
        adc #2
        sta ZP_PTR2
        bcc .noof2
        inc ZP_PTR2+1
.noof2:
        dex
        beq .fu_loop_done
        jmp .fu_entry            ; BNE can't reach, loop body > 127 bytes
.fu_loop_done:

        jsr upload_palette_data
        rts

; =============================================================================
; UPLOAD_PALETTE_DATA: 512 bytes (palette_data) to VRAM $1FA00.
; Slot-agnostic: addresses VERA via (VERA_ZP),Y indirect. Caller MUST set
; VERA_ZP ($0A/$0B) = $CN00 first (every magic-block client does this at
; startup). Offsets used here: ADDR0_L=$00, ADDR0_M=$01, ADDR0_H=$02,
; DATA0=$03.
; =============================================================================
!zone upload_palette_data
upload_palette_data:
        jsr patch_data0_common  ; DATA0 stores below are absolute, see note
        ldy #$00
        lda #$00
        sta (VERA_ZP),y         ; ADDR0_L = $00
        ldy #$01
        lda #$FA
        sta (VERA_ZP),y         ; ADDR0_M = $FA
        ldy #$02
        lda #$11                ; bit0 = addr bit16 ($10000+), stride +1
        sta (VERA_ZP),y         ; ADDR0_H = $11
        ldx #$00
.p0:    lda palette_data,x
upd_st0: sta $C403              ; DATA0, absolute (patched)
        inx
        bne .p0
.p1:    lda palette_data+256,x
upd_st1: sta $C403              ; DATA0, absolute (patched)
        inx
        bne .p1
        rts

; =============================================================================
; PATCH_DATA0_COMMON: point this file's absolute `sta $Cn03` DATA0 stores
; at whatever slot VERA_ZP holds. Cheap, idempotent, called on entry by each
; routine here that writes DATA0, so callers need not remember to call it.
;
; Why absolute stores and not `sta (VERA_ZP),Y`: an indexed write does a
; dummy READ of the target address first, and reading DATA0 auto-increments
; ADDR0, so each byte advances the pointer TWICE. Writing $11 $22 $33 $44 to
; VRAM 0:
;
;   sta (ZP),y   VRAM 0-7 = 00 11 00 22 00 33 00 44
;   sta abs      VRAM 0-7 = 11 22 33 44 00 00 00 00
;
; The indexed form silently corrupts every VRAM transfer. Absolute stores
; perform no dummy read. Do NOT convert DATA0 or DATA1 writes back to
; (VERA_ZP),Y. Writes to CTRL/ADDR0/L0* via (VERA_ZP),Y
; are fine (reading those has no side effect), as are DATA0 READS, since
; $Cn00+3 never crosses a page and so takes no dummy cycle.
; =============================================================================
!zone patch_data0_common
patch_data0_common:
        lda VERA_ZP+1
        sta upd_st0+2
        sta upd_st1+2
        rts

; =============================================================================
; A2_PRINT: print NUL-terminated string (ZP_PTR) on the Apple II's own
; text screen via Monitor COUT ($FDED). Each byte is OR'd with $80 first
; (Apple II text chars display with the high bit set, this also converts
; ASCII $0D CR -> Apple II $8D return automatically). $00 terminates.
; =============================================================================
!zone a2_print
a2_print:
        ldy #$00
.loop:  lda (ZP_PTR),y
        beq .done
        ora #$80                 ; set high bit (converts $0D -> $8D too)
        jsr COUT
        iny
        bne .loop
.done:  rts

; =============================================================================
; A2_KEYPRESSED: non-blocking keypress check (for animation loops).
; Returns Z=1 (A=0) if no key waiting, Z=0 (A=key|*$80) if a key was hit.
; Always clears the strobe. Does NOT block, use a2_rdkey (below) for a
; blocking wait. Safe to call with interrupts on or off.
; =============================================================================
!zone a2_keypressed
a2_keypressed:
        lda KBD                  ; bit 7 set if a key is waiting
        sta KBDSTRB              ; clear strobe regardless (so a missed
        and #$80                 ; keypress doesn't stick for the next poll)
        rts                      ; Z=1 if no key, Z=0 if key (A=$80)

; =============================================================================
; A2_RDKEY: blocking keypress wait. Returns A = key code with high bit set.
; =============================================================================
!zone a2_rdkey
a2_rdkey:
        jsr $FD0C                ; Monitor RDKEY (blocks, prints cursor)
        rts

; =============================================================================
; a2_clear_basic: reset Applesoft program pointers (clears program in RAM)
; Restores BASIC to a usable state after BRUN has clobbered program memory.
; Safe to call after exiting a program. The program then returns cleanly to ]
; and subsequent LIST shows no garbage (Applesoft has fresh empty program).
; =============================================================================
a2_clear_basic:
        ; Zero page pointers (from Applesoft)
        ; TXTTAB=$67/$68 (text/program start), VARTAB=$69/$6A,
        ; ARYTAB=$6B/$6C, STREND=$6D/$6E, FRETOP=$6F/$70
        lda #$00
        sta $0800               ; $0800 sentinel (PRGBOT-1)
        sta $0801               ; empty program: link lo (first line link = $0000)
        sta $0802               ; empty program: link hi
        lda #$01
        sta $67                 ; TXTTAB = $0801
        lda #$08
        sta $68
        lda #$03
        sta $69                 ; VARTAB = $0803 (TXTTAB+2)
        sta $6B                 ; ARYTAB = $0803
        sta $6D                 ; STREND = $0803
        lda #$08
        sta $6A
        sta $6C
        sta $6E
        lda $73                 ; FRETOP = HIMEM (where protected region starts)
        sta $6F
        lda $74
        sta $70
        rts

; =============================================================================
; Data
; =============================================================================

; Palette: 256 entries x 2 bytes, the AGFA factory default, verbatim. Pure
; data, CPU-independent. Entry 0 = black, entry 1 = white.
palette_data:
    !byte $00,$00,$FF,$0F,$00,$08,$FE,$0A,$4C,$0C,$C5,$00,$0A,$00,$E7,$0E,$85,$0D,$40,$06,$77,$0F,$33,$03,$77,$07,$F6,$0A,$8F,$00,$BB,$0B
    !byte $00,$00,$11,$01,$22,$02,$33,$03,$44,$04,$55,$05,$66,$06,$77,$07,$88,$08,$99,$09,$AA,$0A,$BB,$0B,$CC,$0C,$DD,$0D,$EE,$0E,$FF,$0F
    !byte $11,$02,$33,$04,$44,$06,$66,$08,$88,$0A,$99,$0C,$BB,$0F,$11,$02,$22,$04,$33,$06,$44,$08,$55,$0A,$66,$0C,$77,$0F,$00,$02,$11,$04
    !byte $11,$06,$22,$08,$22,$0A,$33,$0C,$33,$0F,$00,$02,$00,$04,$00,$06,$00,$08,$00,$0A,$00,$0C,$00,$0F,$21,$02,$43,$04,$64,$06,$86,$08
    !byte $A8,$0A,$C9,$0C,$EB,$0F,$11,$02,$32,$04,$53,$06,$74,$08,$95,$0A,$B6,$0C,$D7,$0F,$10,$02,$31,$04,$51,$06,$62,$08,$82,$0A,$A3,$0C
    !byte $C3,$0F,$10,$02,$30,$04,$40,$06,$60,$08,$80,$0A,$90,$0C,$B0,$0F,$21,$01,$43,$03,$64,$05,$86,$07,$A8,$09,$C9,$0B,$FB,$0D,$21,$01
    !byte $42,$03,$63,$04,$84,$06,$A5,$08,$C6,$09,$F7,$0B,$20,$01,$41,$02,$61,$04,$82,$05,$A2,$06,$C3,$08,$F3,$09,$20,$01,$40,$02,$60,$03
    !byte $80,$04,$A0,$05,$C0,$06,$F0,$07,$21,$01,$43,$03,$65,$04,$86,$06,$A8,$08,$CA,$09,$FC,$0B,$21,$01,$42,$02,$64,$03,$85,$04,$A6,$05
    !byte $C8,$06,$F9,$07,$20,$00,$41,$01,$62,$01,$83,$02,$A4,$02,$C5,$03,$F6,$03,$20,$00,$41,$00,$61,$00,$82,$00,$A2,$00,$C3,$00,$F3,$00
    !byte $22,$01,$44,$03,$66,$04,$88,$06,$AA,$08,$CC,$09,$FF,$0B,$22,$01,$44,$02,$66,$03,$88,$04,$AA,$05,$CC,$06,$FF,$07,$22,$00,$44,$01
    !byte $66,$01,$88,$02,$AA,$02,$CC,$03,$FF,$03,$22,$00,$44,$00,$66,$00,$88,$00,$AA,$00,$CC,$00,$FF,$00,$12,$01,$34,$03,$56,$04,$68,$06
    !byte $8A,$08,$AC,$09,$CF,$0B,$12,$01,$24,$02,$46,$03,$58,$04,$6A,$05,$8C,$06,$9F,$07,$02,$00,$14,$01,$26,$01,$38,$02,$4A,$02,$5C,$03
    !byte $6F,$03,$02,$00,$14,$00,$16,$00,$28,$00,$2A,$00,$3C,$00,$3F,$00,$12,$01,$34,$03,$46,$05,$68,$07,$8A,$09,$9C,$0B,$BF,$0D,$12,$01
    !byte $24,$03,$36,$04,$48,$06,$5A,$08,$6C,$09,$7F,$0B,$02,$01,$14,$02,$16,$04,$28,$05,$2A,$06,$3C,$08,$3F,$09,$02,$01,$04,$02,$06,$03
    !byte $08,$04,$0A,$05,$0C,$06,$0F,$07,$12,$02,$34,$04,$46,$06,$68,$08,$8A,$0A,$9C,$0C,$BE,$0F,$11,$02,$23,$04,$35,$06,$47,$08,$59,$0A
    !byte $6B,$0C,$7D,$0F,$01,$02,$13,$04,$15,$06,$26,$08,$28,$0A,$3A,$0C,$3C,$0F,$01,$02,$03,$04,$04,$06,$06,$08,$08,$0A,$09,$0C,$0B,$0F

; Palette fade scratch variables and original palette backup
pal_orig:
        !fill 512, 0

fade_steps_left: !byte 0
pal_tmp0: !byte 0
pal_tmp1: !byte 0
pal_tmp2: !byte 0
pal_tmp3: !byte 0
pal_tmp4: !byte 0
pal_tmp5: !byte 0
pal_tmp6: !byte 0

; End of vera_common.inc ------------------------------------------------------
