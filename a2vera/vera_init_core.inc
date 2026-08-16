; vera_init_core.inc: everything the three init programs share
;
; Scans Apple II peripheral slots 1-7 for a VERA card using read-first
; safety (Stage 0 read-only filter -> Stage 1 version probe -> VRAM
; round-trip confirm), then initializes VERA IN THE DETECTED SLOT and
; publishes the slot in a magic block at $0300 so client programs can
; find VERA without scanning or initializing themselves.
;
; Sourced by init_vga.asm, init_ntsc.asm and init_rgb.asm. Those three
; differ only in the display composer setup, so each one supplies:
;
;   MODE_ID          MODE_VGA / MODE_NTSC / MODE_RGB, published to $0307
;   v_video_setup    the composer writes for that output mode
;   msg_title        Apple II screen banner, NUL-terminated
;   vstr_mode        mode name for the VERA screen, NUL-terminated
;
; and set the origin to $0800 with a jmp start ahead of this file.
;
; SELF-CONTAINED: vera_common.inc is sourced only for a2_print,
; palette_data and a2_keypressed. Its slot-4 VERA routines are DEAD CODE
; here (never called). VERA is addressed entirely through a runtime zero
; page pointer (VERA_ZP) with (ptr),Y indirect addressing, so this works
; in ANY slot.
;
; Key safety property of the detection: a write only ever lands on a
; slot whose offsets $00-$05 all read $00
; (looks like an uninitialized VERA). Empty slots and other cards fail
; that read filter and are never written.
;
; Idempotent: if the magic block is already present (VERA initialized by
; a previous run this session), it skips the scan, reports the slot it
; already knows, and reinitializes. That is what lets a second init
; program switch the output mode without rescanning.
;
; Emulator note: AppleWin does not emulate VERA. With no VERA present, the
; Stage-0 read filter sees floating bus (non-$00) on every slot, so the
; program prints "NO VERA CARD FOUND" and returns to ]. That is the
; expected result there, detection only means something on real hardware.

; --- Layout constants --------------------------------------------------------

TEXT_ATTR   = $01             ; white-on-black (palette entry 1)
VERA_ZP     = $0A             ; 2 bytes ($0A/$0B): runtime VERA base = $CN00

; Magic block at $0300 (persistent across BRUN, cleared by power-cycle)
MAGIC_ADDR  = $0300
MAGIC_B0    = $A2
MAGIC_B1    = $56

; Video mode published at $0307. The values are DC_VIDEO's own output mode
; field, so a client can compare against the low two bits it would write.
MODE_VGA    = 1
MODE_NTSC   = 2
MODE_RGB    = 3

; VERA banner layout (tilemap row/col)
BANNER_ROW  = 2
BANNER_COL  = 8
ADRIAN_ROW  = 3
ADRIAN_COL  = 8
SLOT_ROW    = 4
SLOT_COL    = 8
MODE_ROW    = 5
MODE_COL    = 8
CHAR_ROW_START = 7
CHAR_COL_START = 8
CHAR_PER_ROW = 64
CHAR_ROWS = 4

; VERA register offsets (used as Y indices into (VERA_ZP),Y)
OFS_ADDR0_L = $00
OFS_ADDR0_M = $01
OFS_ADDR0_H = $02
OFS_DATA0   = $03
OFS_CTRL    = $05
OFS_DC09    = $09
OFS_DC0A    = $0A
OFS_DC0B    = $0B
OFS_DC0C    = $0C
OFS_L0CFG   = $0D
OFS_L0MAP   = $0E
OFS_L0TILE  = $0F

; --- Macro: write a VERA register (offset, value) via (VERA_ZP),Y -------------
; SAFE for every register EXCEPT DATA0 ($03) and DATA1 ($04), see the
; "DATA0 writes" note below. `sta (ptr),Y` performs a dummy READ of the
; target address before the write, harmless on CTRL/ADDR0/L0* (reading them
; has no side effect) but NOT on the data ports.
!macro VSET ofs, val {
        ldy #ofs
        lda #val
        sta (VERA_ZP),y
}

