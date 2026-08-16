; veracon.asm: VERA as the Apple II console (80-column-card style redirect)
;
; Hooks the Apple II console output vector CSW ($36/$37) so every COUT
; character (BASIC PRINT, CATALOG, the ] prompt, typed-key echo) renders on
; VERA's 80x30 VGA text screen. Like a Videx Videoterm 80-column card, but the
; driver lives in main RAM with no $C800 bank trampoline.
;
; *** Requires an init program to have been run first this session. ***
; INIT-VGA, INIT-NTSC and INIT-RGB autodetect VERA's slot (1-7), initialize it
; (text mode, palette, CP437 font, Layer 0 tilemap) and publish a magic block
; at $0300:
;     $0300 = $A2, $0301 = $56   (signature)
;     $0303 = VERA base hi byte  ($C1..$C7)
; This driver reuses all of that. It does NO VERA init and carries NO font, so
; it is tiny. It reads the base from the magic block and addresses VERA through
; a runtime zero-page pointer (VERA_ZP) with (ptr),Y, so it works in ANY slot.
;
; Design:
;   - Inverse video via VERA's per-cell attribute byte (swap fg/bg). CP437 font.
;   - Scrolling moves the *display window* (hardware L0_VSCROLL over a 64-row
;     circular tilemap), NOT characters in VRAM. Same approach as the AGFA
;     version's VERA_HANDLE_LF.
;   - Static (non-flashing) block cursor. Flashing would need a VERA IRQ tick
;     and is not implemented.
;   - Ctrl-G ($87) bell (self-contained speaker loop, ported from Videx $C919).
;   - Ctrl-L ($8C) clears the VERA screen + homes (HOME the command can't be
;     intercepted, it calls $FC58 directly, never via COUT. Use PRINT CHR$(12)).
;
; Installer runs at $0800, returns via JMP $03D0 (never RTS under BRUN). The
; resident driver is assembled for $9000, copied there, protected by lowering
; HIMEM. After install it runs a NEW+CLEAR so BASIC stays usable (the BRUN load
; clobbered the $0801 program area).
;
; Run: BRUN INIT-VGA, then BRUN VERACON.

!cpu 6502

TEXT_ATTR   = $01          ; fg=1 (white) / bg=0 (black)
INV_ATTR    = $10          ; fg=0 (black) / bg=1 (white), inverse
VIEW_H      = 30           ; visible text rows
VCON_ORG    = $9000        ; resident driver target (protected by HIMEM)
SPEAKER     = $C030        ; speaker toggle (for the bell)

; VERA register offsets, used as Y indices into (VERA_ZP),Y
OFS_ADDR0_L = $00
OFS_ADDR0_M = $01
OFS_ADDR0_H = $02
OFS_DATA0   = $03
OFS_CTRL    = $05

; --- SMC: absolute VERA DATA0 store, patched at install time ----------------
; DATA0 must NEVER be written with `sta (VERA_ZP),Y`. An indexed write does a
; dummy READ of the target first, and reading DATA0 auto-increments ADDR0, so
; every byte advances the pointer twice and lands on the wrong address.
; Writing $11 $22 $33 $44 to VRAM 0 lands as 00 11 00 22 00 33 00 44 with the
; indexed form. Full note in vera_common.inc.
; Placeholder low byte = DATA0 offset ($03). High byte $01 is a throwaway that
; forces ACME to emit a 3-byte absolute STA, giving us an operand to patch.
; The store sites live inside the !pseudopc resident block, so their labels
; resolve to $9000-space addresses, so the installer patches them AFTER the
; copy, the same way it already fills in vcon_base_hi.
VDATA0 = $0103
OFS_VSCR_L  = $12          ; L0_VSCROLL_L
OFS_VSCR_H  = $13          ; L0_VSCROLL_H

; Magic block published by the init program at $0300
MAGIC_ADDR  = $0300
MAGIC_B0    = $A2
MAGIC_B1    = $56

; Apple II / DOS / zero page
ZP_PTR      = $06          ; string pointer for a2_print (install-time only)
VERA_ZP     = $0A          ; resident driver's runtime VERA base ptr ($00/$CN)
COUT        = $FDED        ; Monitor char out
CSWL        = $36          ; COUT output vector lo/hi
CSWH        = $37
HOME        = $FC58        ; Monitor clear-screen/home
DOS_RECONN  = $03EA        ; DOS 3.3 "reconnect I/O hooks" vector

; Applesoft zero-page pointers (for the NEW+CLEAR cleanup)
TXTTAB      = $67
VARTAB      = $69
ARYTAB      = $6B
STREND      = $6D
FRETOP      = $6F
HIMEM       = $73
PRGBOT      = $0801        ; default Applesoft program start

