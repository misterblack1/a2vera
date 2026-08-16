; bach_inv13.asm: Bach Invention No. 13 (BWV 784) on VERA PSG, Apple II port
;
; Ported from the C64 and AGFA 9000PS 68020 versions, which share the PSG
; register layout and the note tables. Plays audio through PSG channels 0/1
; (doubled onto 2/3 an octave down, matching the AGFA original) and shows
; a title banner on the VERA display (font + text mode).
;
; PSG registers live in VRAM at $1F9C0, 16 voices x 4 bytes each:
;   byte0 = freq lo, byte1 = freq hi, byte2 = volume/pan, byte3 = waveform/PW
; $1F9C0 is above $10000, so VERA_ADDR0_H needs address-bit-16 set (bit0=1).
;
; AUDIO_CTRL quirk (preserved verbatim from the AGFA source): writing $4F
; then $0F to AUDIO_CTRL is required to make PSG audible at all on the AGFA
; hardware: "Without this PSG is silent." Ported byte-for-byte.
;
; TIMING: the score is written in ticks at 100 Hz, each duration byte being
; N ticks. The Apple II has no free-running timer, so this port paces ticks
; off VERA VSYNC (60 Hz) with a Bresenham accumulator (TEMPO_NUM/TEMPO_DEN
; and advance_tick). Every VSYNC frame adds TEMPO_NUM to a 16-bit
; accumulator, and each time it reaches TEMPO_DEN it subtracts and advances
; one note-tick. TEMPO_NUM=100 with TEMPO_DEN=60 yields exactly 100 ticks per
; 60 frames, so the composed 100 Hz tempo comes out right on 60 Hz hardware.
; Dial the tempo by changing TEMPO_NUM alone (90 = 10% slower, 110 = 10%
; faster).

!cpu 6502

; --- VERA addressing: slot-agnostic via the init program's magic block ------
; Requires an init program (INIT-VGA, INIT-NTSC or INIT-RGB) to have been BRUN
; first. It autodetects VERA's slot, initializes it (text mode, palette, CP437
; font, Layer 0 tilemap) and publishes the slot at $0300: $0300=$A2,
; $0301=$56, $0303=base hi ($C1..$C7). We read the base and address VERA
; through a runtime zero-page pointer (VERA_ZP) with (ptr),Y, so this plays in
; WHATEVER slot init found. No VERA init + no font here.
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
OFS_ISR     = $07
OFS_AUDIO   = $1B             ; AUDIO_CTRL

; --- SMC: absolute VERA DATA0 store, patched at startup ---------------------
; DATA0 must NEVER be written with `sta (VERA_ZP),Y`. An indexed write does a
; dummy READ of the target first, and reading DATA0 auto-increments ADDR0, so
; every byte advances the pointer twice and lands on the wrong address.
; Writing $11 $22 $33 $44 to VRAM 0 lands as 00 11 00 22 00 33 00 44 with the
; indexed form. Full note in vera_common.inc. This corrupts PSG register
; writes exactly as it corrupts tilemap writes, because the PSG registers
; live in VRAM at $1F9C0 and are reached through DATA0.
; Placeholder low byte = DATA0 offset ($03). High byte $01 is a throwaway that
; forces ACME to emit a 3-byte absolute STA, giving us an operand to patch.
VDATA0 = $0103

; Write a VERA register: (offset, immediate value) via (VERA_ZP),Y
; Safe for every register EXCEPT DATA0/DATA1 (see VDATA0 above).
!macro VSET ofs, val {
        ldy #ofs
        lda #val
        sta (VERA_ZP),y
}