; --- DATA0 writes: absolute stores, operand patched at runtime ---------------
; Writing DATA0 with `sta (VERA_ZP),Y` corrupts every VRAM transfer. The
; indexed-write dummy read hits DATA0 first, and a READ of DATA0 auto-
; increments ADDR0, so each byte advances the pointer TWICE. Writing
; $11 $22 $33 $44 to VRAM 0:
;
;   sta (ZP),y   VRAM 0-7 = 00 11 00 22 00 33 00 44
;   sta abs      VRAM 0-7 = 11 22 33 44 00 00 00 00
;
; Absolute (non-indexed) stores perform no dummy read, so every DATA0 write
; below is an absolute `sta $Cn03` whose high byte is patched by
; patch_data0_sites once the slot is known. Do NOT convert these back to
; (VERA_ZP),Y. Reads via `lda (VERA_ZP),Y` are fine ($Cn00+3 never crosses a
; page, so there is no dummy cycle) and are left alone.

start:
        ; --- title on the Apple II's own screen ---
        jsr $FC58               ; HOME
        lda #<msg_title
        sta ZP_PTR
        lda #>msg_title
        sta ZP_PTR+1
        jsr a2_print

        ; --- magic check: is VERA already initialized this session? ---
        lda MAGIC_ADDR
        cmp #MAGIC_B0
        bne cold_path
        lda MAGIC_ADDR+1
        cmp #MAGIC_B1
        bne cold_path
        jsr warm_path           ; already initialized, report + exit
        jsr a2_clear_basic
        jmp $03D0

cold_path:
        ; --- cold scan ---
        lda #<msg_scan
        sta ZP_PTR
        lda #>msg_scan
        sta ZP_PTR+1
        jsr a2_print

        jsr VERA_SCAN
        bcs .nv_skip            ; long-branch: no_vera is out of bcc range
        jmp no_vera
.nv_skip:

        ; ZP_PTR still holds the winning $CN00 (left by VERA_PROBE), so use
        ; it for the confirm round-trip before anything clobbers it.
        jsr VERA_CONFIRM
        bcs .cf_skip            ; long-branch: confirm_fail is out of range
        jmp confirm_fail
.cf_skip:

        ; "VERA FOUND IN SLOT N"
        jsr print_found

        jmp init_vera

warm_path:
        ; Extract slot from magic block without re-scanning
        lda MAGIC_ADDR+3        ; stored base hi ($C1..$C7)
        sta vera_slot_hi
        lda MAGIC_ADDR+2        ; stored slot number
        sta vera_slot_num
        lda MAGIC_ADDR+4
        sta vera_ver_maj
        lda MAGIC_ADDR+5
        sta vera_ver_min

        lda #<msg_reinit
        sta ZP_PTR
        lda #>msg_reinit
        sta ZP_PTR+1
        jsr a2_print
        jsr print_slot_digit
        lda #<msg_dotnl
        sta ZP_PTR
        lda #>msg_dotnl
        sta ZP_PTR+1
        jsr a2_print

        ; fall through to init_vera with vera_slot_hi already loaded

init_vera:
        ; load VERA_ZP from vera_slot_hi
        lda vera_slot_hi
        sta VERA_ZP+1
        lda #$00
        sta VERA_ZP
        jsr patch_data0_sites   ; MUST precede any DATA0 write

        lda #<msg_init
        sta ZP_PTR
        lda #>msg_init
        sta ZP_PTR+1
        jsr a2_print

        ; --- full VERA init in the detected slot (all indirect) ---
        jsr v_reset
        jsr v_video_setup
        jsr v_upload_palette
        jsr v_upload_font
        jsr v_layer0_setup
        jsr v_clear_tilemap

        ; --- banner on the VERA screen ---
        jsr vera_banner

        ; --- qualify the SD link, so clients do not each have to guess ---
        jsr probe_sd

        ; --- publish the magic block for client programs ---
        jsr magic_write

        lda #<msg_done
        sta ZP_PTR
        lda #>msg_done
        sta ZP_PTR+1
        jsr a2_print
        jsr a2_clear_basic
        jmp $03D0               ; DOS warm start -> ]