* = $0800

; =============================================================================
; INSTALLER  (BRUN VERACON)
; =============================================================================
!zone installer
start:
        jsr HOME

        ; --- require the init program's magic block (VERA already up) ---
        ; Inverted-branch + jmp: .no_magic is beyond BNE range from here.
        lda MAGIC_ADDR
        cmp #MAGIC_B0
        beq .m0
        jmp .no_magic
.m0:    lda MAGIC_ADDR+1
        cmp #MAGIC_B1
        beq .m1
        jmp .no_magic
.m1:

        lda #<msg_install
        sta ZP_PTR
        lda #>msg_install
        sta ZP_PTR+1
        jsr a2_print

        ; --- copy the resident driver up to $9000 ---
        ldx #$00
.copy:
        lda resident_src,x
        sta VCON_ORG,x
        lda resident_src+256,x
        sta VCON_ORG+256,x
        inx
        bne .copy

        ; --- tell the driver which slot VERA is in (from the magic block) ---
        lda MAGIC_ADDR+3        ; VERA base hi ($C1..$C7)
        sta vcon_base_hi
        lda #$00
        sta VERA_ZP
        lda vcon_base_hi
        sta VERA_ZP+1

        ; --- patch the relocated driver's absolute DATA0 stores to $CN03 ---
        ; These labels are $9000-space (inside !pseudopc), so this writes into
        ; the copy that just landed there, exactly like vcon_base_hi above.
        ; Must happen before vcon_clrscr / vcon_draw_cursor below.
        lda vcon_base_hi
        sta vcp_st1+2           ; vcon_plot (char)
        sta vcp_st2+2           ; vcon_plot (attr)
        sta vdc_st1+2           ; vcon_draw_cursor
        sta vdc_st2+2
        sta vec_st1+2           ; vcon_erase_cursor
        sta vec_st2+2
        sta vsc_st1+2           ; scroll clear loop
        sta vsc_st2+2
        sta vbl_st1+2           ; blank-to-end-of-line
        sta vbl_st2+2

        ; --- start with a clean VERA screen + cursor at home ---
        jsr vcon_clrscr         ; clears tilemap, homes, resets scroll/state
        jsr vcon_draw_cursor

        ; --- protect the driver: lower Applesoft HIMEM to $9000 ---
        lda #<VCON_ORG
        sta HIMEM
        lda #>VCON_ORG
        sta HIMEM+1

        ; --- hook console output, DOS-safe ---
        lda #<vcon_cout
        sta CSWL
        lda #>vcon_cout
        sta CSWH
        jsr DOS_RECONN          ; DOS copies CSW into its intercept

        ; --- NEW + CLEAR so BASIC is usable (BRUN clobbered $0801+) ---
        lda #$00
        sta PRGBOT-1            ; $0800 sentinel
        sta PRGBOT              ; empty program: link bytes = $0000
        sta PRGBOT+1
        lda #<PRGBOT
        sta TXTTAB
        lda #>PRGBOT
        sta TXTTAB+1
        lda #<(PRGBOT+2)
        sta VARTAB             ; VARTAB = TXTTAB + 2
        sta ARYTAB
        sta STREND
        lda #>(PRGBOT+2)
        sta VARTAB+1
        sta ARYTAB+1
        sta STREND+1
        lda HIMEM              ; FRETOP = HIMEM ($9000)
        sta FRETOP
        lda HIMEM+1
        sta FRETOP+1

        jmp $03D0               ; back to ], prompt now renders on VERA

.no_magic:
        lda #<msg_nomagic
        sta ZP_PTR
        lda #>msg_nomagic
        sta ZP_PTR+1
        jsr a2_print
        jmp $03D0

; --- a2_print: print NUL-terminated string (ZP_PTR) via COUT (install only) ---
!zone a2_print
a2_print:
        ldy #$00
.loop:  lda (ZP_PTR),y
        beq .done
        ora #$80               ; Apple II chars want the high bit set
        jsr COUT
        iny
        bne .loop
.done:  rts

; =============================================================================
; RESIDENT DRIVER  (assembled for $9000, copied there by the installer)
; Addresses VERA through (VERA_ZP),Y so it works in whatever slot init found.
; vcon_cout saves/restores VERA_ZP around its work (COUT is called from BASIC).
; =============================================================================
resident_src:
!pseudopc VCON_ORG {

; --- vcon_cout: the CSW target. A=char (hi bit set=normal). Preserve A,X,Y. --
!zone vcon_cout
vcon_cout:
        sta vcon_savea
        stx vcon_savex
        sty vcon_savey
        lda VERA_ZP             ; borrow VERA_ZP, restore it at .ret
        sta vcon_zpsave
        lda VERA_ZP+1
        sta vcon_zpsave+1
        lda #$00
        sta VERA_ZP
        lda vcon_base_hi
        sta VERA_ZP+1

        jsr vcon_erase_cursor   ; lift the cursor block off the current cell

        lda vcon_savea
        cmp #$8D                ; CR -> column 0 AND advance a line (Apple II
        bne .not_cr             ;   sends only CR on Enter, it means CR+LF).
        lda #$00
        sta vcon_col
        jsr vcon_advance_row
        jmp .ret
