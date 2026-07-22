// by anthony king
//    marco fontana
//    viktoriia nymkovich

.syntax unified
  .cpu cortex-m4
  .fpu softvfp
  .thumb
  
  .global Main
  .global SysTick_Handler
  .global EXTI0_IRQHandler
  .global setupRound

  #include "definitions.S"

  .equ    FEEDBACK_WIN_MASK,    (1 << LD4_PIN)
  .equ    FEEDBACK_LOSE_MASK,   (1 << LD3_PIN)
  .equ    FEEDBACK_LEDS_MASK,   ((1 << LD3_PIN) | (1 << LD4_PIN))
  .equ    FLASH_TABLE_LED_MASK, ((1 << LD6_PIN) | (1 << LD10_PIN) | (1 << LD7_PIN))
  
  .equ    ROUND_MS,             3000
  .equ    FEEDBACK_HALF_MS,     120
  .equ    FEEDBACK_TOGGLES,     8

  .equ    ALL_LED_MODER_CLR,    0xFFFF0000
  .equ    ALL_LED_MODER_SET,    0x55550000

  .section .text
  .type Main, %function
Main:
  @
  @ Enable GPIO Port E clock; configure all 8 user LEDs (pins 8-15) as outputs
  @ (same layout as flashAllLEDs.s on STM32F3 Discovery)
  @
  LDR     R4, =RCC_AHBENR
  LDR     R5, [R4]
  ORR     R5, R5, #(0b1 << (RCC_AHBENR_GPIOEEN_BIT))
  STR     R5, [R4]
  LDR     R4, =GPIOE_MODER
  LDR     R5, [R4]
  LDR     R4, =ALL_LED_MODER_CLR
  BIC     R5, R5, R4
  LDR     R4, =ALL_LED_MODER_SET
  ORR     R5, R5, R4
  LDR     R4, =GPIOE_MODER
  STR     R5, [R4]
                                          @ Initialise the first countdown
  LDR     R4, =SCB_ICSR                   @ Configure SysTick Timer to generate an interrupt every 1ms
  LDR     R5, =SCB_ICSR_PENDSTCLR         @   + Clearing any pre-existing interrupts
  STR     R5, [R4]                        @
  LDR     R4, =SYSTICK_CSR                @ Stop SysTick timer
  LDR     R5, =0                          @   by writing 0 to CSR
  STR     R5, [R4]                        @   CSR is the Control and Status Register
  LDR     R4, =SYSTICK_LOAD               @ Set SysTick LOAD for 1ms delay
  LDR     R5, =7999                       @ Assuming 8MHz clock
  STR     R5, [R4]                        @ 
  LDR     R4, =SYSTICK_VAL                @   Reset SysTick internal counter to 0
  LDR     R5, =0x1                        @     by writing any value
  STR     R5, [R4]
  @ Prepare external interrupt Line 0 (USER pushbutton)
  @ We'll count the number of times the button is pressed
  @
  @ Initialise count to zero
  @ Configure USER pushbutton (GPIO Port A Pin 0 on STM32F3 Discovery
  @   kit) to use the EXTI0 external interrupt signal
  @ Determined by bits 3..0 of the External Interrrupt Control
  @   Register (EXTIICR)
  LDR     R4, =SYSCFG_EXTIICR1
  LDR     R5, [R4]
  BIC     R5, R5, #0b1111
  STR     R5, [R4]
  @ Enable (unmask) interrupts on external interrupt Line0
  LDR     R4, =EXTI_IMR
  LDR     R5, [R4]
  ORR     R5, R5, #1
  STR     R5, [R4]
  @ Set falling edge detection on Line0
  LDR     R4, =EXTI_FTSR
  LDR     R5, [R4]
  ORR     R5, R5, #1
  STR     R5, [R4]
  @ Enable NVIC interrupt #6 (external interrupt Line0)
  LDR     R4, =NVIC_ISER
  MOV     R5, #(1<<6)
  STR     R5, [R4]
  BL      setupRound
  LDR     R4, =SYSTICK_CSR                @ Start SysTick after first round is configured
  LDR     R5, =0x7
  STR     R5, [R4]

Idle_Loop:
  B       Idle_Loop


@
@ SysTick interrupt handler
@
@ Handling the interrupt, when the feedback phase is:
@   - Inactive: The round timer will be decremented each tick; on timeout,
@     the score will be updated, clearing the round LEDs, and starting
@     the equivalent win/lose blink.
@   - Active: Advanding the actual blink, calling setupRound() when done.
@
  .type  SysTick_Handler, %function
SysTick_Handler:
  PUSH    {R4-R7, LR}