; =============================================================================
; NO_VERA / CONFIRM_FAIL: error exits
; =============================================================================
!zone no_vera
no_vera:
        lda #<msg_novera
        sta ZP_PTR
        lda #>msg_novera
        sta ZP_PTR+1
        jsr a2_print
        jsr a2_clear_basic
        jmp $03D0

!zone confirm_fail
confirm_fail:
        lda #<msg_conffail
        sta ZP_PTR
        lda #>msg_conffail
        sta ZP_PTR+1
        jsr a2_print
        jsr a2_clear_basic
        jmp $03D0

; =============================================================================
; PRINT_FOUND: "VERA FOUND IN SLOT N" on the Apple II screen
; =============================================================================
!zone print_found
print_found:
        lda #<msg_found
        sta ZP_PTR
        lda #>msg_found
        sta ZP_PTR+1
        jsr a2_print
        jsr print_slot_digit
        lda #<msg_dotnl
        sta ZP_PTR
        lda #>msg_dotnl
        sta ZP_PTR+1
        jsr a2_print
        rts

; PRINT_SLOT_DIGIT: print vera_slot_num (1-7) as one digit on A2 screen
!zone print_slot_digit
print_slot_digit:
        lda vera_slot_num
        ora #$B0                ; '0'=$B0 with high bit, 1-7 -> $B1-$B7
        jsr COUT
        rts

; =============================================================================
; VERA_PROBE: test one slot. In: A = base hi ($C1..$C7). Out: carry set=found.
;   Stage 0: read offsets $00-$05, all must be $00 (read-only, safe).
;   Stage 1: write CTRL=$7E (DCSEL=63), read $09, expect $56 ('V').
; Uses ZP_PTR (set to $CN00). CTRL restored to $00 afterward.
; =============================================================================
!zone vera_probe
VERA_PROBE:
        sta ZP_PTR+1
        lda #$00
        sta ZP_PTR
        ; --- stage 0: read-only pre-filter ---
        ldy #$05
.rdchk: lda (ZP_PTR),y
        bne .notfound
        dey
        bpl .rdchk
        ; --- stage 1: version probe (now safe to write this slot) ---
        ldy #OFS_CTRL
        lda #$7E
        sta (ZP_PTR),y          ; CTRL = DCSEL 63
        ldy #OFS_DC09
        lda (ZP_PTR),y          ; DC_VER0
        cmp #$56                ; 'V'?
        bne .restore_miss
        lda #$00
        ldy #OFS_CTRL
        sta (ZP_PTR),y          ; restore CTRL
        sec
        rts
.restore_miss:
        lda #$00
        ldy #OFS_CTRL
        sta (ZP_PTR),y          ; restore CTRL
.notfound:
        clc
        rts

; =============================================================================
; VERA_SCAN: walk slots 1..7. Out: carry set -> vera_slot_hi/num set.
; =============================================================================
!zone vera_scan
VERA_SCAN:
        lda #$C1
.loop:  pha
        jsr VERA_PROBE
        bcs .found
        pla
        clc
        adc #$01
        cmp #$C8                ; past slot 7?
        bne .loop
        clc
        rts
.found: pla                     ; A = winning base hi
        sta vera_slot_hi
        sec
        sbc #$C0                ; slot number = hi - $C0
        sta vera_slot_num
        sec
        rts

