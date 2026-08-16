; sd_diag.asm: staged SD-card bring-up diagnostic (Apple II + VERA)
;
; Client program: requires an init program to have been BRUN first (it reads
; the $0300 magic block to find VERA's slot). Exercises vera_sd.inc one layer
; at a time and prints every result to the Apple II's own 40-col text screen
; via COUT / PRBYTE, so each stage can be verified on real hardware before the
; next is trusted:
;
;   1. sd_init        -> "SD INIT" OK/err, card type (block vs byte address)
;   2. sd_read_block  -> MBR signature bytes at $1FE/$1FF (expect 55 AA)
;   3. fat_mount      -> secs/clus, fat_begin, clus_begin, root_clus
;   4. fat_find       -> first cluster + size of IMAGE.BIN in the root dir
;
; AppleWin cannot emulate VERA, so there SPI reads come back as $FF and every
; stage "fails" cleanly. This program is a real-hardware test.
;
; Ends with JMP $03D0 (never RTS from a BRUN'd program).

!cpu 6502

VERA_ZP     = $0A               ; runtime VERA base = $00/$CN (from magic block)
MAGIC_ADDR  = $0300
MAGIC_B0    = $A2
MAGIC_B1    = $56

COUT        = $FDED
PRBYTE      = $FDDA             ; print A as two hex digits

* = $0800

start:
        jsr $FC58               ; HOME

        lda #<msg_title
        sta ZP_PTR
        lda #>msg_title
        sta ZP_PTR+1
        jsr a2_print

        ; --- locate-or-die: VERA must already be initialized ---
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
        lda MAGIC_ADDR+3        ; VERA base hi ($C1..$C7)
        sta VERA_ZP+1
        lda #$00
        sta VERA_ZP

        ; ================= STAGE 1: sd_init =================
        lda #<msg_init
        sta ZP_PTR
        lda #>msg_init
        sta ZP_PTR+1
        jsr a2_print
        jsr sd_clock_from_magic  ; start from init's verdict. The staged
                                 ; tests below still override it on purpose
        jsr sd_init
        bcc .init_ok
        lda #<msg_fail
        sta ZP_PTR
        lda #>msg_fail
        sta ZP_PTR+1
        jsr a2_print
        lda sd_last_err
        jsr PRBYTE
        jsr pcr
        jmp done                 ; can't continue without a card
.init_ok:
        lda #<msg_ok
        sta ZP_PTR
        lda #>msg_ok
        sta ZP_PTR+1
        jsr a2_print
        lda #<msg_type
        sta ZP_PTR
        lda #>msg_type
        sta ZP_PTR+1
        jsr a2_print
        lda sd_block_addr        ; 01 = SDHC/block, 00 = SDSC/byte
        jsr PRBYTE
        jsr pcr

        ; ================= STAGE 2: raw block read (LBA 0) =================
        ; Tried at both SPI clocks. Bring-up runs at ~390kHz and works. The
        ; switch to 12.5MHz happens between that and this read, which makes it
        ; the prime suspect when init passes and the first read does not.
        lda #<msg_mbr
        sta ZP_PTR
        lda #>msg_mbr
        sta ZP_PTR+1
        jsr a2_print

        lda #<msg_fast
        sta ZP_PTR
        lda #>msg_fast
        sta ZP_PTR+1
        jsr a2_print
        lda #$01
        sta sd_fast_clock
        jsr sd_apply_clock
        jsr try_mbr
        bcc .rd_ok

        lda #<msg_slow
        sta ZP_PTR
        lda #>msg_slow
        sta ZP_PTR+1
        jsr a2_print
        lda #$00                 ; leave it slow for the rest of the run if
        sta sd_fast_clock        ; this is what works
        jsr sd_apply_clock
        jsr try_mbr
        bcc .rd_ok
        jmp stress   ; the stress numbers are the point of this run
.rd_ok:
        ; What is actually at LBA 0: a partition table, or the volume itself?
        ; A superfloppy has no MBR, so the "partition type" byte is really
        ; boot-message text and means nothing.
        jsr fat_is_vbr
        bcc .show_ptype
        lda #<msg_vbr
        sta ZP_PTR
        lda #>msg_vbr
        sta ZP_PTR+1
        jsr a2_print
        jmp .layout_done
.show_ptype:
        lda #<msg_ptype
        sta ZP_PTR
        lda #>msg_ptype
        sta ZP_PTR+1
        jsr a2_print
        lda sd_buf+$1BE+4        ; $0B/$0C = FAT32, $04/$06 = FAT16
        jsr PRBYTE
.layout_done:
        jsr pcr

        ; ================= STAGE 3: fat_mount =================
        lda #<msg_mount
        sta ZP_PTR
        lda #>msg_mount
        sta ZP_PTR+1
        jsr a2_print
        jsr fat_mount
        bcc .mnt_ok
        lda #<msg_fail
        sta ZP_PTR
        lda #>msg_fail
        sta ZP_PTR+1
        jsr a2_print
        lda sd_last_err
        jsr PRBYTE
        jsr pcr
        jmp stress   ; the stress numbers are the point of this run
.mnt_ok:
        lda #<msg_ok
        sta ZP_PTR
        lda #>msg_ok
        sta ZP_PTR+1
        jsr a2_print

        lda #<msg_spc
        sta ZP_PTR
        lda #>msg_spc
        sta ZP_PTR+1
        jsr a2_print
        lda secs_per_clus
        jsr PRBYTE
        jsr pcr

        lda #<msg_fatb
        sta ZP_PTR
        lda #>msg_fatb
        sta ZP_PTR+1
        jsr a2_print
        lda #<fat_begin_lba
        sta ZP_PTR
        lda #>fat_begin_lba
        sta ZP_PTR+1
        jsr phex4
        jsr pcr

        lda #<msg_clusb
        sta ZP_PTR
        lda #>msg_clusb
        sta ZP_PTR+1
        jsr a2_print
        lda #<clus_begin_lba
        sta ZP_PTR
        lda #>clus_begin_lba
        sta ZP_PTR+1
        jsr phex4
        jsr pcr

        lda #<msg_rootc
        sta ZP_PTR
        lda #>msg_rootc
        sta ZP_PTR+1
        jsr a2_print
        lda #<root_clus
        sta ZP_PTR
        lda #>root_clus
        sta ZP_PTR+1
        jsr phex4
        jsr pcr

        ; ============ STAGE 3B: list the root directory ============
        ; "NOT FOUND" alone cannot distinguish an empty card from a broken
        ; directory walk. Listing what IS there separates the two, and it
        ; exercises the same traversal fat_find uses.
        lda #<msg_root
        sta ZP_PTR
        lda #>msg_root
        sta ZP_PTR+1
        jsr a2_print
        jsr list_root
        lda lr_count
        bne .listed
        lda #<msg_empty
        sta ZP_PTR
        lda #>msg_empty
        sta ZP_PTR+1
        jsr a2_print
.listed:

        ; ================= STAGE 4: fat_find IMAGE.BIN =================
        lda #<msg_find
        sta ZP_PTR
        lda #>msg_find
        sta ZP_PTR+1
        jsr a2_print
        lda #<name_image
        sta ZP_PTR
        lda #>name_image
        sta ZP_PTR+1
        jsr fat_find
        bcc .found
        lda #<msg_nofile
        sta ZP_PTR
        lda #>msg_nofile
        sta ZP_PTR+1
        jsr a2_print
        jmp stress   ; the stress numbers are the point of this run
.found:
        lda #<msg_clus
        sta ZP_PTR
        lda #>msg_clus
        sta ZP_PTR+1
        jsr a2_print
        lda #<file_first_clus
        sta ZP_PTR
        lda #>file_first_clus
        sta ZP_PTR+1
        jsr phex4
        jsr pcr

        lda #<msg_size
        sta ZP_PTR
        lda #>msg_size
        sta ZP_PTR+1
        jsr a2_print
        lda #<file_size
        sta ZP_PTR
        lda #>file_size
        sta ZP_PTR+1
        jsr phex4
        jsr pcr

; ================= STAGE 5: read stress =================
; "It is inconsistent" is not something you can act on. Read STRESS_N different
; sectors at each SPI clock and count the failures, so the run reports a rate.
; Uses sd_read_block (the slow, original path) on purpose: fat_find reads
; through it too, so a failure here is below the fast streaming loaders and
; rules them out.
stress:
        lda #$00
        sta sd_trace_on
        lda #<msg_stress
        sta ZP_PTR
        lda #>msg_stress
        sta ZP_PTR+1
        jsr a2_print

        lda #$01                 ; 12.5MHz
        sta sd_fast_clock
        jsr sd_apply_clock
        jsr stress_run
        lda #<msg_sfast
        sta ZP_PTR
        lda #>msg_sfast
        sta ZP_PTR+1
        jsr a2_print
        lda st_err
        jsr PRBYTE
        jsr pcr

        lda #$00                 ; ~390kHz
        sta sd_fast_clock
        jsr sd_apply_clock
        jsr stress_run
        lda #<msg_sslow
        sta ZP_PTR
        lda #>msg_sslow
        sta ZP_PTR+1
        jsr a2_print
        lda st_err
        jsr PRBYTE
        jsr pcr

done:
        lda #<msg_done
        sta ZP_PTR
        lda #>msg_done
        sta ZP_PTR+1
        jsr a2_print
        jsr a2_clear_basic
        jmp $03D0

; =============================================================================
; stress_run: read STRESS_N different sectors at the current clock, counting
; failures in st_err. Different LBAs on purpose: re-reading one sector can be
; answered from the card's own buffer and would under-report. All counters live
; in memory because sd_read_block clobbers A, X and Y.
; =============================================================================
STRESS_N = $40                   ; 64 sectors, printed as hex

!zone stress_run
stress_run:
        lda #$00
        sta st_err
        sta st_lba
        lda #STRESS_N
        sta st_left
.loop:
        lda st_lba               ; LBA 0..STRESS_N-1, top three bytes stay 0
        sta sd_lba+0
        lda #$00
        sta sd_lba+1
        sta sd_lba+2
        sta sd_lba+3
        lda #<sd_buf
        sta ZP_PTR2
        lda #>sd_buf
        sta ZP_PTR2+1
        jsr sd_read_block
        bcc .ok
        inc st_err
.ok:
        inc st_lba
        dec st_left
        bne .loop
        rts

; =============================================================================
; list_root: print the 8.3 names in the root directory (max LR_MAX).
; Same walk as fat_find: follow the root cluster chain, 16 entries per sector,
; skipping deleted ($E5), long-filename ($0F attr) and volume-label entries.
; Sets lr_count. Uses the shared cur_clus / cur_lba / sects_left state, so it
; must not be interleaved with a fat_find.
; =============================================================================
LR_MAX = 12                      ; leave room on a 24-line screen

!zone list_root
list_root:
        lda #$00
        sta lr_count
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
        rts                      ; read error: stop listing
.rdok:
        lda #<sd_buf
        sta ZP_PTR2
        lda #>sd_buf
        sta ZP_PTR2+1
        ldx #16
.entry_loop:
        stx lr_x
        ldy #$00
        lda (ZP_PTR2),y
        bne .not_end
        rts                      ; $00 first byte = end of directory
.not_end:
        cmp #$E5
        beq .next                ; deleted
        ldy #$0B
        lda (ZP_PTR2),y          ; attribute byte
        cmp #$0F
        beq .next                ; long-filename fragment
        and #$08
        bne .next                ; volume label
        ldy #$00
.pn:    sty lr_y
        lda (ZP_PTR2),y
        ora #$80
        jsr COUT
        ldy lr_y
        iny
        cpy #11
        bne .pn
        jsr pcr
        inc lr_count
        lda lr_count
        cmp #LR_MAX
        bcc .next
        rts                      ; screen is full, stop here
.next:
        clc
        lda ZP_PTR2
        adc #32
        sta ZP_PTR2
        bcc .noc
        inc ZP_PTR2+1
.noc:
        ldx lr_x
        dex
        beq .sector_done
        jmp .entry_loop
.sector_done:
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
        jsr fat_next_cluster
        bcc .more
        rts                      ; end of the root chain
.more:
        jmp .clus_loop

; =============================================================================
; try_mbr: one attempt at reading LBA 0, then report it on one line:
;   R1=  CMD17's response byte ($00 = accepted)
;   TO=  spi_xfer BUSY-poll timeouts during the attempt ($00 = SPI healthy)
;   T:   the first bytes clocked in while waiting for the $FE data token
; followed by the MBR signature bytes actually landed in the buffer.
; Returns carry from sd_read_block (clear = the read succeeded).
; =============================================================================
!zone try_mbr
try_mbr:
        lda #$80                 ; markers stream out as sd_read_block runs, so
        sta sd_trace_on          ; a freeze still shows where it stopped
        lda #$00
        sta spi_timeouts         ; per-attempt, not per-run
        sta sd_lba+0
        sta sd_lba+1
        sta sd_lba+2
        sta sd_lba+3
        lda #<sd_buf
        sta ZP_PTR2
        lda #>sd_buf
        sta ZP_PTR2+1
        jsr sd_read_block
        lda #$00                 ; stash carry: the printing below destroys it
        bcc .sv
        lda #$01
.sv:    sta mbr_fail
        lda #$00
        sta sd_trace_on          ; markers off again for the report itself
        jsr pcr

        lda #<msg_r1
        sta ZP_PTR
        lda #>msg_r1
        sta ZP_PTR+1
        jsr a2_print
        lda sd_r1
        jsr PRBYTE

        lda #<msg_to
        sta ZP_PTR
        lda #>msg_to
        sta ZP_PTR+1
        jsr a2_print
        lda spi_timeouts
        jsr PRBYTE

        lda #<msg_tok
        sta ZP_PTR
        lda #>msg_tok
        sta ZP_PTR+1
        jsr a2_print
        ldx #0
.tl:    cpx rb_ncap
        bcs .tdone
        lda rb_cap,x
        stx tmx                  ; PRBYTE/COUT are only trusted with Y
        jsr PRBYTE
        jsr pspace
        ldx tmx
        inx
        bne .tl                  ; always taken (X < RB_CAP_N)
.tdone:
        jsr pcr

        lda #<msg_sig
        sta ZP_PTR
        lda #>msg_sig
        sta ZP_PTR+1
        jsr a2_print
        lda sd_buf+$1FE
        jsr PRBYTE
        jsr pspace
        lda sd_buf+$1FF
        jsr PRBYTE
        jsr pcr

        lda mbr_fail
        lsr                      ; bit0 -> carry
        rts

; =============================================================================
; phex4: print the 4-byte LE value at (ZP_PTR) as 8 hex digits, MSB first.
; Relies on COUT/PRBYTE preserving Y (same assumption a2_print makes).
; =============================================================================
!zone phex4
phex4:
        ldy #3
.pl:
        lda (ZP_PTR),y
        jsr PRBYTE
        dey
        bpl .pl
        rts

!zone pspace
pspace:
        lda #$A0                 ; ' ' | $80
        jmp COUT

!zone pcr
pcr:
        lda #$8D                 ; CR | $80
        jmp COUT

!source "a2vera/vera_sd.inc"
!source "a2vera/vera_common.inc"

; =============================================================================
; Data
; =============================================================================
msg_title:  !text "SD CARD DIAGNOSTIC", 13, 0
msg_nomagic:!text "BRUN AN INIT PROGRAM FIRST.", 13, 0
msg_init:   !text "SD INIT... ", 0
msg_ok:     !text "OK ", 0
msg_fail:   !text "FAIL ERR=", 0
msg_type:   !text "TYPE=", 0
msg_mbr:    !text "MBR READ (WANT SIG 55 AA)", 13, 0
msg_fast:   !text "FAST CLK ", 0
msg_slow:   !text "SLOW CLK ", 0
msg_r1:     !text "R1=", 0
msg_to:     !text " TO=", 0
msg_tok:    !text " T:", 0
msg_sig:    !text "  SIG=", 0
msg_ptype:  !text "PART0 TYPE=", 0
msg_vbr:    !text "NO MBR - FAT32 VBR AT LBA 0", 0
msg_mount:  !text "FAT MOUNT... ", 0
msg_spc:    !text "SEC/CLUS=", 0
msg_fatb:   !text "FAT BEGIN=", 0
msg_clusb:  !text "CLUS BEGIN=", 0
msg_rootc:  !text "ROOT CLUS=", 0
msg_root:   !text "ROOT DIR:", 13, 0
msg_empty:  !text "(EMPTY)", 13, 0
msg_find:   !text "FIND IMAGE.BIN... ", 0
msg_nofile: !text "NOT FOUND", 13, 0
msg_clus:   !text "FIRST CLUS=", 0
msg_size:   !text "SIZE=", 0
msg_done:   !text "DONE.", 13, 0
msg_stress: !text "READ STRESS, 40 SECTORS EACH:", 13, 0
msg_sfast:  !text "  12.5MHZ ERRS=", 0
msg_sslow:  !text "  390KHZ  ERRS=", 0

; 8.3 name, space-padded to 11 bytes: "IMAGE" + 3 spaces + "BIN"
name_image: !text "IMAGE   BIN"

mbr_fail:   !byte 0             ; carry saved across try_mbr's printing
tmx:        !byte 0             ; X save slot around PRBYTE
lr_count:   !byte 0             ; root entries printed by list_root
lr_x:       !byte 0             ; list_root register saves across COUT
lr_y:       !byte 0
st_err:     !byte 0             ; stress_run: failures this pass
st_lba:     !byte 0             ; stress_run: sector counter (LBA 0..STRESS_N-1)
st_left:    !byte 0             ; stress_run: reads remaining