.LHandler_Entry:                          @
  LDR     R4, =feedback_phase             @
  LDR     R5, [R4]                        @ feedbackPhase = memory[&feedbackPhase];
  CMP     R5, #0                          @ if (feedbackPhase != 0)
  BEQ     .LRound_Timer_Decrement         @ {
  LDR     R4, =feedback_ms_until_toggle   @
  LDR     R6, [R4]                        @   msUntilToggle = memory[&feedbackMsUntilToggle];
  SUBS    R6, R6, #1                      @   msUntilToggle--;
  BHI     .LFeedback_Store_Countdown      @   if (msUntilToggle > 0)
  LDR     R4, =feedback_toggles_remaining @   {
  LDR     R7, [R4]                        @     togglesRemaining = memory[&feedbackTogglesRemaining];
  SUBS    R7, R7, #1                      @     togglesRemaining--;
  BEQ     .LFeedback_Clear_And_Next_Round @     if (togglesRemaining == 0)
  LDR     R4, =feedback_phase             @     {
  LDR     R4, [R4]                        @       feedbackPhase = memory[&feedbackPhase];
  CMP     R4, #1                          @       if (feedbackPhase != 1)
  BEQ     .LFeedback_Win_Mask             @       {
  LDR     R4, =FEEDBACK_LOSE_MASK         @         feedbackLedMask = FEEDBACK_LOSE_MASK;
  B       .LFeedback_Xor_Odr              @       } else {
.LFeedback_Win_Mask:                      @
  LDR     R4, =FEEDBACK_WIN_MASK          @         feedbackLedMask = FEEDBACK_WIN_MASK;
.LFeedback_Xor_Odr:                       @       }
  MOV     R6, R4                          @
  LDR     R4, =GPIOE_ODR                  @
  LDR     R5, [R4]                        @         gpioeOdr = memory[&GPIOE_ODR];
  EOR     R5, R5, R6                      @         gpioeOdr ^= feedbackLedMask;
  STR     R5, [R4]                        @         memory[&GPIOE_ODR] = gpioeOdr;
  LDR     R5, =FEEDBACK_HALF_MS           @
  LDR     R4, =feedback_ms_until_toggle   @
  STR     R5, [R4]                        @         memory[&feedbackMsUntilToggle] = FEEDBACK_HALF_MS;
  LDR     R4, =feedback_toggles_remaining @
  STR     R7, [R4]                        @         memory[&feedbackTogglesRemaining] = togglesRemaining;
  B       .LClear_Sys_Tick_Pending_Exit   @       }
                                          @     }
                                          @   }
.LFeedback_Store_Countdown:               @
  LDR     R4, =feedback_ms_until_toggle   @
  STR     R6, [R4]                        @   memory[&feedbackMsUntilToggle] = msUntilToggle;
  B       .LClear_Sys_Tick_Pending_Exit   @
.LFeedback_Clear_And_Next_Round:          @
  LDR     R4, =GPIOE_ODR                  @   gpioeOdr = memory[&GPIOE_ODR];
  LDR     R5, [R4]                        @
  LDR     R6, =FEEDBACK_LEDS_MASK         @
  BIC     R5, R5, R6                      @   gpioeOdr &= ~FEEDBACK_LEDS_MASK;
  STR     R5, [R4]                        @   memory[&GPIOE_ODR] = gpioeOdr;
  MOV     R5, #0                          @
  LDR     R4, =feedback_phase             @
  STR     R5, [R4]                        @   memory[&feedbackPhase] = 0;
  B       .LCall_Setup_Round              @
                                          @   }
                                          @ }