; =============================================================================
; VERA_CONFIRM: VRAM write/readback round-trip. In: ZP_PTR = $CN00.
; Out: carry set = confirmed VERA. Scribbles 2 bytes at VRAM $00000-$00001
; (harmless, v_clear_tilemap wipes them before use).
; =============================================================================
!zone vera_confirm
VERA_CONFIRM:
        ; This runs before VERA_ZP exists, off ZP_PTR (left by VERA_PROBE),
        ; so patch our own DATA0 stores from ZP_PTR's high byte first.
        lda ZP_PTR+1
        sta vcf_st1+2
        sta vcf_st2+2
        ; ADDR0 = $00000, increment step 1
        lda #$00
        ldy #OFS_ADDR0_L
        sta (ZP_PTR),y
        iny
        sta (ZP_PTR),y          ; ADDR0_M = $00
        iny
        lda #$10                ; ADDR0_H: incr=1, bit16=0
        sta (ZP_PTR),y
        ; write $A5 then $5A through DATA0 (auto-increments)
        lda #$A5
vcf_st1: sta $C403              ; DATA0, absolute (patched just above)
        lda #$5A
vcf_st2: sta $C403              ; DATA0, absolute (patched just above)
        ; rewind ADDR0 to $00000
        lda #$00
        ldy #OFS_ADDR0_L
        sta (ZP_PTR),y
        iny
        sta (ZP_PTR),y
        iny
        lda #$10
        sta (ZP_PTR),y
        ; read back
        ldy #OFS_DATA0
        lda (ZP_PTR),y
        cmp #$A5
        bne .bad
        lda (ZP_PTR),y
        cmp #$5A
        bne .bad
        sec
        rts
.bad:   clc
        rts

; =============================================================================
; PATCH_DATA0_SITES: point every absolute `sta $Cn03` at the detected slot.
; Must run after VERA_ZP is loaded and before any DATA0 write. Only the high
; byte varies. The low byte ($03 = DATA0) is fixed at assembly time.
; VERA_CONFIRM patches its own two sites separately because it runs before
; VERA_ZP exists.
; =============================================================================
!zone patch_data0_sites
patch_data0_sites:
        lda VERA_ZP+1
        sta vcp_st+2            ; v_copy_pages
        sta vct_st1+2           ; v_clear_tilemap (char)
        sta vct_st2+2           ; v_clear_tilemap (attr)
        sta vps_st1+2           ; v_print_str (char)
        sta vps_st2+2           ; v_print_str (attr)
        sta vpc_st1+2           ; v_putc (char)
        sta vpc_st2+2           ; v_putc (attr)
        rts

; =============================================================================
; READ_VERSION: DCSEL=63, grab DC_VER1/VER2. VERA_ZP must be set. Restores
; CTRL to $00.
; =============================================================================
!zone read_version
read_version:
        ldy #OFS_CTRL
        lda #$7E
        sta (VERA_ZP),y
        ldy #OFS_DC0A
        lda (VERA_ZP),y
        sta vera_ver_maj
        ldy #OFS_DC0B
        lda (VERA_ZP),y
        sta vera_ver_min
        ldy #OFS_CTRL
        lda #$00
        sta (VERA_ZP),y
        rts

; =============================================================================
; V_RESET: soft reset (CTRL bit7 pulse) via indirect access
; =============================================================================
!zone v_reset
v_reset:
        ldy #OFS_CTRL
        lda #$80
        sta (VERA_ZP),y
        jsr v_delay
        ldy #OFS_CTRL
        lda #$00
        sta (VERA_ZP),y
        jsr v_delay
        rts

!zone v_delay
v_delay:
        ldx #$00
        ldy #$00
.dl:    iny
        bne .dl
        inx
        bne .dl
        rts

; =============================================================================
; V_COPY_PAGES: copy X*256 bytes from ZP_PTR to VERA DATA0 (indirect dest)
; =============================================================================
!zone v_copy_pages
v_copy_pages:
.page:  ldy #$00
.byte:  lda (ZP_PTR),y
vcp_st: sta $C403               ; DATA0, absolute (patched). ADDR0 auto-incs.
        iny
        bne .byte
        inc ZP_PTR+1
        dex
        bne .page
        rts