.not_cr:
        cmp #$8A                ; LF -> advance a line, keep the column
        bne .not_lf
        jsr vcon_advance_row
        jmp .ret
.not_lf:
        cmp #$88                ; BS
        bne .not_bs
        jsr vcon_backspace
        jmp .ret
.not_bs:
        cmp #$8C                ; Ctrl-L (form feed) -> clear screen + home
        bne .not_ff
        jsr vcon_clrscr
        jmp .ret
.not_ff:
        cmp #$87                ; Ctrl-G (bell) -> beep the speaker
        bne .printable
        jsr vcon_bell
        jmp .ret

.printable:
        lda vcon_savea
        bmi .normal             ; bit7 set -> normal
        ; inverse / flashing
        and #$3F
        cmp #$20
        bcs .inv_store
        ora #$40                ; $00-$1F -> uppercase glyphs $40-$5F
.inv_store:
        sta vcon_glyph
        lda #INV_ATTR
        sta vcon_attr
        jmp .plot
.normal:
        and #$7F
        sta vcon_glyph
        lda #TEXT_ATTR
        sta vcon_attr
.plot:
        jsr vcon_setaddr
        lda vcon_glyph
vcp_st1: sta VDATA0             ; char to DATA0, absolute (patched at install)
        lda vcon_attr
vcp_st2: sta VDATA0             ; attr (ADDR0 auto-advances 2 = one tile)
        inc vcon_col
        lda vcon_col
        cmp #80
        bcc .ret
        lda #$00                ; past the right edge -> wrap to next line
        sta vcon_col
        jsr vcon_advance_row
.ret:
        jsr vcon_draw_cursor
        lda vcon_zpsave         ; restore the borrowed VERA_ZP
        sta VERA_ZP
        lda vcon_zpsave+1
        sta VERA_ZP+1
        lda vcon_savea          ; COUT returns the char in A
        ldx vcon_savex
        ldy vcon_savey
        rts

; --- vcon_setaddr: VERA ADDR0 = row*256 + col*2, stride +1 -------------------
!zone vcon_setaddr
vcon_setaddr:
        ldy #OFS_CTRL
        lda #$00
        sta (VERA_ZP),y         ; CTRL = 0 (DCSEL0, ADDRSEL0)
        lda vcon_col
        asl
        ldy #OFS_ADDR0_L
        sta (VERA_ZP),y         ; col*2
        lda vcon_row
        ldy #OFS_ADDR0_M
        sta (VERA_ZP),y         ; row
        lda #$10
        ldy #OFS_ADDR0_H
        sta (VERA_ZP),y
        rts

; --- vcon_draw_cursor: static (non-flashing) block at the current cell --------
!zone vcon_draw_cursor
vcon_draw_cursor:
        jsr vcon_setaddr
        lda #$20                ; space glyph
vdc_st1: sta VDATA0             ; DATA0, absolute (patched at install)
        lda #INV_ATTR           ; inverse -> solid white block
vdc_st2: sta VDATA0
        rts

; --- vcon_erase_cursor: restore a normal blank at the current cell ------------
!zone vcon_erase_cursor
vcon_erase_cursor:
        jsr vcon_setaddr
        lda #$20
vec_st1: sta VDATA0             ; DATA0, absolute (patched at install)
        lda #TEXT_ATTR
vec_st2: sta VDATA0
        rts

; --- vcon_advance_row: row+1 (circular), scroll the window if past bottom -----
; Does NOT touch the column. The caller sets col (CR/wrap = 0, LF = keep).
!zone vcon_advance_row
vcon_advance_row:
        lda vcon_row
        clc
        adc #1
        and #$3F                ; circular over 64 physical rows
        sta vcon_row
        sec
        sbc vcon_scroll_row
        and #$3F                ; distance from window top
        cmp #VIEW_H
        bcc .done               ; still inside the viewport
        ; --- bump the display window one text row (8 px) ---
        lda vcon_scroll_row
        clc
        adc #1
        and #$3F
        sta vcon_scroll_row
        asl
        asl
        asl                     ; scroll_row * 8 (low byte)
        ldy #OFS_VSCR_L
        sta (VERA_ZP),y
        lda vcon_scroll_row
        lsr
        lsr
        lsr
        lsr
        lsr                     ; (scroll_row*8) >> 8 = scroll_row >> 5 (0/1)
        ldy #OFS_VSCR_H
        sta (VERA_ZP),y
        ; clear the newly-exposed bottom row = (scroll_row + VIEW_H - 1) & $3F
        lda vcon_scroll_row
        clc
        adc #(VIEW_H - 1)
        and #$3F
        jsr vcon_clr_row