.LRound_Timer_Decrement:                  @ 
  LDR     R4, =remaining_time_in_ms       @
  LDR     R5, [R4]                        @ remainingMs = memory[&remainingTimeInMs];
  SUBS    R5, R5, #1                      @ remainingMs--;
  STR     R5, [R4]                        @ memory[&remainingTimeInMs] = remainingMs;
  BGT     .LClear_Sys_Tick_Pending_Exit   @ if (remainingMs > 0)
  LDR     R4, =actual_presses             @ {
  LDR     R5, [R4]                        @   actualPresses = memory[&actualPresses];
  LDR     R4, =required_presses           @
  LDR     R6, [R4]                        @   requiredPresses = memory[&requiredPresses];
  MOV     R7, #1                          @   roundWon = true;
  CMP     R5, R6                          @   if (actualPresses == requiredPresses)
  BEQ     .LAfter_Round_Won_Check         @   {
  MOV     R7, #0                          @     roundWon = false;
.LAfter_Round_Won_Check:                  @   }
  LDR     R4, =score                      @
  LDR     R5, [R4]                        @   scoreValue = memory[&score];
  CMP     R7, #0                          @   if (!roundWon)
  BEQ     .LScore_Zero_Result             @   {
  ADD     R5, R5, #1                      @     scoreValue++;
  B       .LScore_Store_Result            @
.LScore_Zero_Result:                      @
  MOV     R5, #0                          @     scoreValue = 0;
.LScore_Store_Result:                     @   }
  STR     R5, [R4]                        @   memory[&score] = scoreValue;
  LDR     R4, =GPIOE_ODR                  @
  LDR     R5, [R4]                        @   gpioeOdr = memory[&GPIOE_ODR];
  LDR     R6, =FLASH_TABLE_LED_MASK       @
  BIC     R5, R5, R6                      @   gpioeOdr &= ~FLASH_TABLE_LED_MASK;
  STR     R5, [R4]                        @   memory[&GPIOE_ODR] = gpioeOdr;
  CMP     R7, #0                          @   if (!roundWon)
  BEQ     .LFeedback_Phase_Lose           @   {
  MOV     R5, #1                          @     nextFeedbackPhase = 1;
  B       .LWrite_Feedback_State          @   } else {
.LFeedback_Phase_Lose:                    @
  MOV     R5, #2                          @     nextFeedbackPhase = 2;
                                          @
                                          @
.LWrite_Feedback_State:                   @   }
  LDR     R4, =feedback_phase             @
  STR     R5, [R4]                        @   memory[&feedbackPhase] = nextFeedbackPhase;
  LDR     R4, =feedback_ms_until_toggle   @
  LDR     R5, =FEEDBACK_HALF_MS           @
  STR     R5, [R4]                        @   memory[&feedbackMsUntilToggle] = FEEDBACK_HALF_MS;
  LDR     R4, =feedback_toggles_remaining @
  LDR     R5, =FEEDBACK_TOGGLES           @
  STR     R5, [R4]                        @   memory[&feedbackTogglesRemaining] = FEEDBACK_TOGGLES;
  B       .LClear_Sys_Tick_Pending_Exit   @ }
.LCall_Setup_Round:                       @
  BL      setupRound                      @ setupRound();
.LClear_Sys_Tick_Pending_Exit:            @
  LDR     R4, =SCB_ICSR                   @
  LDR     R5, =SCB_ICSR_PENDSTCLR         @
  STR     R5, [R4]                        @ Clear (acknowledge) the interrupt
  POP     {R4-R7, PC}


@
@ External interrupt line 0 interrupt handler
@   (count button presses)
@
  .type  EXTI0_IRQHandler, %function
EXTI0_IRQHandler:
  PUSH    {R4-R5, LR}
  LDR     R4, =actual_presses             @
  LDR     R5, [R4]                        @ actualPresses = memory[&actualPresses];
  ADD     R5, R5, #1                      @ actualPresses++;
  STR     R5, [R4]                        @ memory[&actualPresses] = actualPresses;
  LDR     R4, =EXTI_PR                    @
  MOV     R5, #(1<<0)                     @ extiPrClearMask = (1 << 0);
  STR     R5, [R4]                        @ memory[&EXTI_PR] = extiPrClearMask;
  POP     {R4-R5, PC}