; =============================================================================
; V_UPLOAD_PALETTE: 512 bytes (palette_data) to VRAM $1FA00
; =============================================================================
!zone v_upload_palette
v_upload_palette:
        +VSET OFS_ADDR0_L, $00
        +VSET OFS_ADDR0_M, $FA
        +VSET OFS_ADDR0_H, $11  ; incr=1, bit16=1
        lda #<palette_data
        sta ZP_PTR
        lda #>palette_data
        sta ZP_PTR+1
        ldx #2                  ; 2 pages = 512 bytes
        jsr v_copy_pages
        rts

; =============================================================================
; V_UPLOAD_FONT: 2048 bytes (font_data) to VRAM $0F000
; =============================================================================
!zone v_upload_font
v_upload_font:
        +VSET OFS_ADDR0_L, $00
        +VSET OFS_ADDR0_M, $F0
        +VSET OFS_ADDR0_H, $10  ; incr=1, bit16=0
        lda #<font_data
        sta ZP_PTR
        lda #>font_data
        sta ZP_PTR+1
        ldx #8                  ; 8 pages = 2048 bytes
        jsr v_copy_pages
        rts

; =============================================================================
; V_LAYER0_SETUP: 128x64 1bpp tile map @ $00000, tiles @ $0F000
; =============================================================================
!zone v_layer0_setup
v_layer0_setup:
        +VSET OFS_L0CFG,  $60
        +VSET OFS_L0MAP,  $00
        +VSET OFS_L0TILE, $78
        rts

; =============================================================================
; V_CLEAR_TILEMAP: 8192 tiles (char+attr) from $00000, filled with spaces
; =============================================================================
!zone v_clear_tilemap
v_clear_tilemap:
        +VSET OFS_ADDR0_L, $00
        +VSET OFS_ADDR0_M, $00
        +VSET OFS_ADDR0_H, $10
        ldx #32                 ; 32 * 256 = 8192 tiles
.outer: lda #$00
        sta clrcnt
.inner: lda #$20                ; space
vct_st1: sta $C403              ; DATA0, absolute (patched)
        lda #TEXT_ATTR
vct_st2: sta $C403              ; DATA0, absolute (patched)
        dec clrcnt
        bne .inner
        dex
        bne .outer
        rts

; =============================================================================
; V_GOTOXY: set ADDR0 to tilemap (row,col), stride +1. In: A=row, X=col
; =============================================================================
!zone v_gotoxy
v_gotoxy:
        ldy #OFS_ADDR0_M
        sta (VERA_ZP),y         ; ADDR0_M = row
        txa
        asl                     ; col*2
        ldy #OFS_ADDR0_L
        sta (VERA_ZP),y
        lda #$10
        ldy #OFS_ADDR0_H
        sta (VERA_ZP),y
        rts

; =============================================================================
; V_PRINT_STR: NUL-terminated string (ZP_PTR) at current ADDR0, via DATA0
; =============================================================================
!zone v_print_str
v_print_str:
        ldy #$00
.loop:  lda (ZP_PTR),y
        beq .done
vps_st1: sta $C403              ; char  -- DATA0, absolute (patched)
        lda #TEXT_ATTR
vps_st2: sta $C403              ; attr (ADDR0 advances 2 = one tile)
        iny
        bne .loop
.done:  rts

; V_PUTC: write one char (A) + attr at current ADDR0 position
!zone v_putc
v_putc:
vpc_st1: sta $C403              ; DATA0, absolute (patched)
        lda #TEXT_ATTR
vpc_st2: sta $C403              ; DATA0, absolute (patched)
        rts

; V_PUT_HEX: write A as two hex digits at current ADDR0 position
!zone v_put_hex
v_put_hex:
        sta vhex
        lsr
        lsr
        lsr
        lsr                     ; high nibble
        jsr hexdigit
        jsr v_putc
        lda vhex
        and #$0F                ; low nibble
        jsr hexdigit
        jsr v_putc
        rts