.done:
        rts

; --- vcon_clr_row: clear physical row A (0-63) to space+attr ------------------
!zone vcon_clr_row
vcon_clr_row:
        pha
        ldy #OFS_CTRL
        lda #$00
        sta (VERA_ZP),y
        ldy #OFS_ADDR0_L
        lda #$00
        sta (VERA_ZP),y
        pla
        ldy #OFS_ADDR0_M
        sta (VERA_ZP),y         ; row*256
        lda #$10
        ldy #OFS_ADDR0_H
        sta (VERA_ZP),y
        ldx #128                ; 128 cells (full map width), X = count
.clp:
        lda #$20
vsc_st1: sta VDATA0             ; DATA0, absolute (patched at install)
        lda #TEXT_ATTR
vsc_st2: sta VDATA0
        dex
        bne .clp
        rts

; --- vcon_clrscr: clear all 64 rows, home cursor, reset scroll (Ctrl-L) -------
!zone vcon_clrscr
vcon_clrscr:
        lda #$00
        sta vcon_col
        sta vcon_row
        sta vcon_scroll_row
        ldy #OFS_VSCR_L
        lda #$00
        sta (VERA_ZP),y
        ldy #OFS_VSCR_H
        lda #$00
        sta (VERA_ZP),y
        lda #$00
        sta vcon_rowtmp         ; row counter (in memory, vcon_clr_row uses X)
.row:
        lda vcon_rowtmp
        jsr vcon_clr_row
        inc vcon_rowtmp
        lda vcon_rowtmp
        cmp #64
        bne .row
        rts

; --- vcon_bell: short speaker tone (ported from Videx ROM $C919) --------------
; Self-contained $C030 toggle/delay loop, NOT a monitor BELL call (that
; re-enters COUT and would recurse through this driver).
!zone vcon_bell
vcon_bell:
        ldy #$C0
.outer:
        ldx #$80
.inner:
        dex
        bne .inner
        lda SPEAKER             ; toggle speaker
        dey
        bne .outer
        rts

; --- vcon_backspace: col-1 (or wrap to end of prev row), blank the cell ------
!zone vcon_backspace
vcon_backspace:
        lda vcon_col
        beq .atcol0
        dec vcon_col
        jmp .blank
.atcol0:
        lda vcon_row
        beq .done               ; at home, nothing to do
        sec
        sbc #1
        and #$3F
        sta vcon_row
        lda #79
        sta vcon_col
.blank:
        jsr vcon_setaddr
        lda #$20
vbl_st1: sta VDATA0             ; DATA0, absolute (patched at install)
        lda #TEXT_ATTR
vbl_st2: sta VDATA0
.done:
        rts

; --- resident state (lives inside the $9000 block) ---------------------------
vcon_base_hi:    !byte 0        ; VERA base hi byte ($C1..$C7) from magic block
vcon_col:        !byte 0        ; 0-79
vcon_row:        !byte 0        ; 0-63 (circular physical tilemap row)
vcon_scroll_row: !byte 0        ; 0-63 (physical row at top of viewport)
vcon_rowtmp:     !byte 0        ; clrscr row counter
vcon_savea:      !byte 0
vcon_savex:      !byte 0
vcon_savey:      !byte 0
vcon_zpsave:     !byte 0, 0     ; saved VERA_ZP across a COUT call
vcon_glyph:      !byte 0
vcon_attr:       !byte 0

vcon_end:
}   ; end !pseudopc

; The installer copies exactly 512 bytes (two 256-byte passes) to $9000.
; If the resident driver ever outgrows that, the copy silently truncates and
; the driver crashes at runtime. Fail the build instead.
!if vcon_end - VCON_ORG > 512 {
        !error "resident driver > 512 bytes, widen the installer copy loop"
}

; =============================================================================
; Data (Apple II screen messages, a2_print ORs $80, so plain ASCII + $0D)
; =============================================================================
msg_install:
        !text "VERA CONSOLE DRIVER"
        !byte 13
        !text "-------------------"
        !byte 13, 13
        !text "REDIRECTING CONSOLE OUTPUT TO VERA."
        !byte 13, 0

msg_nomagic:
        !text "VERA NOT INITIALIZED."
        !byte 13
        !text "RUN AN INIT PROGRAM, THEN VERACON."
        !byte 13, 0
