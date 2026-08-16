; vera_sd.inc: SD-card asset loader for Apple II + VERA
;
; !source this into a program alongside vera_common.inc:
;     !source "a2vera/vera_sd.inc"
;     !source "a2vera/vera_common.inc"
;
; Talks to the SD card wired to VERA's on-chip SPI controller (JP1 = SD).
; Reads a FAT32 card, finds files by 8.3 name in the ROOT directory only,
; and streams their bytes either straight into VRAM (fat_load_vram) or into
; Apple II RAM (fat_load_ram).
;
; SCOPE, by design: FAT32 only, root directory only, uppercase 8.3 short
; names, MBR-partitioned card (partition 0). No FAT16, no subdirectories,
; no long filenames.
;
; ACCESS MODEL: this is a normal VERA "client". It inherits VERA_ZP
; ($0A/$0B = $CN00) from the magic-block locate-or-die snippet the caller
; runs at startup, and reuses ZP_PTR ($06/$07) + ZP_PTR2 ($08/$09) from
; vera_common.inc as transient indirect pointers. It defines NO new zero
; page. All persistent state lives in absolute labeled storage below.
;
; VERA SPI registers live inside the normal 32-byte window:
;   SPI_DATA = offset $1E : write starts a transfer, read gets received byte
;   SPI_CTRL = offset $1F : bit7 BUSY(RO), bit2 Auto-TX, bit1 Slow-Clock
;                           (1=~390kHz init / 0=12.5MHz), bit0 Select(1=CS)
;
; ERROR CONVENTION: public routines return carry clear = OK, carry set =
; failure (with a code in sd_last_err). Every caller ends with JMP $03D0.

OFS_SPI_DATA = $1E
OFS_SPI_CTRL = $1F
!ifndef OFS_DATA0 {
OFS_DATA0    = $03            ; VERA DATA0 (for fat_load_vram streaming)
}                             ; guarded: the init programs define it too

; --- SPI clock published in the $0300 magic block ----------------------------
; The init program qualifies the link once (sd_probe_clock) and leaves the
; $0306, one of the two bytes the magic block reserves. Clients adopt it with
; sd_clock_from_magic instead of each guessing for itself.
;
; $00 means "nobody probed", which is also what a stale or zeroed block reads
; as, and it maps to SLOW. Every unknown therefore degrades to the setting that
; works in every slot, so no version check is needed.
MAGIC_SPI    = $0306
SPICLK_NONE  = $00            ; not probed -> treat as slow
SPICLK_SLOW  = $01            ; ~390kHz, works in every slot
SPICLK_FAST  = $02            ; 12.5MHz, qualified by sd_probe_clock

; --- SMC: absolute stores for the side-effect registers ---------------------
; DATA0 must NEVER be written with `sta (VERA_ZP),Y`. An indexed write does a
; dummy READ of the target first, and reading DATA0 auto-increments ADDR0, so
; every byte advances the pointer twice and lands on the wrong address.
; Writing $11 $22 $33 $44 to VRAM 0 gives 00 11 00 22 00 33 00 44 with the
; indexed form. See the same note in vera_common.inc.
;
; SPI_DATA gets the same treatment as a precaution: reading it returns the
; received byte and, with Auto-TX enabled, kicks off another transfer. This
; driver leaves Auto-TX off so the dummy read should be harmless, and an
; absolute store costs nothing and removes the question entirely.
;
; Low byte = the register offset. High byte $01 is a throwaway that forces
; ACME to emit a 3-byte absolute STA/LDA, giving us an operand to patch.
; sd_patch_smc rewrites both to $CN.. and is called by sd_init.
;
; Reads (of SPI_CTRL / SPI_DATA) get the same SMC treatment as writes, for two
; reasons: (a) absolute LDA is 4 cycles vs 5 for (ZP),Y, and (b) the fast bulk
; loops below use Y as a loop counter, so they cannot also use Y as the VERA
; register offset. Reading these registers has no side effect, so the absolute
; form is safe on every host.
VDATA0   = $0103
VSPIDATA = $011E
VSPICTRL = $011F

RB_CAP_N = 5                  ; token-wait bytes kept for the diagnostic

; Error codes (stored in sd_last_err on failure)
SDERR_NONE   = $00
SDERR_CMD0   = $01            ; card never reached idle after CMD0
SDERR_ACMD41 = $02            ; init timeout (ACMD41 never returned ready)
SDERR_READ   = $03            ; block read failed (R1 != 0 or no data token)
SDERR_MBR    = $04            ; bad MBR signature / no FAT32 partition
SDERR_FIND   = $05            ; file not found in root directory

; =============================================================================
; SPI PRIMITIVES
; =============================================================================

; --- spi_xfer: A = byte out, returns A = byte received. Preserves X and Y. ---
; PRESERVING Y IS LOAD-BEARING. This routine needs Y internally as the VERA
; register offset, but the 512-byte read loop in sd_read_block indexes its
; destination with Y. If spi_xfer returned with Y = OFS_SPI_DATA ($1E), every
; byte would land on sd_buf+$1E and the loop's `iny / bne` would never reach
; zero. X is preserved for the same reason, sd_init's retry loops count with
; it.
;
; The BUSY poll is bounded, and a failure is STICKY. Bounding alone is not
; enough: a 3ms stuck-BUSY wait multiplied by the data-token loop's 32768
; retries is 98 seconds, which looks like a hang. A timeout therefore sets
; spi_fault, and every loop that polls the card checks it and gives up at
; once, turning a dead bus into a ~30ms error.
!zone spi_xfer
spi_xfer:
sx_st:  sta VSPIDATA             ; SPI_DATA -> starts transfer, absolute
                                 ; (patched by sd_patch_smc)
        stx sx_xsave
        sty sx_ysave
        ldx #$00                 ; 256 polls ~= 3ms at 1MHz. A slow-clock byte
        ldy #OFS_SPI_CTRL        ; takes ~21us and a fast-clock byte under 1us,
.wait:                           ; so this only trips on a genuinely stuck bit.
        lda (VERA_ZP),y
        bpl .ready               ; bit7 BUSY clear -> done
        dex
        bne .wait
        lda #$80                 ; sticky, and bit7 so callers can test it with
        sta spi_fault            ; BIT (preserves A and X, unlike LDA/LDX)
        lda spi_timeouts         ; saturate: a 512-byte read must not wrap it
        cmp #$FF
        beq .ready
        inc spi_timeouts
.ready:
        ldy #OFS_SPI_DATA
        lda (VERA_ZP),y          ; received byte
        ldx sx_xsave
        ldy sx_ysave
        rts

; --- spi_read_byte: clock in one byte ($FF out). Returns A. Keeps X and Y. ---
!zone spi_read_byte
spi_read_byte:
        lda #$FF
        jmp spi_xfer             ; tail call: returns A = received