; HEXDIGIT: A (0-15) -> ASCII char in A
!zone hexdigit
hexdigit:
        cmp #$0A
        bcc .num
        sec
        sbc #$0A
        clc
        adc #$41                ; 'A'
        rts
.num:   clc
        adc #$30                ; '0'
        rts

; =============================================================================
; VERA_BANNER: draw banner, adrian, slot, and character dump on VERA screen
; =============================================================================
!zone vera_banner
vera_banner:
        lda #BANNER_ROW
        ldx #BANNER_COL
        jsr v_gotoxy
        lda #<vstr_banner
        sta ZP_PTR
        lda #>vstr_banner
        sta ZP_PTR+1
        jsr v_print_str

        lda #ADRIAN_ROW
        ldx #ADRIAN_COL
        jsr v_gotoxy
        lda #<vstr_adrian
        sta ZP_PTR
        lda #>vstr_adrian
        sta ZP_PTR+1
        jsr v_print_str

        lda #SLOT_ROW
        ldx #SLOT_COL
        jsr v_gotoxy
        lda #<vstr_slot
        sta ZP_PTR
        lda #>vstr_slot
        sta ZP_PTR+1
        jsr v_print_str
        lda vera_slot_num
        ora #$30                ; '0'..'7' (raw ASCII for VERA tile index)
        jsr v_putc

        lda #MODE_ROW
        ldx #MODE_COL
        jsr v_gotoxy
        lda #<vstr_modelbl
        sta ZP_PTR
        lda #>vstr_modelbl
        sta ZP_PTR+1
        jsr v_print_str
        lda #<vstr_mode         ; supplied by the including program
        sta ZP_PTR
        lda #>vstr_mode
        sta ZP_PTR+1
        jsr v_print_str         ; ADDR0 carried over, so this appends

        jsr char_dump
        rts

; =============================================================================
; CHAR_DUMP: print all 256 characters, CHAR_PER_ROW per row, CHAR_ROWS rows
; =============================================================================
!zone char_dump
char_dump:
        lda #$00
        sta charval
        lda #CHAR_ROW_START
        sta currow
        lda #CHAR_ROWS
        sta rowsleft
.rowloop:
        lda currow
        ldx #CHAR_COL_START
        jsr v_gotoxy
        ldy #CHAR_PER_ROW
.charloop:
        lda charval
        sty vsave
        jsr v_putc
        ldy vsave
        inc charval
        dey
        bne .charloop
        inc currow
        dec rowsleft
        bne .rowloop
        rts

; =============================================================================
; MAGIC_WRITE: publish slot/version into the $0300 block
; =============================================================================
!zone magic_write
magic_write:
        lda #MAGIC_B0
        sta MAGIC_ADDR
        lda #MAGIC_B1
        sta MAGIC_ADDR+1
        lda vera_slot_num
        sta MAGIC_ADDR+2
        lda vera_slot_hi
        sta MAGIC_ADDR+3
        lda vera_ver_maj
        sta MAGIC_ADDR+4
        lda vera_ver_min
        sta MAGIC_ADDR+5
        lda spi_clk_result       ; $0306: SD link speed (see sd_probe_clock)
        sta MAGIC_ADDR+6
        lda #MODE_ID             ; $0307: which output mode is driving VERA
        sta MAGIC_ADDR+7
        rts