; --- PSG ---------------------------------------------------------------------
PSG_VRAM_LO = <$1F9C0
PSG_VRAM_MI = >$1F9C0
; bit16 of $1F9C0 is set (it's > $10000), folded into ADDR0_H below.

; --- Tempo (Bresenham tick accumulator) --------------------------------------
; Each VSYNC frame adds TEMPO_NUM to tick_acc. When tick_acc >= TEMPO_DEN,
; subtract TEMPO_DEN and advance one note-tick. Net = TEMPO_NUM ticks per
; TEMPO_DEN frames. Music was composed for a 100 Hz tick, VSYNC is 60 Hz, so
; TEMPO_NUM=100/TEMPO_DEN=60 reproduces the composed tempo exactly. Change
; TEMPO_NUM only to scale tempo (keep TEMPO_DEN=60 = VSYNC rate).
TEMPO_NUM = 100
TEMPO_DEN = 60

* = $0800

start:
        jsr $FC58               ; HOME: clear Apple II text screen

        lda #<str_banner
        sta ZP_PTR
        lda #>str_banner
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
        jmp no_magic            ; (long-branch: no_magic is out of bne range)
.magic_ok:
        lda MAGIC_ADDR+3        ; VERA base hi ($C1..$C7)
        sta VERA_ZP+1
        lda #$00
        sta VERA_ZP
        jsr patch_smc           ; MUST precede any DATA0 / PSG write

        ; Init already did reset, composer, text mode, font, tilemap clear.
        ; Re-clear the tilemap (wipes init's banner) and draw ours.
        +VSET OFS_ADDR0_L, $00
        +VSET OFS_ADDR0_M, $00
        +VSET OFS_ADDR0_H, $10
        jsr vera_clear_tilemap

        ; title: row 10 col 24 -> addr $0A30 (10*256+24*2)
        +VSET OFS_ADDR0_L, $30
        +VSET OFS_ADDR0_M, $0A
        +VSET OFS_ADDR0_H, $10
        lda #<vera_msg_title
        sta ZP_PTR
        lda #>vera_msg_title
        sta ZP_PTR+1
        jsr vera_puts_white
        ; "PLAYING ON VERA PSG": row 12 col 30 -> $0C3C
        +VSET OFS_ADDR0_L, $3C
        +VSET OFS_ADDR0_M, $0C
        +VSET OFS_ADDR0_H, $10
        lda #<vera_msg_playing
        sta ZP_PTR
        lda #>vera_msg_playing
        sta ZP_PTR+1
        jsr vera_puts_white
        ; "PRESS ANY KEY TO STOP": row 13 col 29 -> $0D3A
        +VSET OFS_ADDR0_L, $3A
        +VSET OFS_ADDR0_M, $0D
        +VSET OFS_ADDR0_H, $10
        lda #<vera_msg_stop
        sta ZP_PTR
        lda #>vera_msg_stop
        sta ZP_PTR+1
        jsr vera_puts_white

        ; Enable VERA master audio output. AGFA source: "$4F = FIFO reset +
        ; master vol 15. Without this PSG is silent." Preserved verbatim.
        +VSET OFS_CTRL,  $00
        +VSET OFS_AUDIO, $4F
        +VSET OFS_AUDIO, $0F

        ; Init all 4 channels: ch 0,1 = pulse 50%, ch 2,3 = sawtooth
        ldx #$00
        jsr psg_channel_init
        ldx #$01
        jsr psg_channel_init
        ldx #$02
        jsr psg_channel_init
        ldx #$03
        jsr psg_channel_init

        lda #<str_playing
        sta ZP_PTR
        lda #>str_playing
        sta ZP_PTR+1
        jsr a2_print

        ; --- "NOW PLAYING" indicator on VERA screen (visible during playback) ---
        +VSET OFS_ADDR0_L, $3A  ; row 15 col 29 -> addr $0F3A
        +VSET OFS_ADDR0_M, $0F
        +VSET OFS_ADDR0_H, $10
        lda #<vera_msg_now_playing
        sta ZP_PTR
        lda #>vera_msg_now_playing
        sta ZP_PTR+1
        jsr vera_puts_white

        ; Clear any stale VSYNC flag before starting playback, so the first
        ; wait_vsync blocks a full frame (not just returns immediately).
        +VSET OFS_ISR, $01

        ; --- main playback loop --------------------------------------------
        ; ZP_PTR walks voice1_table, ZP_PTR2 walks voice2_table. Both are
        ; project zero page (vera_common.inc) since indirect (ZP),Y
        ; addressing requires a zero page pointer.
        lda #<voice1_table
        sta ZP_PTR
        lda #>voice1_table
        sta ZP_PTR+1
        lda #<voice2_table
        sta ZP_PTR2
        lda #>voice2_table
        sta ZP_PTR2+1
        lda #$00
        sta v1_remain           ; 0 ticks remaining -> advance immediately
        sta v2_remain
        sta v1_ended            ; neither voice at terminator yet
        sta v2_ended
        sta tick_acc            ; clear 16-bit Bresenham accumulator
        sta tick_acc+1

!zone main_loop
main_loop:
        ; Keypress check (Apple II KBD register, no SEI needed)
        jsr a2_keypressed
        beq .no_key             ; Z=1 means no key -> continue
        jmp abort_play          ; key pressed -> exit (too far for branch)
.no_key:

        ; Voice 1 advance? (skip entirely once it hit its terminator --
        ; otherwise the pointer would walk past the end reading garbage.)
        lda v1_ended
        bne .v1_done
        lda v1_remain
        bne .v1_alive
        ldy #$00
        lda (ZP_PTR),y          ; freq hi
        sta v1_freq_hi
        iny
        lda (ZP_PTR),y          ; freq lo
        sta v1_freq_lo
        iny
        iny                     ; skip unused byte
        lda (ZP_PTR),y          ; duration
        sta v1_remain
        ; advance pointer by 4
        lda ZP_PTR
        clc
        adc #4
        sta ZP_PTR
        bcc .v1_noof
        inc ZP_PTR+1
.v1_noof:
        ; sound it on both pulse (ch0) and octave-down saw (ch2). For the
        ; terminator note freq=$0000, psg_set_freq takes the mute path, so
        ; the voice goes silent, which is correct.
        ldx #$00
        lda v1_freq_hi
        ldy v1_freq_lo
        jsr psg_set_freq
        ldx #$02
        lda v1_freq_hi
        ldy v1_freq_lo
        jsr psg_set_freq
        ; duration 0 -> this was the terminator: latch voice-ended so we
        ; never reload from this pointer again.
        lda v1_remain
        bne .v1_alive
        inc v1_ended
.v1_alive:
.v1_done:

        ; Voice 2 advance? (same ended-flag guard as voice 1)
        lda v2_ended
        bne .v2_done
        lda v2_remain
        bne .v2_alive
        ldy #$00
        lda (ZP_PTR2),y         ; freq hi
        sta v2_freq_hi
        iny
        lda (ZP_PTR2),y         ; freq lo
        sta v2_freq_lo
        iny
        iny                     ; skip unused byte
        lda (ZP_PTR2),y         ; duration
        sta v2_remain
        lda ZP_PTR2
        clc
        adc #4
        sta ZP_PTR2
        bcc .v2_noof
        inc ZP_PTR2+1
.v2_noof:
        ldx #$01
        lda v2_freq_hi
        ldy v2_freq_lo
        jsr psg_set_freq
        ldx #$03
        lda v2_freq_hi
        ldy v2_freq_lo
        jsr psg_set_freq
        lda v2_remain
        bne .v2_alive
        inc v2_ended
.v2_alive:
.v2_done:

        ; Both voices hit their terminator -> done. (Using ended flags rather
        ; than remain==0 means a voice that ended early can't drift into the
        ; other's tail reading garbage, which was the overrun bug.)
        lda v1_ended
        beq .wait_tick
        lda v2_ended
        bne play_done

.wait_tick:
        ; Wait for VERA VSYNC (one video frame, 60 Hz).
        ; Replaces the C64's CIA #1 Timer B underflow poll.
        jsr wait_vsync

        ; Bresenham tempo accumulator: advance note-ticks at a fractional
        ; rate per frame so the composed 100 Hz tempo is reproduced on 60 Hz
        ; VSYNC. Adds TEMPO_NUM per frame. While tick_acc >= TEMPO_DEN,
        ; subtract TEMPO_DEN and advance one tick (may advance 0, 1, or 2+).
        clc
        lda tick_acc
        adc #<TEMPO_NUM
        sta tick_acc
        lda tick_acc+1
        adc #>TEMPO_NUM
        sta tick_acc+1
.tick_loop:
        sec
        lda tick_acc
        sbc #<TEMPO_DEN
        tay                    ; save low byte of (acc - DEN)
        lda tick_acc+1
        sbc #>TEMPO_DEN
        bcc .ticks_done        ; borrow -> acc < DEN, no more ticks this frame
        sta tick_acc+1
        sty tick_acc
        jsr advance_tick
        jmp .tick_loop
.ticks_done:
        jmp main_loop

abort_play:
        jsr psg_mute_all
        lda #<str_stopped
        sta ZP_PTR
        lda #>str_stopped
        sta ZP_PTR+1
        jsr a2_print
        jsr a2_clear_basic
        jmp $03D0               ; return to DOS

play_done:
        jsr psg_mute_all
        lda #<str_done
        sta ZP_PTR
        lda #>str_done
        sta ZP_PTR+1
        jsr a2_print
        jsr a2_clear_basic
        jmp $03D0               ; return to DOS

no_magic:
        lda #<str_nomagic
        sta ZP_PTR
        lda #>str_nomagic
        sta ZP_PTR+1
        jsr a2_print
        jsr a2_clear_basic
        jmp $03D0               ; return to DOS

; =============================================================================
; WAIT_VSYNC: poll VERA_ISR bit 0 (VSYNC) for one video frame tick.
; Clears the flag after detecting it. 60 Hz = ~16.7ms per tick.
; Replaces the C64's CIA #1 Timer B underflow poll (~100 Hz).
; =============================================================================
!zone wait_vsync
wait_vsync:
        ldy #OFS_ISR
.wv_loop:
        lda (VERA_ZP),y
        and #$01
        beq .wv_loop
        lda #$01
        sta (VERA_ZP),y         ; clear VSYNC flag by writing 1 to bit 0
        rts

; =============================================================================
; ADVANCE_TICK: decrement both voices' remain counters (guarded). Called
; once per Bresenham tick. A voice at remain=0 (waiting on reload or ended)
; is left alone. This is the single point that consumes note duration.
; =============================================================================
!zone advance_tick
advance_tick:
        lda v1_remain
        beq .at_s1
        dec v1_remain
.at_s1:
        lda v2_remain
        beq .at_s2
        dec v2_remain
.at_s2:
        rts

; =============================================================================
; PSG_MUTE_ALL: set freq=0 on channels 0-3 (matches AGFA done: path)
; =============================================================================
!zone psg_mute_all
psg_mute_all:
        ldx #$00
.loop:
        lda #$00
        ldy #$00
        jsr psg_set_freq
        inx
        cpx #$04
        bne .loop
        rts

; =============================================================================
; PSG_CHANNEL_INIT (X=channel 0-3): ch 0,1 pulse 50%, ch 2,3 sawtooth,
; freq=0, vol/pan=0 (silent until psg_set_freq turns it on).
; Address = $1F9C0 + channel*4. $1F9C0 already has addr-bit16 set, and
; channel*4 (max 12) never carries into bit 16, so ADDR0_H is always $11.
; =============================================================================
!zone psg_channel_init
psg_channel_init:
        txa
        asl                     ; channel*4 low byte. Channel 0-3, so no
        asl                     ; carry out of the low byte is possible
        clc
        adc #PSG_VRAM_LO
        ldy #OFS_ADDR0_L
        sta (VERA_ZP),y
        lda #PSG_VRAM_MI
        ldy #OFS_ADDR0_M
        sta (VERA_ZP),y
        lda #$11
        ldy #OFS_ADDR0_H
        sta (VERA_ZP),y

        lda #$00
        jsr vdata_w             ; freq lo = 0
        lda #$00
        jsr vdata_w             ; freq hi = 0
        lda #$00
        jsr vdata_w             ; vol/pan = 0 (silent)

        txa
        and #$02
        bne .saw_init
        lda #$20                ; pulse, 50% duty
        jmp vdata_w             ; tail call (vdata_w rts's for us)
.saw_init:
        lda #$7F                ; sawtooth
        jmp vdata_w

; =============================================================================
; PSG_SET_FREQ (X=channel 0-3, A=freq hi, Y=freq lo): freq=0 mutes.
; ch 0,2 = left pan, ch 1,3 = right pan. ch 0,1 = pulse, ch 2,3 = sawtooth
; (also halved an octave, matching the AGFA bit-1 test on channel number).
; =============================================================================
!zone psg_set_freq
psg_set_freq:
        sta freq_hi
        sty freq_lo

        txa
        and #$02
        beq .no_octave
        ; halve the 16-bit frequency (octave down) via one right shift
        lsr freq_hi
        ror freq_lo
.no_octave:

        txa
        asl
        asl
        clc
        adc #PSG_VRAM_LO
        ldy #OFS_ADDR0_L
        sta (VERA_ZP),y
        lda #PSG_VRAM_MI
        ldy #OFS_ADDR0_M
        sta (VERA_ZP),y
        lda #$11
        ldy #OFS_ADDR0_H
        sta (VERA_ZP),y

        lda freq_lo
        jsr vdata_w
        lda freq_hi
        jsr vdata_w

        lda freq_lo
        ora freq_hi
        bne .play
        ; mute
        txa
        and #$01
        bne .right_mute
        lda #$40
        jsr vdata_w
        jmp .waveform
.right_mute:
        lda #$80
        jsr vdata_w
        jmp .waveform
.play:
        txa
        and #$01
        bne .right_play
        lda #$7F
        jsr vdata_w
        jmp .waveform
.right_play:
        lda #$BF
        jsr vdata_w
.waveform:
        txa
        and #$02
        bne .saw_pw
        lda #$20
        jmp vdata_w             ; tail call (vdata_w rts's for us)
.saw_pw:
        lda #$7F
        jmp vdata_w

; =============================================================================
; VERA_CLEAR_TILEMAP: fill 30 rows x 256 bytes with space ($20) / white
; attr ($01) pairs. VERA_ADDR0_* must be set to $00000 stride+1 before calling.
; =============================================================================
!zone vera_clear_tilemap
vera_clear_tilemap:
        ldx #30                  ; 30 visible rows
.page:
        lda #128                 ; 128 char+attr pairs per row
        sta clr_inner
.pair:  lda #$20                 ; space character (CP437)
vct_st1: sta VDATA0              ; DATA0, absolute (patched by patch_smc)
        lda #$01                 ; white on black attribute
vct_st2: sta VDATA0              ; DATA0, absolute (patched by patch_smc)
        dec clr_inner
        bne .pair
        dex
        bne .page
        rts

; =============================================================================
; VERA_PUTS_WHITE: write NUL-terminated string at ZP_PTR to current
; VERA_ADDR0 position as char+$01 (white on black) pairs.
; =============================================================================
!zone vera_puts_white
vera_puts_white:
        ldx #$00                 ; X = string index (Y is needed for VERA offset)
.loop:  txa
        tay
        lda (ZP_PTR),y           ; string[X]
        beq .done
vpw_st1: sta VDATA0              ; character byte to DATA0, absolute (patched)
        lda #$01                 ; white on black attribute
vpw_st2: sta VDATA0              ; DATA0, absolute (patched by patch_smc)
        inx
        bne .loop                ; all banner strings fit in 256 chars
.done:  rts

; =============================================================================
; VDATA_W: write A to DATA0 via an absolute store. Preserves X and Y.
; Used by the PSG routines, where the 12-cycle JSR/RTS overhead is irrelevant
; (a handful of register writes per frame) and the clarity is worth more.
; The hot loops (vera_clear_tilemap, vera_puts_white) inline their own
; patched stores instead.
; =============================================================================
!zone vdata_w
vdata_w:
vdw_st: sta VDATA0              ; DATA0, absolute (patched by patch_smc)
        rts

; =============================================================================
; PATCH_SMC: point every absolute DATA0 store at the detected slot.
; Call once, after VERA_ZP is loaded, before any DATA0 write. Only the high
; operand byte varies. The low byte ($03 = DATA0) is fixed at assembly time.
; =============================================================================
!zone patch_smc
patch_smc:
        lda VERA_ZP+1            ; $C1..$C7
        sta vdw_st+2             ; vdata_w (all PSG writes)
        sta vct_st1+2            ; vera_clear_tilemap (char)
        sta vct_st2+2            ; vera_clear_tilemap (attr)
        sta vpw_st1+2            ; vera_puts_white (char)
        sta vpw_st2+2            ; vera_puts_white (attr)
        rts

!source "a2vera/vera_common.inc"

; =============================================================================
; Data
; =============================================================================

; Printed on the Apple II's OWN screen via COUT. Messages kept <= 40 chars.
str_banner:
        !text "BACH INV. 13 (BWV 784) ON VERA PSG."
        !byte 13, 0

str_playing:
        !text "PLAYING ON VERA PSG."
        !byte 13
        !text "PRESS ANY KEY TO STOP."
        !byte 13, 0

str_stopped:
        !byte 13
        !text "STOPPED."
        !byte 13, 0

str_done:
        !byte 13
        !text "PLAYBACK COMPLETE."
        !byte 13, 0

str_nomagic:
        !text "VERA MODULE MUST BE INITIALIZED"
        !byte 13
        !text "BEFORE RUNNING THIS PROGRAM."
        !byte 13, 0

; --- voice playback state ---------------------------------------------------
v1_remain:     !byte 0        ; frames left on voice 1's current note
v2_remain:     !byte 0        ; frames left on voice 2's current note
v1_freq_hi:    !byte 0
v1_freq_lo:    !byte 0
v2_freq_hi:    !byte 0
v2_freq_lo:    !byte 0
v1_ended:      !byte 0        ; 1 = voice 1 reached its terminator
v2_ended:      !byte 0        ; 1 = voice 2 reached its terminator
freq_hi:       !byte 0        ; psg_set_freq scratch
freq_lo:       !byte 0
tick_acc:      !byte 0, 0     ; 16-bit Bresenham tempo accumulator
clr_inner:     !byte 0        ; vera_clear_tilemap inner pair counter

; --- VERA banner strings (written to tilemap during startup) ------------------
vera_msg_title:
        !text "BACH INVENTION NO. 13 (BWV 784)", 0
vera_msg_playing:
        !text "PLAYING ON VERA PSG", 0
vera_msg_stop:
        !text "PRESS ANY KEY TO STOP", 0
vera_msg_now_playing:
        !text ">>>  NOW PLAYING  <<<", 0

; (No font here. The init program already put the CP437 font in VRAM $0F000.)

; --- voice note tables --------------------------------------------------------
; 4 bytes/note: freq hi, freq lo, unused, duration (in 100 Hz ticks).
; Duration values are copied verbatim from the AGFA/C64 source. The
; Bresenham accumulator (TEMPO_NUM/TEMPO_DEN) paces them at the composed
; 100 Hz rate on the Apple II's 60 Hz VSYNC, so no per-note scaling is done.
; 4-byte terminator: freq=$0000, duration=$00 (handled by v1_ended/v2_ended).
voice1_table:
        !byte $00,$00,$00,$0f,$03,$75,$00,$0f,$04,$9d,$00,$0f,$05,$7d,$00,$0f
        !byte $05,$2e,$00,$0f,$03,$75,$00,$0f,$05,$2e,$00,$0f,$06,$29,$00,$0f
        !byte $05,$7d,$00,$1e,$06,$ea,$00,$1e,$04,$5b,$00,$1e,$06,$ea,$00,$1e
        !byte $04,$9d,$00,$0f,$03,$75,$00,$0f,$04,$9d,$00,$0f,$05,$7d,$00,$0f
        !byte $05,$2e,$00,$0f,$03,$75,$00,$0f,$05,$2e,$00,$0f,$06,$29,$00,$0f
        !byte $05,$7d,$00,$1e,$04,$9d,$00,$1e,$00,$00,$00,$3c,$00,$00,$00,$0f
        !byte $06,$ea,$00,$0f,$05,$7d,$00,$0f,$06,$ea,$00,$0f,$04,$9d,$00,$0f
        !byte $05,$7d,$00,$0f,$03,$75,$00,$0f,$04,$1c,$00,$0f,$03,$a9,$00,$1e
        !byte $04,$9d,$00,$1e,$06,$29,$00,$1e,$07,$53,$00,$2d,$06,$29,$00,$0f
        !byte $05,$2e,$00,$0f,$06,$29,$00,$0f,$04,$1c,$00,$0f,$05,$2e,$00,$0f
        !byte $03,$14,$00,$0f,$03,$a9,$00,$0f,$03,$75,$00,$1e,$04,$1c,$00,$1e
        !byte $05,$7d,$00,$1e,$06,$ea,$00,$2d,$05,$7d,$00,$0f,$04,$9d,$00,$0f
        !byte $05,$7d,$00,$0f,$03,$a9,$00,$1e,$06,$29,$00,$2d,$05,$2e,$00,$0f
        !byte $04,$1c,$00,$0f,$05,$2e,$00,$0f,$03,$75,$00,$1e,$05,$7d,$00,$2d
        !byte $04,$9d,$00,$0f,$03,$a9,$00,$0f,$04,$9d,$00,$0f,$03,$14,$00,$1e
        !byte $05,$2e,$00,$1e,$05,$7d,$00,$1e,$00,$00,$00,$1e,$00,$00,$00,$3c
        !byte $00,$00,$00,$0f,$04,$1c,$00,$0f,$05,$7d,$00,$0f,$06,$ea,$00,$0f
        !byte $06,$29,$00,$0f,$04,$1c,$00,$0f,$06,$29,$00,$0f,$07,$53,$00,$0f
        !byte $06,$ea,$00,$1e,$08,$39,$00,$1e,$05,$2e,$00,$1e,$08,$39,$00,$1e
        !byte $05,$7d,$00,$0f,$04,$1c,$00,$0f,$05,$7d,$00,$0f,$06,$ea,$00,$0f
        !byte $06,$29,$00,$0f,$04,$1c,$00,$0f,$06,$29,$00,$0f,$07,$53,$00,$0f
        !byte $06,$ea,$00,$1e,$05,$7d,$00,$1e,$08,$39,$00,$1e,$06,$ea,$00,$1e
        !byte $0a,$f9,$00,$0f,$09,$3a,$00,$0f,$06,$ea,$00,$0f,$09,$3a,$00,$0f
        !byte $05,$7d,$00,$0f,$06,$ea,$00,$0f,$04,$9d,$00,$0f,$05,$7d,$00,$0f
        !byte $06,$29,$00,$1e,$07,$c2,$00,$1e,$09,$3a,$00,$1e,$0a,$f9,$00,$1e
        !byte $0a,$5c,$00,$0f,$08,$39,$00,$0f,$06,$29,$00,$0f,$08,$39,$00,$0f
        !byte $05,$2e,$00,$0f,$06,$29,$00,$0f,$04,$1c,$00,$0f,$05,$2e,$00,$0f
        !byte $05,$7d,$00,$1e,$06,$ea,$00,$1e,$08,$39,$00,$1e,$0a,$5c,$00,$1e
        !byte $09,$3a,$00,$0f,$07,$c2,$00,$0f,$06,$86,$00,$0f,$07,$c2,$00,$0f
        !byte $05,$2e,$00,$0f,$06,$86,$00,$0f,$03,$e1,$00,$0f,$04,$9d,$00,$0f
        !byte $04,$1c,$00,$1e,$08,$39,$00,$2d,$06,$ea,$00,$0f,$05,$7d,$00,$0f
        !byte $06,$ea,$00,$0f,$04,$9d,$00,$1e,$07,$c2,$00,$2d,$06,$29,$00,$0f
        !byte $05,$2e,$00,$0f,$06,$29,$00,$0f,$04,$1c,$00,$1e,$06,$ea,$00,$2d
        !byte $05,$7d,$00,$0f,$04,$9d,$00,$0f,$05,$7d,$00,$0f,$03,$e1,$00,$0f
        !byte $08,$39,$00,$0f,$07,$c2,$00,$0f,$06,$ea,$00,$0f,$06,$86,$00,$0f
        !byte $07,$c2,$00,$0f,$05,$2e,$00,$0f,$06,$86,$00,$0f,$06,$ea,$00,$1e
        !byte $00,$00,$00,$1e,$00,$00,$00,$3c,$00,$00,$00,$0f,$08,$39,$00,$0f
        !byte $09,$c7,$00,$0f,$08,$39,$00,$0f,$06,$ea,$00,$0f,$08,$39,$00,$0f
        !byte $05,$d0,$00,$0f,$06,$ea,$00,$0f,$08,$39,$00,$0f,$06,$ea,$00,$0f
        !byte $05,$d0,$00,$0f,$06,$ea,$00,$0f,$04,$9d,$00,$0f,$00,$00,$00,$0f
        !byte $00,$00,$00,$1e,$00,$00,$00,$0f,$07,$53,$00,$0f,$09,$3a,$00,$0f
        !byte $07,$53,$00,$0f,$06,$29,$00,$0f,$07,$53,$00,$0f,$05,$2e,$00,$0f
        !byte $06,$29,$00,$0f,$07,$53,$00,$0f,$06,$29,$00,$0f,$05,$2e,$00,$0f
        !byte $06,$29,$00,$0f,$04,$1c,$00,$0f,$00,$00,$00,$0f,$00,$00,$00,$1e
        !byte $00,$00,$00,$0f,$06,$ea,$00,$0f,$08,$39,$00,$0f,$06,$ea,$00,$0f
        !byte $05,$7d,$00,$0f,$06,$ea,$00,$0f,$04,$9d,$00,$0f,$05,$7d,$00,$0f
        !byte $06,$86,$00,$0f,$05,$7d,$00,$0f,$04,$9d,$00,$0f,$05,$7d,$00,$0f
        !byte $03,$e1,$00,$0f,$00,$00,$00,$0f,$00,$00,$00,$1e,$00,$00,$00,$0f
        !byte $06,$29,$00,$0f,$07,$53,$00,$0f,$06,$29,$00,$0f,$05,$2e,$00,$0f
        !byte $06,$29,$00,$0f,$04,$5b,$00,$0f,$05,$2e,$00,$0f,$06,$29,$00,$0f
        !byte $05,$2e,$00,$0f,$04,$5b,$00,$0f,$05,$2e,$00,$0f,$03,$75,$00,$0f
        !byte $00,$00,$00,$0f,$00,$00,$00,$1e,$00,$00,$00,$0f,$03,$75,$00,$0f
        !byte $04,$9d,$00,$0f,$05,$7d,$00,$0f,$05,$2e,$00,$0f,$03,$75,$00,$0f
        !byte $05,$2e,$00,$0f,$06,$29,$00,$0f,$05,$7d,$00,$1e,$04,$9d,$00,$1e
        !byte $04,$5b,$00,$1e,$03,$75,$00,$1e,$04,$9d,$00,$0f,$05,$7d,$00,$0f
        !byte $06,$ea,$00,$0f,$05,$7d,$00,$0f,$04,$9d,$00,$0f,$05,$7d,$00,$0f
        !byte $03,$e1,$00,$0f,$04,$9d,$00,$0f,$05,$7d,$00,$0f,$04,$9d,$00,$0f
        !byte $03,$e1,$00,$0f,$04,$9d,$00,$0f,$03,$43,$00,$0f,$05,$7d,$00,$0f
        !byte $05,$2e,$00,$0f,$04,$9d,$00,$0f,$04,$5b,$00,$0f,$05,$2e,$00,$0f
        !byte $06,$29,$00,$0f,$05,$2e,$00,$0f,$04,$5b,$00,$0f,$05,$2e,$00,$0f
        !byte $03,$14,$00,$0f,$03,$a9,$00,$0f,$04,$5b,$00,$0f,$03,$a9,$00,$0f
        !byte $03,$14,$00,$0f,$03,$a9,$00,$0f,$02,$97,$00,$0f,$03,$a9,$00,$0f
        !byte $03,$75,$00,$0f,$03,$14,$00,$0f,$02,$be,$00,$0f,$03,$75,$00,$0f
        !byte $04,$9d,$00,$0f,$03,$75,$00,$0f,$02,$be,$00,$0f,$03,$75,$00,$0f
        !byte $02,$4f,$00,$0f,$02,$be,$00,$0f,$03,$43,$00,$0f,$02,$be,$00,$0f
        !byte $02,$4f,$00,$0f,$02,$be,$00,$0f,$01,$f1,$00,$0f,$02,$be,$00,$0f
        !byte $02,$97,$00,$0f,$02,$4f,$00,$0f,$02,$2d,$00,$1e,$05,$2e,$00,$1e
        !byte $04,$5b,$00,$1e,$03,$75,$00,$1e,$00,$00,$00,$0f,$03,$75,$00,$0f
        !byte $04,$9d,$00,$0f,$05,$7d,$00,$0f,$05,$2e,$00,$0f,$03,$75,$00,$0f
        !byte $05,$2e,$00,$0f,$06,$29,$00,$0f,$05,$7d,$00,$0f,$04,$9d,$00,$0f
        !byte $05,$7d,$00,$0f,$06,$ea,$00,$0f,$06,$29,$00,$0f,$05,$2e,$00,$0f
        !byte $06,$29,$00,$0f,$07,$53,$00,$0f,$06,$ea,$00,$0f,$05,$7d,$00,$0f
        !byte $06,$ea,$00,$0f,$08,$39,$00,$0f,$07,$53,$00,$0f,$06,$ea,$00,$0f
        !byte $06,$29,$00,$0f,$05,$7d,$00,$0f,$05,$2e,$00,$0f,$05,$7d,$00,$0f
        !byte $06,$29,$00,$0f,$06,$ea,$00,$0f,$07,$53,$00,$0f,$06,$29,$00,$0f
        !byte $08,$b6,$00,$0f,$06,$29,$00,$0f,$0a,$5c,$00,$0f,$06,$29,$00,$0f
        !byte $05,$7d,$00,$0f,$09,$3a,$00,$0f,$07,$53,$00,$0f,$06,$29,$00,$0f
        !byte $05,$2e,$00,$0f,$06,$29,$00,$0f,$04,$5b,$00,$0f,$05,$2e,$00,$0f
        !byte $05,$7d,$00,$0f,$04,$9d,$00,$0f,$03,$75,$00,$0f,$04,$9d,$00,$0f
        !byte $05,$2e,$00,$0f,$04,$5b,$00,$0f,$04,$9d,$00,$0f,$03,$75,$00,$0f
        !byte $02,$be,$00,$0f,$03,$75,$00,$0f,$02,$4f,$00,$3c,$00,$00,$00,$00

voice2_table:
        !byte $01,$27,$00,$1e,$02,$4f,$00,$3c,$02,$2d,$00,$1e,$02,$4f,$00,$0f
        !byte $01,$ba,$00,$0f,$02,$4f,$00,$0f,$02,$be,$00,$0f,$02,$97,$00,$0f
        !byte $01,$ba,$00,$0f,$02,$97,$00,$0f,$03,$14,$00,$0f,$02,$be,$00,$1e
        !byte $02,$4f,$00,$1e,$02,$2d,$00,$1e,$01,$ba,$00,$1e,$02,$4f,$00,$0f
        !byte $01,$ba,$00,$0f,$02,$4f,$00,$0f,$02,$be,$00,$0f,$02,$97,$00,$0f
        !byte $01,$ba,$00,$0f,$02,$97,$00,$0f,$03,$14,$00,$0f,$02,$be,$00,$1e
        !byte $02,$4f,$00,$1e,$02,$be,$00,$1e,$02,$4f,$00,$1e,$03,$14,$00,$0f
        !byte $02,$4f,$00,$0f,$01,$d5,$00,$0f,$02,$4f,$00,$0f,$01,$8a,$00,$0f
        !byte $01,$d5,$00,$0f,$01,$27,$00,$0f,$01,$5f,$00,$0f,$01,$4b,$00,$1e
        !byte $01,$8a,$00,$1e,$02,$0e,$00,$1e,$02,$97,$00,$2d,$02,$0e,$00,$0f
        !byte $01,$ba,$00,$0f,$02,$0e,$00,$0f,$01,$5f,$00,$0f,$01,$ba,$00,$0f
        !byte $01,$07,$00,$0f,$01,$4b,$00,$0f,$01,$27,$00,$1e,$01,$5f,$00,$1e
        !byte $01,$8a,$00,$0f,$01,$d5,$00,$0f,$01,$4b,$00,$0f,$01,$8a,$00,$0f
        !byte $01,$07,$00,$1e,$01,$4b,$00,$1e,$01,$5f,$00,$0f,$01,$ba,$00,$0f
        !byte $01,$27,$00,$0f,$01,$5f,$00,$0f,$00,$ea,$00,$1e,$00,$c5,$00,$1e
        !byte $01,$07,$00,$0f,$02,$0e,$00,$0f,$01,$d5,$00,$0f,$02,$0e,$00,$0f
        !byte $01,$5f,$00,$0f,$02,$0e,$00,$0f,$02,$be,$00,$0f,$03,$75,$00,$0f
        !byte $03,$14,$00,$0f,$02,$0e,$00,$0f,$03,$14,$00,$0f,$03,$a9,$00,$0f
        !byte $03,$75,$00,$1e,$02,$be,$00,$1e,$02,$97,$00,$1e,$02,$0e,$00,$1e
        !byte $02,$be,$00,$0f,$02,$0e,$00,$0f,$02,$be,$00,$0f,$03,$75,$00,$0f
        !byte $03,$14,$00,$0f,$02,$0e,$00,$0f,$03,$14,$00,$0f,$03,$a9,$00,$0f
        !byte $03,$75,$00,$1e,$02,$be,$00,$1e,$00,$00,$00,$3c,$00,$00,$00,$0f
        !byte $04,$1c,$00,$0f,$03,$75,$00,$0f,$04,$1c,$00,$0f,$02,$be,$00,$0f
        !byte $03,$75,$00,$0f,$02,$0e,$00,$0f,$02,$97,$00,$0f,$02,$4f,$00,$1e
        !byte $02,$be,$00,$1e,$03,$75,$00,$1e,$04,$1c,$00,$1e,$03,$e1,$00,$0f
        !byte $04,$9d,$00,$0f,$03,$14,$00,$0f,$03,$e1,$00,$0f,$02,$4f,$00,$0f
        !byte $03,$14,$00,$0f,$01,$f1,$00,$0f,$02,$4f,$00,$0f,$02,$0e,$00,$1e
        !byte $02,$97,$00,$1e,$03,$14,$00,$1e,$03,$e1,$00,$1e,$03,$75,$00,$0f
        !byte $04,$1c,$00,$0f,$02,$be,$00,$0f,$03,$75,$00,$0f,$02,$0e,$00,$0f
        !byte $02,$be,$00,$0f,$01,$ba,$00,$0f,$02,$0e,$00,$0f,$01,$f1,$00,$1e
        !byte $02,$4f,$00,$1e,$02,$97,$00,$1e,$03,$43,$00,$1e,$00,$00,$00,$0f
        !byte $03,$75,$00,$0f,$02,$be,$00,$0f,$03,$75,$00,$0f,$02,$4f,$00,$0f
        !byte $02,$be,$00,$0f,$03,$75,$00,$0f,$04,$1c,$00,$0f,$03,$e1,$00,$0f
        !byte $03,$14,$00,$0f,$02,$97,$00,$0f,$03,$14,$00,$0f,$02,$0e,$00,$0f
        !byte $02,$97,$00,$0f,$03,$14,$00,$0f,$03,$e1,$00,$0f,$03,$75,$00,$0f
        !byte $02,$be,$00,$0f,$02,$4f,$00,$0f,$02,$be,$00,$0f,$01,$f1,$00,$0f
        !byte $02,$4f,$00,$0f,$02,$be,$00,$2d,$02,$97,$00,$0f,$02,$be,$00,$0f
        !byte $02,$4f,$00,$0f,$02,$97,$00,$1e,$01,$4b,$00,$1e,$01,$ba,$00,$0f
        !byte $03,$75,$00,$0f,$02,$97,$00,$0f,$02,$0e,$00,$0f,$01,$ba,$00,$0f
        !byte $01,$4b,$00,$0f,$01,$07,$00,$0f,$01,$4b,$00,$0f,$00,$dd,$00,$1e
        !byte $01,$ba,$00,$1e,$02,$0e,$00,$1e,$02,$72,$00,$1e,$01,$74,$00,$1e
        !byte $00,$00,$00,$1e,$00,$00,$00,$0f,$04,$1c,$00,$0f,$03,$a9,$00,$0f
        !byte $03,$75,$00,$0f,$03,$14,$00,$1e,$01,$8a,$00,$1e,$01,$d5,$00,$1e
        !byte $02,$2d,$00,$1e,$01,$4b,$00,$1e,$00,$00,$00,$1e,$00,$00,$00,$0f
        !byte $03,$a9,$00,$0f,$03,$75,$00,$0f,$03,$14,$00,$0f,$02,$be,$00,$1e
        !byte $01,$5f,$00,$1e,$01,$ba,$00,$1e,$01,$f1,$00,$1e,$01,$27,$00,$1e
        !byte $00,$00,$00,$1e,$00,$00,$00,$0f,$03,$75,$00,$0f,$03,$43,$00,$0f
        !byte $02,$e8,$00,$0f,$02,$97,$00,$1e,$01,$4b,$00,$1e,$01,$8a,$00,$1e
        !byte $01,$d5,$00,$1e,$01,$17,$00,$1e,$00,$00,$00,$1e,$00,$00,$00,$0f
        !byte $03,$14,$00,$0f,$02,$be,$00,$0f,$02,$97,$00,$0f,$02,$be,$00,$1e
        !byte $02,$4f,$00,$1e,$02,$2d,$00,$1e,$01,$ba,$00,$1e,$02,$4f,$00,$0f
        !byte $01,$ba,$00,$0f,$02,$4f,$00,$0f,$02,$be,$00,$0f,$02,$97,$00,$0f
        !byte $01,$ba,$00,$0f,$02,$97,$00,$0f,$03,$14,$00,$0f,$02,$be,$00,$0f
        !byte $03,$75,$00,$0f,$04,$9d,$00,$0f,$03,$75,$00,$0f,$02,$be,$00,$0f
        !byte $03,$75,$00,$0f,$02,$4f,$00,$0f,$02,$be,$00,$0f,$01,$f1,$00,$0f
        !byte $02,$4f,$00,$0f,$02,$be,$00,$0f,$02,$4f,$00,$0f,$01,$f1,$00,$0f
        !byte $02,$4f,$00,$0f,$01,$a2,$00,$0f,$01,$f1,$00,$0f,$01,$ba,$00,$1e
        !byte $02,$2d,$00,$1e,$02,$97,$00,$1e,$02,$2d,$00,$1e,$01,$ba,$00,$1e
        !byte $01,$4b,$00,$1e,$01,$17,$00,$1e,$00,$dd,$00,$1e,$01,$27,$00,$1e
        !byte $01,$5f,$00,$1e,$01,$ba,$00,$1e,$01,$5f,$00,$1e,$01,$27,$00,$1e
        !byte $01,$5f,$00,$1e,$00,$d1,$00,$1e,$00,$00,$00,$1e,$00,$00,$00,$0f
        !byte $02,$97,$00,$0f,$02,$2d,$00,$0f,$01,$ba,$00,$0f,$01,$8a,$00,$0f
        !byte $02,$97,$00,$0f,$02,$2d,$00,$0f,$01,$8a,$00,$0f,$01,$5f,$00,$1e
        !byte $01,$ba,$00,$1e,$01,$17,$00,$1e,$01,$ba,$00,$1e,$01,$27,$00,$1e
        !byte $01,$f1,$00,$1e,$01,$4b,$00,$1e,$02,$2d,$00,$1e,$01,$5f,$00,$1e
        !byte $02,$4f,$00,$1e,$01,$8a,$00,$1e,$02,$72,$00,$1e,$02,$2d,$00,$1e
        !byte $01,$d5,$00,$1e,$01,$8a,$00,$1e,$01,$4b,$00,$1e,$01,$17,$00,$1e
        !byte $01,$27,$00,$1e,$00,$c5,$00,$1e,$00,$dd,$00,$1e,$00,$ea,$00,$1e
        !byte $00,$d1,$00,$1e,$00,$dd,$00,$1e,$01,$ba,$00,$1e,$01,$27,$00,$78
        !byte $00,$00,$00,$00