; =============================================================================
; sd_PATCH_SMC: point every absolute SPI_DATA / SPI_CTRL / DATA0 store+read
; at the detected slot. Called by sd_init, which every caller runs first. Only
; the high operand byte varies. The low bytes are the register offsets, fixed
; at assembly time. Safe to call more than once. One LDA feeds many STA because
; every site wants the same high byte (the slot's $CN page).
; =============================================================================
!zone sd_patch_smc
sd_patch_smc:
        lda VERA_ZP+1            ; $C1..$C7
        sta sx_st+2              ; spi_xfer -> SPI_DATA write
        sta srd_tx+2             ; _sd_start_read -> SPI_DATA write (token TX)
        sta srd_bp+2             ; _sd_start_read -> SPI_CTRL read (BUSY poll)
        sta srd_br+2             ; _sd_start_read -> SPI_DATA read (token byte)
        sta dcr_tx+2             ; _sd_drain_crc -> SPI_DATA write
        sta dcr_bp+2             ; _sd_drain_crc -> SPI_CTRL read
        sta dcr_br+2             ; _sd_drain_crc -> SPI_DATA read
        sta vrb_tx+2             ; sd_read_block_vram -> SPI_DATA write
        sta vrb_bp+2             ; sd_read_block_vram -> SPI_CTRL read
        sta vrb_br+2             ; sd_read_block_vram -> SPI_DATA read
        sta vrb_vs+2             ; sd_read_block_vram -> DATA0 store
        sta rrb_tx+2             ; sd_read_block_ram -> SPI_DATA write
        sta rrb_bp+2             ; sd_read_block_ram -> SPI_CTRL read
        sta rrb_br+2             ; sd_read_block_ram -> SPI_DATA read
        rts

; --- spi_select / spi_deselect: assert / release CS, keep clock+autotx bits --
!zone spi_select
spi_select:
        lda spi_ctrl_base
        ora #$01                 ; CS = assert (active low is handled in HW)
        ldy #OFS_SPI_CTRL
        sta (VERA_ZP),y
        rts

!zone spi_deselect
spi_deselect:
        lda spi_ctrl_base        ; bit0 already 0 in the shadow
        ldy #OFS_SPI_CTRL
        sta (VERA_ZP),y
        lda #$FF                 ; 8 extra clocks after release (SD needs it)
        jmp spi_xfer

; --- sd_cmd: send a 6-byte command frame, return R1 in A (and sd_r1). --------
; A = command index (0-63). sd_arg[0..3] = argument MSB..LSB. sd_crc = CRC.
; CS must already be asserted by the caller. Polls up to 255 times for a
; response byte with bit7 clear, leaves $FF in sd_r1 on timeout.
!zone sd_cmd
sd_cmd:
        pha
        lda #$FF                 ; one dummy clock before the frame (Ncr)
        jsr spi_xfer
        pla
        ora #$40                 ; command byte = $40 | index
        jsr spi_xfer
        lda sd_arg+0
        jsr spi_xfer
        lda sd_arg+1
        jsr spi_xfer
        lda sd_arg+2
        jsr spi_xfer
        lda sd_arg+3
        jsr spi_xfer
        lda sd_crc
        jsr spi_xfer
        lda #$FF                 ; count in memory, not X: sd_init's CMD0 loop
        sta cmd_to               ; retries with X across this call
.wait:
        jsr spi_read_byte
        cmp #$FF
        bne .got
        bit spi_fault            ; dead bus -> stop asking (BIT keeps A and X)
        bmi .got
        dec cmd_to
        bne .wait                ; timeout -> A still $FF
.got:
        sta sd_r1
        rts

; =============================================================================
; sd_init: bring the card up in SPI mode. Carry clear = OK, set = error.
; =============================================================================
!zone sd_init
sd_init:
        jsr sd_patch_smc         ; MUST precede any spi_xfer / DATA0 write
        lda #$00
        sta spi_timeouts         ; fresh count for this bring-up
        sta spi_fault
        ; slow clock, CS deasserted
        lda #$02
        sta spi_ctrl_base
        ldy #OFS_SPI_CTRL
        lda #$02
        sta (VERA_ZP),y

        ; >= 74 clocks with CS high, DI high: send 10 x $FF
        ldx #10
.warm:
        lda #$FF
        jsr spi_xfer
        dex
        bne .warm

        jsr spi_select

        ; --- CMD0 (GO_IDLE_STATE), arg 0, CRC $95 -> expect R1 = $01 ---
        lda #$00
        sta sd_arg+0
        sta sd_arg+1
        sta sd_arg+2
        sta sd_arg+3
        lda #$95
        sta sd_crc
        ldx #10                  ; retry CMD0 a few times
.cmd0:
        lda #0
        jsr sd_cmd
        lda sd_r1
        cmp #$01
        beq .cmd0_ok
        dex
        bne .cmd0
        lda #SDERR_CMD0
        jmp .fail
.cmd0_ok:

        ; --- CMD8 (SEND_IF_COND), arg $000001AA, CRC $87 ---
        lda #$00
        sta sd_arg+0
        sta sd_arg+1
        lda #$01
        sta sd_arg+2
        lda #$AA
        sta sd_arg+3
        lda #$87
        sta sd_crc
        lda #8
        jsr sd_cmd
        lda sd_r1
        and #$04                 ; illegal command bit -> v1 card
        bne .v1
        ; v2 card: read the 4-byte R7 tail (discard, echo AA in last byte)
        jsr spi_read_byte
        jsr spi_read_byte
        jsr spi_read_byte
        jsr spi_read_byte
.v1:

        ; --- ACMD41 loop (CMD55 then CMD41 w/ HCS) until R1 = $00 ---
        lda #$00
        sta init_to+0
        lda #$40                 ; ~16384 iterations timeout
        sta init_to+1
.acmd41:
        ; CMD55 (APP_CMD)
        lda #$00
        sta sd_arg+0
        sta sd_arg+1
        sta sd_arg+2
        sta sd_arg+3
        lda #$FF
        sta sd_crc
        lda #55
        jsr sd_cmd
        ; ACMD41 arg $40000000 (HCS = support high capacity)
        lda #$40
        sta sd_arg+0
        lda #$00
        sta sd_arg+1
        sta sd_arg+2
        sta sd_arg+3
        lda #$FF
        sta sd_crc
        lda #41
        jsr sd_cmd
        lda sd_r1
        beq .ready
        ; decrement 16-bit timeout
        lda init_to+0
        bne .dec_lo
        dec init_to+1
.dec_lo:
        dec init_to+0
        lda init_to+0
        ora init_to+1
        bne .acmd41
        lda #SDERR_ACMD41
        jmp .fail
.ready:

        ; --- CMD58 (READ_OCR) -> CCS bit picks block vs byte addressing ---
        lda #$00
        sta sd_arg+0
        sta sd_arg+1
        sta sd_arg+2
        sta sd_arg+3
        lda #$FF
        sta sd_crc
        lda #58
        jsr sd_cmd
        jsr spi_read_byte        ; OCR[31:24]
        sta ocr_hi
        jsr spi_read_byte        ; OCR[23:16]
        jsr spi_read_byte        ; OCR[15:8]
        jsr spi_read_byte        ; OCR[7:0]
        lda #$00
        sta sd_block_addr
        lda ocr_hi
        and #$40                 ; CCS (bit30) -> SDHC/SDXC = block addressing
        beq .byteaddr
        lda #$01
        sta sd_block_addr
.byteaddr:

        jsr spi_deselect
        jsr sd_apply_clock       ; leave the init clock behind (see below)
        lda #SDERR_NONE
        sta sd_last_err
        clc
        rts
.fail:
        sta sd_last_err
        jsr spi_deselect
        sec
        rts

; =============================================================================
; sd_apply_clock: set SPI_CTRL from sd_fast_clock, CS deasserted, Auto-TX off.
; Bring-up always runs at the ~390kHz slow clock because the SD spec requires
; it. Everything after runs at whatever sd_fast_clock says: 0 = stay slow
; (default), 1 = 12.5MHz. The switch happens exactly between "init worked" and
; "first block read", so it needs to be testable without a rebuild. SD-DIAG
; flips it and retries, and its stress stage counts errors at both.
;
; Why slow is the default: measured on an Apple IIe, 64-sector read stress.
;   slot 4: 0 errors at 12.5MHz, 0 at 390kHz
;   slot 2: 3 errors at 12.5MHz, 0 at 390kHz
;   slot 1: data token corrupted outright at 12.5MHz (saw EB 58, the FAT32
;           boot sector's first bytes, instead of the $FE token)
; 12.5MHz is marginal in low slots. The cost of dropping to 390kHz is small
; because the 1MHz 6502 loop is close to the bottleneck either way: ~27 cycles
; per byte at 12.5MHz against ~42 with the slow clock's extra BUSY spin.
; Clobbers A, X, Y.
; =============================================================================
!zone sd_apply_clock
sd_apply_clock:
        lda #$02                 ; slow-clock bit
        ldx sd_fast_clock
        beq .set
        lda #$00
.set:   sta spi_ctrl_base
        ldy #OFS_SPI_CTRL
        sta (VERA_ZP),y
        rts

; =============================================================================
; sd_probe_clock: decide what this slot and card can actually hold.
;
; Returns A = SPICLK_FAST or SPICLK_SLOW, with sd_fast_clock and SPI_CTRL left
; matching the verdict. Precondition: sd_init has succeeded.
;
; Method: read a reference sector at 390kHz into fat_buf, then read the SAME
; sector PROBE_N times at 12.5MHz, comparing all 512 bytes every time. Any
; mismatch or read error picks slow and stops immediately.
;
; Comparing the DATA is the whole point, and a pass/fail probe would not work.
; A read only reports failure when corruption destroys the $FE data token. A
; flipped bit inside the payload is completely invisible to the protocol.
; Measured on an Apple IIe in slot 2, only ~5% of reads failed outright at
; 12.5MHz, so an 8-read pass/fail probe would call that slot clean about 66% of
; the time and then die mid-slideshow. Comparing 512 bytes tests ~4096 bits per
; read instead of one, and catches the silent corruption directly.
;
; Re-reading one LBA is deliberate. The flash is not what is marginal, the
; wire is, and every repeat still clocks 512 bytes across it.
; =============================================================================
PROBE_N = 8                      ; fast reads that must all match the reference

!zone sd_probe_clock
sd_probe_clock:
        lda #$00                 ; reference read at the slow clock
        sta sd_fast_clock
        jsr sd_apply_clock
        jsr .set_lba
        lda #<fat_buf
        sta ZP_PTR2
        lda #>fat_buf
        sta ZP_PTR2+1
        jsr sd_read_block
        bcs .slow                ; cannot read even slowly: nothing to qualify

        lda #$01                 ; now try the fast clock against it
        sta sd_fast_clock
        jsr sd_apply_clock
        lda #PROBE_N
        sta probe_left
.loop:
        jsr .set_lba
        lda #<sd_buf
        sta ZP_PTR2
        lda #>sd_buf
        sta ZP_PTR2+1
        jsr sd_read_block
        bcs .slow
        jsr .compare
        bcs .slow
        dec probe_left
        bne .loop

        lda #$01                 ; PROBE_N reads, byte for byte, no drift
        sta sd_fast_clock
        jsr sd_apply_clock
        lda #SPICLK_FAST
        rts
.slow:
        lda #$00
        sta sd_fast_clock
        jsr sd_apply_clock
        lda #SPICLK_SLOW
        rts

.set_lba:
        lda #$00                 ; LBA 0 always exists (MBR or VBR)
        sta sd_lba+0
        sta sd_lba+1
        sta sd_lba+2
        sta sd_lba+3
        rts

; sd_buf vs fat_buf, 512 bytes in two Y-indexed passes. Carry set = mismatch.
.compare:
        ldy #$00
.c0:    lda sd_buf,y
        cmp fat_buf,y
        bne .bad
        iny
        bne .c0
.c1:    lda sd_buf+256,y
        cmp fat_buf+256,y
        bne .bad
        iny
        bne .c1
        clc
        rts
.bad:   sec
        rts

; =============================================================================
; sd_clock_from_magic: adopt the clock init qualified for this slot.
; Call before sd_init. Anything other than SPICLK_FAST means slow, so an
; unprobed or stale magic block lands on the setting that always works.
; =============================================================================
!zone sd_clock_from_magic
sd_clock_from_magic:
        lda MAGIC_SPI
        cmp #SPICLK_FAST
        beq .fast
        lda #$00
        sta sd_fast_clock
        rts
.fast:
        lda #$01
        sta sd_fast_clock
        rts

; =============================================================================
; sd_read_block: read 512 bytes at sd_lba (4-byte LE) into (ZP_PTR2).
; Caller sets sd_lba and ZP_PTR2 (= buffer base) before calling.
; Carry clear = OK, set = error (sd_last_err = SDERR_READ).
; =============================================================================
!zone sd_read_block
sd_read_block:
        lda #$00                 ; every block read gets a fresh chance at the
        sta spi_fault            ; bus. The flag only short-circuits this one
        lda #'S'                 ; trace: entered, about to assert CS
        jsr sd_trace
        jsr spi_select

        lda sd_block_addr
        beq .byteaddr
        ; block addressing: arg = sd_lba (MSB first)
        lda sd_lba+3
        sta sd_arg+0
        lda sd_lba+2
        sta sd_arg+1
        lda sd_lba+1
        sta sd_arg+2
        lda sd_lba+0
        sta sd_arg+3
        jmp .send
.byteaddr:
        ; byte addressing: arg = sd_lba << 9 (multiply by 512)
        lda sd_lba+0
        sta rb_ba+0
        lda sd_lba+1
        sta rb_ba+1
        lda sd_lba+2
        sta rb_ba+2
        lda sd_lba+3
        sta rb_ba+3
        ldx #9
.shl:
        asl rb_ba+0
        rol rb_ba+1
        rol rb_ba+2
        rol rb_ba+3
        dex
        bne .shl
        lda rb_ba+3
        sta sd_arg+0
        lda rb_ba+2
        sta sd_arg+1
        lda rb_ba+1
        sta sd_arg+2
        lda rb_ba+0
        sta sd_arg+3
.send:
        lda #'C'                 ; trace: argument built, sending CMD17
        jsr sd_trace
        lda #$FF
        sta sd_crc
        lda #17                  ; CMD17 READ_SINGLE_BLOCK
        jsr sd_cmd
        lda #'R'                 ; trace: CMD17 answered
        jsr sd_trace
        lda sd_r1
        bne .err

        ; wait for data token $FE (16-bit timeout). The first few bytes are
        ; kept for the diagnostic: all $FF means the card is just making us
        ; wait, all $00 means MISO is stuck low, anything else is garbage on
        ; the wire.
        lda #'T'                 ; trace: waiting for the data token
        jsr sd_trace
        lda #$00
        sta rb_ncap
        sta rb_to+0
        lda #$80
        sta rb_to+1
.tok:
        jsr spi_read_byte
        ldx rb_ncap
        cpx #RB_CAP_N
        bcs .nocap
        sta rb_cap,x
        inc rb_ncap
.nocap:
        cmp #$FE
        beq .gotdata
        bit spi_fault            ; dead bus: 32768 more tries changes nothing
        bpl .keeptrying
        jmp .err
.keeptrying:
        lda rb_to+0
        bne .dec_lo
        dec rb_to+1
.dec_lo:
        dec rb_to+0
        lda rb_to+0
        ora rb_to+1
        bne .tok
        jmp .err                 ; no data token -> error
.gotdata:
        lda #'D'                 ; trace: got the token, streaming 512 bytes
        jsr sd_trace
        ; read 512 bytes into (ZP_PTR2): two 256-byte passes, Y wraps
        ldy #$00
.rd0:
        jsr spi_read_byte
        sta (ZP_PTR2),y
        iny
        bne .rd0
        inc ZP_PTR2+1
.rd1:
        jsr spi_read_byte
        sta (ZP_PTR2),y
        iny
        bne .rd1
        dec ZP_PTR2+1            ; restore caller's pointer
        ; discard 2 CRC bytes
        jsr spi_read_byte
        jsr spi_read_byte
        jsr spi_deselect
        lda #'.'                 ; trace: clean exit
        jsr sd_trace
        clc
        rts
.err:
        jsr spi_deselect
        lda #'!'                 ; trace: error exit
        jsr sd_trace
        lda #SDERR_READ
        sta sd_last_err
        sec
        rts

; =============================================================================
; FAST SD BLOCK READ: SD -> VRAM (no sd_buf intermediate) and SD -> RAM.
;
; Same SPI protocol as sd_read_block above (write $FF -> poll BUSY -> read byte,
; one transfer per byte). The speedup comes from removing the per-byte JSR/RTS
; and the X/Y save+restore that spi_xfer carries for its generic callers:
;   - The 512-byte data phase is a tight inlined loop. No JSR per byte.
;   - Absolute SMC-patched accesses to SPI_CTRL / SPI_DATA / DATA0 (no Y index,
;     no (ZP),Y indirection cost). Y is free to be the loop counter.
;
; Auto-TX (SPI_CTRL bit 2) is NOT used. Enabling it mid-transfer means writing
; SPI_CTRL, but the spi_ctrl_base shadow does not track the CS bit, so doing so
; released CS and aborted the command (SD ERROR=03 on real IIgs hardware). The
; explicit write-poll-read here never touches SPI_CTRL during the transfer, so
; CS stays asserted from spi_select to spi_deselect.
;
;   - sd_read_block_vram streams each received byte straight to DATA0. ADDR0
;     auto-increment (set up by the caller) advances the VRAM pointer for free.
;   - sd_read_block_ram writes to (ZP_PTR2),y in two 256-byte Y-indexed passes.
;
; Per-byte cost drops from ~69 cycles (sd_read_block) to ~27 cycles (VRAM path)
; and ~29 cycles (RAM path). At 1 MHz a full 76800-byte bitmap goes from ~7.7 s
; to ~2.4 s.
;
; Both routines read a full 512-byte sector. Callers with a partial tail sector
; (file size not a multiple of 512) must use the slow sd_read_block instead.
; Current VRAM-streaming callers (SD-SLIDES at 77312 B, SD-IMAGE at 76800 B)
; are exact multiples of 512 so this is not a limitation in practice.
;
; Public entry points return the same convention as sd_read_block: carry clear
; = OK, carry set = error with sd_last_err = SDERR_READ.
; =============================================================================

; --- _sd_send_cmd17: build CMD17 arg from sd_lba, send it, check R1. ----------
; Private helper. Caller has already asserted CS. Carry clear = R1 was $00,
; ready for the data token. Carry set = error (sd_last_err set).
!zone _sd_send_cmd17
_sd_send_cmd17:
        lda sd_block_addr
        beq .byteaddr
        ; block addressing: arg = sd_lba (MSB first)
        lda sd_lba+3
        sta sd_arg+0
        lda sd_lba+2
        sta sd_arg+1
        lda sd_lba+1
        sta sd_arg+2
        lda sd_lba+0
        sta sd_arg+3
        jmp .send
.byteaddr:
        ; byte addressing: arg = sd_lba << 9
        lda sd_lba+0
        sta rb_ba+0
        lda sd_lba+1
        sta rb_ba+1
        lda sd_lba+2
        sta rb_ba+2
        lda sd_lba+3
        sta rb_ba+3
        ldx #9
.shl:
        asl rb_ba+0
        rol rb_ba+1
        rol rb_ba+2
        rol rb_ba+3
        dex
        bne .shl
        lda rb_ba+3
        sta sd_arg+0
        lda rb_ba+2
        sta sd_arg+1
        lda rb_ba+1
        sta sd_arg+2
        lda rb_ba+0
        sta sd_arg+3
.send:
        lda #$FF
        sta sd_crc
        lda #17                  ; CMD17 READ_SINGLE_BLOCK
        jsr sd_cmd
        lda sd_r1
        bne .err
        clc
        rts
.err:
        lda #SDERR_READ
        sta sd_last_err
        sec
        rts

; --- _sd_start_read: CMD17 + bounded $FE token wait. -------------------------
; Private helper. Caller has asserted CS and set sd_lba.
; On success (carry clear): the $FE data token has been consumed. The caller's
;   bulk loop reads each data byte with the same write-poll-read pattern.
; On error (carry set): sd_last_err is set. CS is still asserted. The caller
;   must deselect.
;
; SPI_CTRL is never touched here. CS must stay asserted across CMD17 and the
; data phase, but the spi_ctrl_base shadow does NOT track the CS bit (see
; spi_select), so writing it back to enable Auto-TX released CS and aborted the
; command. That was the SD ERROR=03 bug. The explicit write-poll-read below
; leaves SPI_CTRL alone, so CS persists from spi_select to spi_deselect.
!zone _sd_start_read
_sd_start_read:
        jsr _sd_send_cmd17
        bcs .err

        ; wait for the $FE data token. 16-bit timeout like sd_read_block.
        lda #$00
        sta rb_to+0
        lda #$80
        sta rb_to+1
.tok_loop:
        lda #$FF
srd_tx: sta VSPIDATA            ; start transfer (patched)
        ldx #$00
.twait:
srd_bp: lda VSPICTRL            ; poll BUSY (patched)
        bpl .tok_ok
        dex
        bne .twait
        jmp .err                ; BUSY stuck
.tok_ok:
srd_br: lda VSPIDATA            ; received byte (patched)
        cmp #$FE
        beq .done
        lda rb_to+0
        bne .td_lo
        dec rb_to+1
.td_lo:
        dec rb_to+0
        lda rb_to+0
        ora rb_to+1
        bne .tok_loop
        jmp .err                ; no token within timeout
.done:
        clc
        rts
.err:
        lda #SDERR_READ
        sta sd_last_err
        sec
        rts

; --- _sd_drain_crc: read+discard the 2 CRC bytes. ----------------------------
; Private helper. Caller is still in the bulk phase (CS asserted). Same
; write-poll-read pattern as the bulk loop. Carry clear = OK, carry set =
; BUSY stuck (sd_last_err set).
!zone _sd_drain_crc
_sd_drain_crc:
        ldy #2
.drain:
        lda #$FF
dcr_tx: sta VSPIDATA            ; patched
        ldx #$00
.dw:
dcr_bp: lda VSPICTRL            ; patched
        bpl .dok
        dex
        bne .dw
        jmp .err
.dok:
dcr_br: lda VSPIDATA            ; patched
        dey
        bne .drain
        clc
        rts
.err:
        lda #SDERR_READ
        sta sd_last_err
        sec
        rts

; =============================================================================
; sd_read_block_vram: read sd_lba straight into VERA via DATA0 (no sd_buf).
; Caller sets ADDR0 (with the wanted increment nibble) before calling.
; Carry clear = OK. Carry set = error (sd_last_err = SDERR_READ).
; =============================================================================
!zone sd_read_block_vram
sd_read_block_vram:
        lda #$00
        sta spi_fault
        jsr spi_select
        jsr _sd_start_read
        bcs vrb_err
        ; 512 bytes SD -> DATA0. ADDR0 auto-increment advances the VRAM pointer,
        ; so no destination index is needed. Y is free as the byte counter. Two
        ; 256-byte passes (Y wraps) share one loop body via vrb_passes.
        lda #2
        sta vrb_passes
        ldy #$00
vrb_loop:
        lda #$FF
vrb_tx: sta VSPIDATA            ; start transfer (patched)
        ldx #$00
vrb_bp: lda VSPICTRL            ; poll BUSY (patched)
        bpl vrb_br
        dex
        bne vrb_bp
        jmp vrb_err_mid          ; BUSY stuck (~3ms)
vrb_br: lda VSPIDATA            ; received byte (patched)
vrb_vs: sta VDATA0              ; -> VRAM, ADDR0 auto-increments (patched)
        iny
        bne vrb_loop
        dec vrb_passes
        beq vrb_done
        jmp vrb_loop            ; pass 2 (Y has wrapped to 0)
vrb_done:
        jsr _sd_drain_crc
        php                     ; preserve carry from _sd_drain_crc
        jsr spi_deselect
        plp
        rts
vrb_err_mid:
        lda #SDERR_READ
        sta sd_last_err
vrb_err:
        php
        jsr spi_deselect
        plp
        rts

; =============================================================================
; sd_read_block_ram: read sd_lba into (ZP_PTR2). Caller sets ZP_PTR2 = dest.
; ZP_PTR2 is restored to its original value on return (caller advances it).
; Carry clear = OK. Carry set = error (sd_last_err = SDERR_READ).
; =============================================================================
!zone sd_read_block_ram
sd_read_block_ram:
        lda #$00
        sta spi_fault
        jsr spi_select
        jsr _sd_start_read
        bcs rrb_err
        ; 512 bytes -> (ZP_PTR2),y, two 256-byte Y-indexed passes sharing one
        ; loop body via rrb_passes.
        lda #2
        sta rrb_passes
        ldy #$00
rrb_loop:
        lda #$FF
rrb_tx: sta VSPIDATA            ; start transfer (patched)
        ldx #$00
rrb_bp: lda VSPICTRL            ; poll BUSY (patched)
        bpl rrb_br
        dex
        bne rrb_bp
        jmp rrb_err_mid
rrb_br: lda VSPIDATA            ; received byte (patched)
        sta (ZP_PTR2),y
        iny
        bne rrb_loop
        ; one 256-byte pass done (Y wrapped to 0). Bump to the next page only
        ; between passes, never after the last one: exactly one inc per call,
        ; matched by the one dec at rrb_done, so the caller's pointer is
        ; restored. (An inc inside the loop body ran after every pass = 2 incs,
        ; leaked 256 bytes/sector, and the writes eventually overran the
        ; caller's buffer. That crashed SD-HIRES with a BRK.)
        dec rrb_passes
        beq rrb_done
        inc ZP_PTR2+1
        jmp rrb_loop            ; Y is already 0
rrb_done:
        dec ZP_PTR2+1           ; restore caller's pointer
        jsr _sd_drain_crc
        php
        jsr spi_deselect
        plp
        rts
rrb_err_mid:
        lda #SDERR_READ
        sta sd_last_err
rrb_err:
        php
        jsr spi_deselect
        plp
        rts


; A, X, Y and the carry, so it can be dropped anywhere without disturbing the
; code around it. Off by default: the streaming loaders read hundreds of
; sectors and must not spray the screen.
;
; This exists because a freeze cannot be diagnosed after the fact. Storing a
; progress code in a variable is useless if the machine never gets far enough
; to print it, so the markers go out as they happen.
; =============================================================================
!zone sd_trace
sd_trace:
        bit sd_trace_on
        bpl .off
        php
        pha
        stx sdt_x
        sty sdt_y
        ora #$80                 ; Apple II wants the high bit set
        jsr COUT
        ldx sdt_x
        ldy sdt_y
        pla
        plp
.off:   rts

; =============================================================================
; fat_is_vbr: does sd_buf hold a FAT32 volume boot record instead of an MBR?
;
; Not every card is partitioned. A "superfloppy" format puts the VBR directly
; at LBA 0 with no partition table at all, and since a VBR also ends in 55 AA
; the signature check cannot tell them apart. Read as an MBR, a VBR's partition
; entry lands in the boot-message text: the 256MB test card reported partition
; type $6E, which is ASCII 'n'.
;
; BS_FilSysType at offset $52 reads "FAT32   " on a FAT32 VBR and is the most
; specific marker available. Carry set = VBR (partition starts at LBA 0).
; Clobbers A, Y.
; =============================================================================
!zone fat_is_vbr
fat_is_vbr:
        ldy #7
.chk:   lda sd_buf+$52,y
        cmp fat32_sig,y
        bne .no
        dey
        bpl .chk
        sec
        rts
.no:    clc
        rts
fat32_sig: !text "FAT32   "

; =============================================================================
; fat_mount: read MBR + BPB, compute the FAT32 layout. Carry set = error.
; Handles both partitioned cards and superfloppies (see fat_is_vbr).
; =============================================================================
!zone fat_mount
fat_mount:
        ; read MBR (LBA 0) into sd_buf
        lda #$00
        sta sd_lba+0
        sta sd_lba+1
        sta sd_lba+2
        sta sd_lba+3
        lda #<sd_buf
        sta ZP_PTR2
        lda #>sd_buf
        sta ZP_PTR2+1
        jsr sd_read_block
        bcc .rd1ok
        jmp .err
.rd1ok:

        ; signature check
        lda sd_buf+$1FE
        cmp #$55
        beq .sig2
        jmp .badmbr
.sig2:
        lda sd_buf+$1FF
        cmp #$AA
        beq .sigok
        jmp .badmbr
.sigok:
        jsr fat_is_vbr
        bcc .has_mbr
        lda #$00                 ; superfloppy: the volume starts at LBA 0 and
        sta part_lba+0           ; sd_buf already holds its BPB. Re-reading it
        sta part_lba+1           ; below costs one sector and keeps one path.
        sta part_lba+2
        sta part_lba+3
        jmp .read_vbr
.has_mbr:
        ; partition 0: type @ $1BE+4, start LBA @ $1BE+8 (4 bytes LE)
        lda sd_buf+$1BE+4
        cmp #$0B
        beq .typeok
        cmp #$0C
        beq .typeok
        cmp #$0E                 ; FAT16 LBA, tolerated but really FAT32-only
        beq .typeok
        jmp .badmbr
.typeok:
        lda sd_buf+$1BE+8
        sta part_lba+0
        lda sd_buf+$1BE+9
        sta part_lba+1
        lda sd_buf+$1BE+10
        sta part_lba+2
        lda sd_buf+$1BE+11
        sta part_lba+3

.read_vbr:
        ; read the volume boot record / BPB at part_lba
        lda part_lba+0
        sta sd_lba+0
        lda part_lba+1
        sta sd_lba+1
        lda part_lba+2
        sta sd_lba+2
        lda part_lba+3
        sta sd_lba+3
        lda #<sd_buf
        sta ZP_PTR2
        lda #>sd_buf
        sta ZP_PTR2+1
        jsr sd_read_block
        bcc .rd2ok
        jmp .err
.rd2ok:

        ; sectors per cluster @ $0D. Must be non-zero: clus_to_lba takes its
        ; log2 by shifting until it hits 1, and 0 shifts to 0 forever. Reject
        ; a garbage BPB here rather than spinning later.
        lda sd_buf+$0D
        sta secs_per_clus
        bne .spc_ok
        jmp .badmbr
.spc_ok:

        ; fat_begin_lba = part_lba + RsvdSecCnt(@$0E, 2 bytes LE)
        clc
        lda part_lba+0
        adc sd_buf+$0E
        sta fat_begin_lba+0
        lda part_lba+1
        adc sd_buf+$0F
        sta fat_begin_lba+1
        lda part_lba+2
        adc #0
        sta fat_begin_lba+2
        lda part_lba+3
        adc #0
        sta fat_begin_lba+3

        ; clus_begin_lba = fat_begin_lba + NumFATs(@$10) * FATSz32(@$24, 4 LE)
        lda fat_begin_lba+0
        sta clus_begin_lba+0
        lda fat_begin_lba+1
        sta clus_begin_lba+1
        lda fat_begin_lba+2
        sta clus_begin_lba+2
        lda fat_begin_lba+3
        sta clus_begin_lba+3
        ldx sd_buf+$10           ; NumFATs (usually 2)
.addfat:
        clc
        lda clus_begin_lba+0
        adc sd_buf+$24
        sta clus_begin_lba+0
        lda clus_begin_lba+1
        adc sd_buf+$25
        sta clus_begin_lba+1
        lda clus_begin_lba+2
        adc sd_buf+$26
        sta clus_begin_lba+2
        lda clus_begin_lba+3
        adc sd_buf+$27
        sta clus_begin_lba+3
        dex
        bne .addfat

        ; root_clus @ $2C (4 bytes LE)
        lda sd_buf+$2C
        sta root_clus+0
        lda sd_buf+$2D
        sta root_clus+1
        lda sd_buf+$2E
        sta root_clus+2
        lda sd_buf+$2F
        sta root_clus+3

        ; invalidate FAT sector cache
        lda #$FF
        sta fat_cache_lba+0
        sta fat_cache_lba+1
        sta fat_cache_lba+2
        sta fat_cache_lba+3
        clc
        rts
.badmbr:
        lda #SDERR_MBR
        sta sd_last_err
.err:
        sec
        rts

; =============================================================================
; clus_to_lba: cur_lba = clus_begin_lba + (cur_clus - 2) * secs_per_clus.
; secs_per_clus is a power of two, so multiply is a left shift.
; =============================================================================
!zone clus_to_lba
clus_to_lba:
        sec
        lda cur_clus+0
        sbc #2
        sta tmp32+0
        lda cur_clus+1
        sbc #0
        sta tmp32+1
        lda cur_clus+2
        sbc #0
        sta tmp32+2
        lda cur_clus+3
        sbc #0
        sta tmp32+3
        ; X = log2(secs_per_clus). fat_mount rejects 0, but belt and braces:
        ; 0 never reaches 1 by shifting, and this loop has no other exit.
        ldx #0
        lda secs_per_clus
        beq .counted
.count:
        cmp #1
        beq .counted
        lsr
        inx
        jmp .count
.counted:
        cpx #0
        beq .noshift
.sh:
        asl tmp32+0
        rol tmp32+1
        rol tmp32+2
        rol tmp32+3
        dex
        bne .sh
.noshift:
        clc
        lda clus_begin_lba+0
        adc tmp32+0
        sta cur_lba+0
        lda clus_begin_lba+1
        adc tmp32+1
        sta cur_lba+1
        lda clus_begin_lba+2
        adc tmp32+2
        sta cur_lba+2
        lda clus_begin_lba+3
        adc tmp32+3
        sta cur_lba+3
        rts

; =============================================================================
; fat_next_cluster: cur_clus = FAT[cur_clus]. Carry set = end of chain.
; Uses fat_buf as a one-sector cache (fat_cache_lba tracks what's loaded).
; =============================================================================
!zone fat_next_cluster
fat_next_cluster:
        ; tmp32 = cur_clus >> 7  (FAT sector offset = cluster / 128)
        lda cur_clus+0
        sta tmp32+0
        lda cur_clus+1
        sta tmp32+1
        lda cur_clus+2
        sta tmp32+2
        lda cur_clus+3
        sta tmp32+3
        ldx #7
.sr:
        lsr tmp32+3
        ror tmp32+2
        ror tmp32+1
        ror tmp32+0
        dex
        bne .sr

        ; wanted = fat_begin_lba + tmp32
        clc
        lda fat_begin_lba+0
        adc tmp32+0
        sta wanted_lba+0
        lda fat_begin_lba+1
        adc tmp32+1
        sta wanted_lba+1
        lda fat_begin_lba+2
        adc tmp32+2
        sta wanted_lba+2
        lda fat_begin_lba+3
        adc tmp32+3
        sta wanted_lba+3

        ; cached?
        lda wanted_lba+0
        cmp fat_cache_lba+0
        bne .reload
        lda wanted_lba+1
        cmp fat_cache_lba+1
        bne .reload
        lda wanted_lba+2
        cmp fat_cache_lba+2
        bne .reload
        lda wanted_lba+3
        cmp fat_cache_lba+3
        beq .cached
.reload:
        lda wanted_lba+0
        sta sd_lba+0
        lda wanted_lba+1
        sta sd_lba+1
        lda wanted_lba+2
        sta sd_lba+2
        lda wanted_lba+3
        sta sd_lba+3
        lda #<fat_buf
        sta ZP_PTR2
        lda #>fat_buf
        sta ZP_PTR2+1
        jsr sd_read_block
        bcs .eoc                 ; read error -> treat as end of chain
        lda wanted_lba+0
        sta fat_cache_lba+0
        lda wanted_lba+1
        sta fat_cache_lba+1
        lda wanted_lba+2
        sta fat_cache_lba+2
        lda wanted_lba+3
        sta fat_cache_lba+3
.cached:
        ; entry offset within the sector = (cur_clus & $7F) * 4
        lda cur_clus+0
        and #$7F
        sta mtmp+0
        lda #0
        sta mtmp+1
        asl mtmp+0
        rol mtmp+1
        asl mtmp+0
        rol mtmp+1               ; mtmp = offset (0..508)
        clc
        lda #<fat_buf
        adc mtmp+0
        sta ZP_PTR2
        lda #>fat_buf
        adc mtmp+1
        sta ZP_PTR2+1
        ; read 4-byte FAT32 entry, mask top nibble
        ldy #0
        lda (ZP_PTR2),y
        sta cur_clus+0
        iny
        lda (ZP_PTR2),y
        sta cur_clus+1
        iny
        lda (ZP_PTR2),y
        sta cur_clus+2
        iny
        lda (ZP_PTR2),y
        and #$0F
        sta cur_clus+3
        ; end of chain? cur_clus >= $0FFFFFF8
        lda cur_clus+3
        cmp #$0F
        bne .not_eoc
        lda cur_clus+2
        cmp #$FF
        bne .not_eoc
        lda cur_clus+1
        cmp #$FF
        bne .not_eoc
        lda cur_clus+0
        cmp #$F8
        bcc .not_eoc
.eoc:
        sec
        rts
.not_eoc:
        clc
        rts

; =============================================================================
; fat_find: locate an 8.3 file in the ROOT directory.
; Input: ZP_PTR -> 11-byte space-padded uppercase name, such as "IMAGE   BIN".
; On success (carry clear): file_first_clus + file_size set.
; On failure (carry set): sd_last_err = SDERR_FIND.
; =============================================================================
!zone fat_find
fat_find:
        ldy #10
.cpname:
        lda (ZP_PTR),y
        sta search_name,y
        dey
        bpl .cpname

        lda root_clus+0
        sta cur_clus+0
        lda root_clus+1
        sta cur_clus+1
        lda root_clus+2
        sta cur_clus+2
        lda root_clus+3
        sta cur_clus+3
.clus_loop:
        jsr clus_to_lba
        lda secs_per_clus
        sta sects_left
.sect_loop:
        lda cur_lba+0
        sta sd_lba+0
        lda cur_lba+1
        sta sd_lba+1
        lda cur_lba+2
        sta sd_lba+2
        lda cur_lba+3
        sta sd_lba+3
        lda #<sd_buf
        sta ZP_PTR2
        lda #>sd_buf
        sta ZP_PTR2+1
        jsr sd_read_block
        bcc .rdok
        jmp .err
.rdok:
        lda #<sd_buf
        sta ZP_PTR2
        lda #>sd_buf
        sta ZP_PTR2+1
        ldx #16                  ; 16 dir entries per 512-byte sector
.entry_loop:
        ldy #0
        lda (ZP_PTR2),y
        bne .not_di_end
        jmp .notfound            ; $00 first byte = end of directory
.not_di_end:
        cmp #$E5
        beq .next_entry          ; deleted
        ldy #$0B
        lda (ZP_PTR2),y          ; attribute byte
        cmp #$0F
        beq .next_entry          ; long-filename entry
        and #$08
        bne .next_entry          ; volume label
        ; compare 11 name bytes
        ldy #10
.cmp:
        lda (ZP_PTR2),y
        cmp search_name,y
        bne .next_entry
        dey
        bpl .cmp
        ; MATCH: first cluster hi @ $14, lo @ $1A, size @ $1C (4 LE)
        ldy #$14
        lda (ZP_PTR2),y
        sta file_first_clus+2
        iny
        lda (ZP_PTR2),y
        sta file_first_clus+3
        ldy #$1A
        lda (ZP_PTR2),y
        sta file_first_clus+0
        iny
        lda (ZP_PTR2),y
        sta file_first_clus+1
        ldy #$1C
        lda (ZP_PTR2),y
        sta file_size+0
        iny
        lda (ZP_PTR2),y
        sta file_size+1
        iny
        lda (ZP_PTR2),y
        sta file_size+2
        iny
        lda (ZP_PTR2),y
        sta file_size+3
        clc
        rts
.next_entry:
        clc
        lda ZP_PTR2
        adc #32
        sta ZP_PTR2
        bcc .noc
        inc ZP_PTR2+1
.noc:
        dex
        beq .sector_done
        jmp .entry_loop
.sector_done:
        ; next sector within this cluster
        inc cur_lba+0
        bne .sdec
        inc cur_lba+1
        bne .sdec
        inc cur_lba+2
        bne .sdec
        inc cur_lba+3
.sdec:
        dec sects_left
        beq .cluster_done
        jmp .sect_loop
.cluster_done:
        ; next cluster in the root's chain
        jsr fat_next_cluster
        bcs .notfound
        jmp .clus_loop
.notfound:
        lda #SDERR_FIND
        sta sd_last_err
.err:
        sec
        rts

; =============================================================================
; fat_open: reset the streaming reader for the file found by fat_find.
; =============================================================================
!zone fat_open
fat_open:
        lda file_first_clus+0
        sta cur_clus+0
        lda file_first_clus+1
        sta cur_clus+1
        lda file_first_clus+2
        sta cur_clus+2
        lda file_first_clus+3
        sta cur_clus+3
        lda file_size+0
        sta bytes_left+0
        lda file_size+1
        sta bytes_left+1
        lda file_size+2
        sta bytes_left+2
        lda file_size+3
        sta bytes_left+3
        lda #1
        sta need_first
        lda #0
        sta sects_left
        rts

; =============================================================================
; fat_read_next_sector: read the file's next data sector into sd_buf.
; Carry set = no more data (EOF or end of chain). On carry clear, this_len
; (16-bit) = valid bytes in sd_buf (1..512), and bytes_left is decremented.
; =============================================================================
!zone fat_read_next_sector
fat_read_next_sector:
        lda bytes_left+0
        ora bytes_left+1
        ora bytes_left+2
        ora bytes_left+3
        bne .havebytes
        sec                      ; EOF
        rts
.havebytes:
        lda sects_left
        bne .read
        ; need a new cluster
        lda need_first
        beq .advance
        lda #0
        sta need_first
        jmp .setclus
.advance:
        jsr fat_next_cluster
        bcc .setclus
        jmp .eof
.setclus:
        jsr clus_to_lba
        lda secs_per_clus
        sta sects_left
.read:
        lda cur_lba+0
        sta sd_lba+0
        lda cur_lba+1
        sta sd_lba+1
        lda cur_lba+2
        sta sd_lba+2
        lda cur_lba+3
        sta sd_lba+3
        ; track_only: skip the actual sector read. Used by the fast streaming
        ; loaders (fat_load_vram / fat_load_ram) which call sd_read_block_vram
        ; or sd_read_block_ram themselves with the sd_lba we just published.
        ; The LBA tracking and bytes_left accounting below still happen, so a
        ; track_only caller can read every sector the chain walks past.
        lda fat_track_only
        bne .skip_read
        lda #<sd_buf
        sta ZP_PTR2
        lda #>sd_buf
        sta ZP_PTR2+1
        jsr sd_read_block
        bcc .rdok
        jmp .eof
.skip_read:
        clc
.rdok:
        ; advance cur_lba, dec sects_left
        inc cur_lba+0
        bne .a1
        inc cur_lba+1
        bne .a1
        inc cur_lba+2
        bne .a1
        inc cur_lba+3
.a1:
        dec sects_left

        ; this_len = min(512, bytes_left), then bytes_left -= this_len
        lda bytes_left+3
        ora bytes_left+2
        bne .full
        lda bytes_left+1
        cmp #$02
        bcc .partial             ; hi byte < 2 -> < 512
        bne .full                ; hi byte > 2 -> > 512
        ; hi byte == 2 -> >= 512 -> full
.full:
        lda #<512
        sta this_len+0
        lda #>512
        sta this_len+1
        sec
        lda bytes_left+0
        sbc #<512
        sta bytes_left+0
        lda bytes_left+1
        sbc #>512
        sta bytes_left+1
        lda bytes_left+2
        sbc #0
        sta bytes_left+2
        lda bytes_left+3
        sbc #0
        sta bytes_left+3
        clc
        rts
.partial:
        lda bytes_left+0
        sta this_len+0
        lda bytes_left+1
        sta this_len+1
        lda #0
        sta bytes_left+0
        sta bytes_left+1
        sta bytes_left+2
        sta bytes_left+3
        clc
        rts
.eof:
        sec
        rts

; =============================================================================
; fat_load_vram: stream the found file straight into VERA via DATA0.
; Input: ld_vaddr+0/+1/+2 = ADDR0_L/M/H (H includes stride nibble + bit16).
; Precondition: fat_find succeeded. Carry set = error.
;
; Uses the fast sd_read_block_vram path: bytes go SD -> DATA0 with no sd_buf
; intermediate. Assumes the file size is a multiple of 512 (the slow
; sd_read_block handles partial tails, this path reads a full sector each call).
; =============================================================================
!zone fat_load_vram
fat_load_vram:
        ; ADDR0 = ld_vaddr (caller's VRAM dest, with increment nibble)
        ldy #$00
        lda ld_vaddr+0
        sta (VERA_ZP),y
        ldy #$01
        lda ld_vaddr+1
        sta (VERA_ZP),y
        ldy #$02
        lda ld_vaddr+2
        sta (VERA_ZP),y

        lda #1
        sta fat_track_only
        jsr fat_open
.loop:
        jsr fat_read_next_sector  ; tracks LBA -> sd_lba, advances chain
        bcs .done
        jsr sd_read_block_vram    ; reads sd_lba straight to VRAM
        bcc .loop
        ; read error
        lda #0
        sta fat_track_only
        sec
        rts
.done:
        lda #0
        sta fat_track_only
        clc
        rts

; =============================================================================
; fat_load_vram_pal: stream a palette+bitmap file into VRAM.
;
; File layout:
;   bytes 0..511       VERA palette, 256 entries x 2 bytes -> VRAM $1FA00
;   bytes 512..end     bitmap                              -> ld_vaddr
;
; The palette is exactly 512 bytes and comes first, so the split lands exactly
; on a sector boundary. ADDR0 is set to $1FA00 for the first sector, then to
; ld_vaddr for the rest.
;
; Uses the fast sd_read_block_vram path. Same 512-byte-multiple assumption as
; fat_load_vram.
; =============================================================================
!zone fat_load_vram_pal
fat_load_vram_pal:
        lda #1
        sta fat_track_only
        jsr fat_open
        jsr fat_read_next_sector  ; first sector = palette
        bcc .havepal
        lda #0
        sta fat_track_only
        sec                      ; file too short to hold a palette
        rts
.havepal:
        ; ADDR0 = $1FA00, increment 1, bit16 = 1 (palette is above $10000)
        ldy #$00
        lda #$00
        sta (VERA_ZP),y
        iny
        lda #$FA
        sta (VERA_ZP),y
        iny
        lda #$11                 ; incr nibble 1, addr bit16 = 1
        sta (VERA_ZP),y
        jsr sd_read_block_vram
        bcc .pal_ok
        lda #0
        sta fat_track_only
        sec
        rts
.pal_ok:
        ; ADDR0 = ld_vaddr for the bitmap
        ldy #$00
        lda ld_vaddr+0
        sta (VERA_ZP),y
        iny
        lda ld_vaddr+1
        sta (VERA_ZP),y
        iny
        lda ld_vaddr+2
        sta (VERA_ZP),y
.loop:
        jsr fat_read_next_sector
        bcs .done
        jsr sd_read_block_vram
        bcc .loop
        lda #0
        sta fat_track_only
        sec
        rts
.done:
        lda #0
        sta fat_track_only
        clc
        rts

; =============================================================================
; fat_load_ram: stream the found file into Apple II RAM.
; Input: ZP_PTR = destination pointer (advanced as bytes are written).
; Precondition: fat_find succeeded. Carry set = error.
;
; Uses the fast sd_read_block_ram path. ZP_PTR2 is used as the per-sector write
; target (sd_read_block_ram's interface). It is advanced by 512 bytes per call.
; Same 512-byte-multiple assumption as fat_load_vram.
; =============================================================================
!zone fat_load_ram
fat_load_ram:
        lda ZP_PTR
        sta ram_dest+0
        lda ZP_PTR+1
        sta ram_dest+1
        lda #1
        sta fat_track_only
        jsr fat_open
.loop:
        jsr fat_read_next_sector
        bcs .done
        ; fat_read_next_sector's cluster-chain walk loads FAT sectors through
        ; ZP_PTR2 (cache reads land in fat_buf), so ZP_PTR2 is trashed on every
        ; cluster crossing. Keep the running destination in ram_dest instead, and
        ; re-point ZP_PTR2 at it immediately before each read. sd_read_block_ram
        ; restores ZP_PTR2, but we cannot rely on that across the next
        ; fat_read_next_sector call.
        lda ram_dest+0
        sta ZP_PTR2
        lda ram_dest+1
        sta ZP_PTR2+1
        jsr sd_read_block_ram    ; 512 bytes -> (ZP_PTR2) = ram_dest
        bcc .adv
        lda #0
        sta fat_track_only
        sec
        rts
.adv:
        inc ram_dest+1           ; +256
        inc ram_dest+1           ; +512 (two pages per sector)
        jmp .loop
.done:
        lda ram_dest+0
        sta ZP_PTR               ; publish advanced dest back to ZP_PTR
        lda ram_dest+1
        sta ZP_PTR+1
        lda #0
        sta fat_track_only
        clc
        rts

; =============================================================================
; Data / working storage
; =============================================================================

; SPI / SD command scratch
sd_lba:          !fill 4, 0      ; target block LBA (4-byte LE) for sd_read_block
spi_ctrl_base:   !byte 0        ; shadow of SPI_CTRL non-CS bits (clock/autotx)
sd_arg:          !fill 4, 0      ; command argument, MSB..LSB
sd_crc:          !byte 0
sd_r1:           !byte 0         ; last R1 response
ocr_hi:          !byte 0         ; OCR[31:24] from CMD58
sd_block_addr:   !byte 0         ; 1 = SDHC/SDXC block addressing, 0 = byte
sd_last_err:     !byte 0
init_to:         !word 0         ; ACMD41 timeout counter
cmd_to:          !byte 0         ; sd_cmd response-poll counter (keeps X free)
rb_to:           !word 0         ; data-token timeout counter
rb_ba:           !fill 4, 0      ; byte-address scratch (lba << 9)
sx_xsave:        !byte 0         ; spi_xfer's X save slot
sx_ysave:        !byte 0         ; spi_xfer's Y save slot (see the note there)
spi_timeouts:    !byte 0         ; times BUSY never cleared (saturates at $FF)
spi_fault:       !byte 0         ; $80 = BUSY stuck, polling loops bail out
sd_trace_on:     !byte 0         ; $80 = print sd_read_block progress markers
sdt_x:           !byte 0         ; sd_trace register saves
sdt_y:           !byte 0
sd_fast_clock:   !byte 0         ; 0 = stay at ~390kHz (default, works in every
                                 ; slot), 1 = 12.5MHz (slot 4+ only). See
                                 ; sd_apply_clock for the measurements.
rb_ncap:         !byte 0         ; token bytes captured this read
rb_cap:          !fill RB_CAP_N, 0
probe_left:      !byte 0         ; sd_probe_clock fast reads remaining
vrb_passes:      !byte 0         ; sd_read_block_vram 2-pass counter
rrb_passes:      !byte 0         ; sd_read_block_ram 2-pass counter
ram_dest:        !fill 2, 0      ; fat_load_ram running RAM destination (survives
                                 ; the FAT-chain reads that trash ZP_PTR2)

; FAT32 layout (from fat_mount)
part_lba:        !fill 4, 0
fat_begin_lba:   !fill 4, 0
clus_begin_lba:  !fill 4, 0
root_clus:       !fill 4, 0
secs_per_clus:   !byte 0
fat_cache_lba:   !fill 4, 0      ; LBA currently in fat_buf ($FFFFFFFF = none)

; Streaming reader state
cur_clus:        !fill 4, 0
cur_lba:         !fill 4, 0
sects_left:      !byte 0
need_first:      !byte 0
bytes_left:      !fill 4, 0
this_len:        !word 0
fat_track_only:  !byte 0         ; 1 = fat_read_next_sector skips sd_read_block
                                 ; (caller does its own fast read via sd_lba)

; Scratch
tmp32:           !fill 4, 0
wanted_lba:      !fill 4, 0
mtmp:            !word 0

; File found by fat_find
file_first_clus: !fill 4, 0
file_size:       !fill 4, 0
search_name:     !fill 11, 0

; Caller-set VRAM destination for fat_load_vram (ADDR0_L/M/H)
ld_vaddr:        !fill 3, 0

; 512-byte sector buffers (no alignment needed: sd_read_block bumps the
; pointer's high byte by exactly 256 for the second half)
sd_buf:          !fill 512, 0    ; data / directory / MBR / BPB sector
fat_buf:         !fill 512, 0    ; cached FAT sector

; End of vera_sd.inc ----------------------------------------------------------