; =============================================================================
; PROBE_SD: qualify the SPI link once, here, so every SD client can just read
; the answer out of the magic block.
;
; 12.5MHz is not safe in every slot. Measured on an Apple IIe, 64-sector read
; stress: slot 4 and 7 clean, slot 2 lost 3 reads, slot 1 could not hold a data
; token at all. All three were clean at 390kHz. Rather than pick one setting for
; everybody (12.5MHz breaks low slots, 390kHz costs 1.67x everywhere, measured
; at 4.17s vs 2.50s per slide), probe the actual link and record the verdict.
;
; No card is not an error. sd_init fails on bounded timeouts, we record SLOW and
; carry on, because plenty of VERA programs never touch the SD card and none of
; them should be held up by its absence.
; =============================================================================
!zone probe_sd
probe_sd:
        lda #SPICLK_SLOW         ; safe default if anything below bails
        sta spi_clk_result

        lda #<msg_sdprobe
        sta ZP_PTR
        lda #>msg_sdprobe
        sta ZP_PTR+1
        jsr a2_print

        jsr sd_init
        bcc .up
        lda #<msg_sdnone         ; no card (or not wired), not a failure
        sta ZP_PTR
        lda #>msg_sdnone
        sta ZP_PTR+1
        jmp a2_print             ; tail call, spi_clk_result stays SLOW
.up:
        jsr sd_probe_clock
        sta spi_clk_result
        cmp #SPICLK_FAST
        beq .fast
        lda #<msg_sdslow
        sta ZP_PTR
        lda #>msg_sdslow
        sta ZP_PTR+1
        jmp a2_print
.fast:
        lda #<msg_sdfast
        sta ZP_PTR
        lda #>msg_sdfast
        sta ZP_PTR+1
        jmp a2_print

; === SD/SPI layer: needed only for probe_sd's link qualification =============
!source "a2vera/vera_sd.inc"

; === shared helpers + palette data from vera_common.inc ======================
; (Its slot-4 VERA routines are unused dead code here. We use the indirect
;  routines above. We only need a2_print, a2_keypressed, palette_data, ZP_PTR.)
!source "a2vera/vera_common.inc"

; =============================================================================
; Data
; =============================================================================

; --- Apple II screen messages (printed via a2_print, which ORs $80) ---
; msg_title comes from the including program.

msg_scan:
        !text "SCANNING SLOTS 1-7..."
        !byte 13, 0

msg_found:
        !text "VERA FOUND IN SLOT ", 0

msg_dotnl:
        !byte 13, 0

msg_init:
        !text "INITIALIZING..."
        !byte 13, 0

msg_done:
        !byte 13
        !text "DONE - VERA READY"
        !byte 13
        !text "OTHER PROGRAMS MAY NOW USE VERA"
        !byte 13, 0

msg_novera:
        !byte 13
        !text "NO VERA CARD FOUND IN SLOTS 1-7"
        !byte 13, 0

msg_conffail:
        !byte 13
        !text "VRAM CONFIRM FAILED - UNEXPECTED"
        !byte 13, 0

msg_reinit:
        !text "VERA RE-INITIALIZING IN SLOT ", 0

msg_sdprobe:
        !text "SD LINK... ", 0
msg_sdnone:
        !text "NO CARD", 13, 0
msg_sdslow:
        !text "390KHZ", 13, 0
msg_sdfast:
        !text "12.5MHZ", 13, 0

; --- VERA screen strings (raw ASCII tile indices) ---

vstr_banner:
        !text "VERA on Apple II Initialized!", 0
vstr_adrian:
        !text "Adrian's Digital Basement", 0
vstr_slot:
        !text "VERA in Slot ", 0
vstr_modelbl:
        !text "Video Mode: ", 0

; --- scratch variables ---
vera_slot_hi:  !byte 0
vera_slot_num: !byte 0
vera_ver_maj:  !byte 0
vera_ver_min:  !byte 0
spi_clk_result: !byte SPICLK_NONE ; probe_sd's verdict, published to $0306
vsave:         !byte 0
vhex:          !byte 0
clrcnt:        !byte 0
charval:       !byte 0
currow:        !byte 0
rowsleft:      !byte 0

; --- font asset (2KB, 1bpp, identical format across all hosts) ---
font_data:
        !bin "agfa-monitor/vera/font_code437_8x8.bin"