@
@ loadRandomValues subroutine
@   Generate a sequence of random numbers (ranging from 0 to 2)
@   using the formula:
@ 
@   nextRandom = (multiplier * currentRandom + increment)(mod m) i.e. nextRandom = remainder 
@   this formula is used twice to produce a longer period generator
@ 
@ Parameters:
@   R1: address of seed (word 0); result is written at word 1 (R1+4)
@
@ Return:
@   R0: next random value (0..2) to setupRound (modify it accordingly)
loadRandomValues:
  PUSH  {R4-R8, LR}
  MOV   R4, #16                           @ modulus = 16       
  MOV   R5, #5                            @ multiplier = 5        
  MOV   R6, #1                            @ increment = 1  
  LDR   R7, [R1]                          @
                                          @
                                          @
  MUL   R7, R5, R7                        @ temp = multiplier * currentRandom
  ADD   R7, R7, R6                        @ temp = temp + increment
  AND   R7, R7, #0xF                      @ firstRandom = (temp)(mod 16) 
                                          @
                                          @
  STR   R7, [R1]                          @ newSeed = currentSeed
  MOV   R4, #3                            @ modulus = 3        
  UDIV  R8, R7, R4                        @ quotient  = firstRandom / modulus
  MUL   R8, R8, R4                        @ product   = quotient * modulus
  SUB   R7, R7, R8                        @ remainder = temp - product
  STR   R7, [R1, #4]                      @ memory[&initialSeed + 4] = nextRandom (0..2)
  MOV   R0, R7                            @ return randomPickedIndex in R0 for setupRound
  POP   {R4-R8, PC}

@
@ light subroutine
@   lights LED corresponding to passed number
@   in R0 exactly one time.
@
@ Parameters:
@   R0: number (between 0-2)
@
light:
  PUSH    {R1-R2, LR}
  CMP     R0, #2                          @ if number > #2 {
  BHI     .LLight_Done                    @ ignore, end subroutine }, else {
                                          @ load bitmask for the selected LED from the jump table
  LDR     R1, =flash_table                @ R1 = flashTableAddress
  LDR     R2, [R1, R0, LSL #2]            @ R2 = flash_table[number] = relevantBitMask
                                          @ toggle the selected pin in GPIOE_ODR
  LDR     R1, =GPIOE_ODR                  @
  LDR     R0, [R1]                        @ read current output state
  EOR     R0, R0, R2                      @  toggle selected LED bit
  STR     R0, [R1]                        @ write updated output state
.LLight_Done:                             @ }
  POP     {R1-R2, PC}

@
@ setupRound subroutine
@   Used to start a new round, including the following phases:
@     - Reset of the actual presses + reload of ramining time
@     - Draw of the next LED index (0..2)
@   Each round a different index will be choosen to differ from the previous one,
@   then GPIOE_ODR will be udpated so only one of LD6/LD10/LD7 will be driven for the round.
@
  .type   setupRound, %function
setupRound:
  PUSH    {R4-R7, LR}
  LDR     R4, =actual_presses             @ 
  MOV     R5, #0                          @ parsedValue = 0;
  STR     R5, [R4]                        @ memory[&actualPresses] = parsedValue;
  LDR     R4, =remaining_time_in_ms       @
  LDR     R5, =ROUND_MS                   @ parsedValue = ROUND_MS
  STR     R5, [R4]                        @ memory[&remainingTimeInMs] = parsedValue;
  LDR     R1, =initial_seed               @
  BL      loadRandomValues                @ randomPickedIndex = loadRandomValues(&initialSeed);
  LDR     R4, =last_picked_index          @
  LDR     R5, [R4]                        @ previousPickedIndex = lastPickedIndex;
  CMP     R5, #-1                         @ if (previousPickedIndex != -1)
  BEQ     .LLED_Processing                @ {
  CMP     R0, R5                          @   if (randomPickedIndex == previousPickedIndex)
  BNE     .LLED_Processing                @   {
  ADD     R0, R0, #1                      @     randomPickedIndex++;
  CMP     R0, #3                          @     if (randomPickedIndex == 3)
  BNE     .LLED_Processing                @     {
  MOV     R0, #0                          @         randomPickedIndex = 0;
.LLED_Processing:                         @     }
                                          @   }
                                          @ }
  STR     R0, [R4]                        @ memory[&lastPickedIndex] = randomPickedIndex;
  MOV     R7, R0                          @
  ADD     R0, R7, #1                      @
  LDR     R4, =required_presses           @
  STR     R0, [R4]                        @ memory[&requiredPresses] = randomPickedIndex + 1;
  MOV     R0, R7                          @
  BL      light                           @ light(randomPickedIndex);
  MOV     R0, R7                          @
  LDR     R4, =GPIOE_ODR                  @
                                          @ // Toggling the selected LEDs without changing other pins on port
                                          @ // (According to the provided flash mask)
  LDR     R5, [R4]                        @ gpioeOdr = GPIOE_ODR;
  LDR     R6, =FLASH_TABLE_LED_MASK       @
  BIC     R5, R5, R6                      @ gpioeOdr &= ~FLASH_TABLE_LED_MASK;
  LDR     R6, =flash_table                @
  LDR     R6, [R6, R0, LSL #2]            @
  ORR     R5, R5, R6                      @ gpioeOdr |= flash_table[randomPickedIndex];
  STR     R5, [R4]                        @ memory[&GPIOE_ODR] = gpioeOdr;
  POP     {R4-R7, PC}


@
@ Allocating data in memory
@
  .section .data

@ Initial seed space for generating pseudo-random numbers
initial_seed:
  .word   1
  .space  4

@ Table for flash subroutine (press count = index + 1):
@   0 = LD6  -> 1 press
@   1 = LD10 -> 2 presses
@   2 = LD7  -> 3 presses
flash_table:
  .word   (1 << LD6_PIN)
  .word   (1 << LD10_PIN)
  .word   (1 << LD7_PIN)

@ Score representing the consecutive wins
score:
  .word   0

@ Fixed presses required per round
required_presses:
  .word   0

@ Actual presses made in a round
actual_presses:
  .word   0

@ Represents the remaining round time (ms)
remaining_time_in_ms:
  .word   0

@ Remembers which LED was chosen last round.
@ It is initialized to 0xFFFFFFFF for no round.
last_picked_index:
  .word   0xFFFFFFFF

@ Phase of performed feedback
@ [0 none, 1 (win blink), 2 (lose blink)]
feedback_phase:
  .word   0

@ Ms until next feedback LED toggle while feedback_phase is 1 or 2 (SysTick decrements).
feedback_ms_until_toggle:
  .word   0

@ Half-period toggles remaining in the win/lose blink sequence; at 0 the sequence ends.
feedback_toggles_remaining:
  .word   0

  .end
