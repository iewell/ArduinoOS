; AOS, a simple operating system for the ATMEL mega328
; (C) Copyright 2013 Ian Ewell

; This file implements an extremely simple operating system (mostly just the kernel and some user apps to demonstrate functionality) that was written in
; a two week period. It is written in AVR assembly as it was a project to teach myself how to code in assembly. I am quite aware that most of
; this would be better written in C. In hindsight there are quite a few design flaws that would make this unsuitible for real use (if you find running a
; multitasking kernel running on an Arduino is useful to begin with), the most glaring being the lack of proper memory management, though you can only do
; so much without a MPU or MMU. This can be explained by a few reasons, some of them possibly rendering me crazy for attempting this project.
; 	1) My knowledge of operating systems theory was quite small, but I knew enough concepts to just get my feet wet
;	2) I had almost no knowledge or experience in any kind of assembly language
;	3) I had no knowledge of the AVR architecture and the CPU limits were "fun" to discover as I wrote the code
;	4) I limited my resources to the AVR reference manuals with some exceptions
; Needless to say, despite these setbacks, I was able to code a functioning multitasking kernel with a small command line interface to boot. The project
; also proved incredibly educational, as I achieved a decent fluency in assembly, a deeper understanding of CPU hardware, and the basics of getting a
; multitasking OS to work. All that in roughly 2 weeks worth of work.

; Port Register Definitions
PINB	= 0x03
DDRB	= 0x04
PORTB	= 0x05
PINC	= 0x26
DDRC	= 0x27
PORTC	= 0x28
PIND	= 0x29
DDRD	= 0x2a
PORTD	= 0x2b

; Reset Register
MCUSR	= 0x35

; Status Register
SPL 	= 0x3D
SPH 	= 0x3E
SREG  	= 0x3F

; Timer Registers
TIFR1	= 0x16
TIMSK1	= 0x6f
TCCR1A	= 0x80
TCCR1B	= 0x81
TCCR1C	= 0x82
TCNT1L	= 0x84
TCNT1H	= 0x85
ICR1L	= 0x86
ICR1H	= 0x87
OCR1AL	= 0x88
OCR1AH	= 0x89
OCR1BL	= 0x8a
OCR1BH	= 0x8b

; UART Registers
UDR0	= 0xc6
UBRR0H	= 0xc5
UBRR0L	= 0xc4
UCSR0C	= 0xc2
UCSR0B	= 0xc1
UCSR0A	= 0xc0

; Register allocation
; Currently the kernel will reserve registers r0 - r20, leaving r21-r31 to user programs plus the stack pointer. This is to reduce the cost
; of having to save the context every time an interrupt occurs and to save memory. Also makes my life harder when writing user code. Trade-offs...

; Stack start for the kernel - 32 bytes for stack; may increase if needed (we're trying to multitask on 2k of ram)
KERN_STACK_START = 0x1F

; Kernel task constants
KERN_TASK_SIZE = 16 ; 16 bytes to store task state
KERN_TASK_STORE_START = 0x0120 ; Location in memory to store tasks
KERN_MAX_TASKS = 8 ; No more than 8 tasks running at once
KERN_TASK_GLOBALS_START = KERN_TASK_STORE_START+(KERN_TASK_SIZE*KERN_MAX_TASKS)
KERN_TASK_MAP = KERN_TASK_GLOBALS_START ; Bitmap used to show which PIDs are in use (i.e. 10000001 means PID 0 and 7 are used)
KERN_TASK_CURRENT = KERN_TASK_GLOBALS_START+1 ; Place in memory to store the PID of the current task

; Memory Management
KERN_MEMORY_MAP = KERN_TASK_GLOBALS_START+2 ; Memory bitmap to show which 64 byte blocks of memory are in use
KERN_MEMORY_MAP_2 = KERN_MEMORY_MAP+1 ; second part of the bitmap (as there are 16 blocks, a 2 byte bitmap is needed)
KERN_USER_MEMORY_START = 0x0500 ; The start of the area reserved for memory allocations: 1 KB into the RAM
KERN_USER_MEMORY_BLOCK_SIZE = 64 ; Memory blocks are 64 bytes each
KERN_USER_MEMORY_BANKS = 16 ; There are 16 64-byte blocks total, which makes 1 KB of user ram total

; Scheduling and clock
KERN_CLOCK = KERN_MEMORY_MAP_2 + 1 ; 32-bit clock updated by the scheduler
KERN_SCHED_TASK_TIME = KERN_CLOCK + 4 ; Time allotted to currently executing task (the quantum)
KERN_SCHED_ENABLE = KERN_SCHED_TASK_TIME + 2 ; Stores if the scheduler is enabled or not (if not, the current process runs forever)

; Task sleeping wait tables
KERN_TASK_SLEEP_TABLE_START = KERN_SCHED_ENABLE + 1 ; Array of 2 byte variables that store the current sleep time for each task

; System locks
KERN_LOCK_UART = KERN_TASK_SLEEP_TABLE_START + 16 ; PID that owns lock to UART. Defaults to PID 0

.text ; Text segment begin at 0x0000

	;Interupt vector table
	jmp	sys_init			; Program execution starts at 0x0000
	jmp	default_int_handler	; IRQ0 Handler
	jmp	default_int_handler	; IRQ1 Handler
	jmp	default_int_handler	; PCINT0 Handler
	jmp	default_int_handler	; PCINT1 Handler
	jmp	default_int_handler	; PCINT2 Handler
	jmp	default_int_handler	; Watchdog Timer
	jmp	default_int_handler	; Timer2 Compare
	jmp	default_int_handler	; Timer2 Compare
	jmp	default_int_handler	; Timer2 Overflow Handler
	jmp	default_int_handler	; Timer1 Capture Handler
	jmp	default_int_handler	; Timer1 Compare A Handler
	jmp	default_int_handler	; Timer1 Compare B Handler
	jmp	sys_timer1_overflow	; Timer1 Overflow Handler, used for rescheduling
	jmp	default_int_handler	; Timer0 Compare A Handler
	jmp	default_int_handler	; Timer0 Compare B Handler
	jmp	default_int_handler	; Timer0 Overflow Handler
	jmp	default_int_handler	; SPI Transfer Complete Handler
	jmp	default_int_handler	; USART, RX Complete Handler
	jmp	default_int_handler	; USART, UDR Empty Handler
	jmp	default_int_handler	; USART, TX Complete Handler
	jmp	default_int_handler	; ADC Conversion Complete Handler
	jmp	default_int_handler	; EEPROM Ready Handler
	jmp	default_int_handler	; Analog Comparator Handler
	jmp	default_int_handler	; 2-wire Serial Interface Handler
	jmp	default_int_handler	; Store Program Memory Ready Handler
;
; Interupt handlers
;

; Default handler for when we have nothing to do for a particular interrupt
default_int_handler:
	reti

; This is called every time timer1 overflows. Timer 1 is used to time a task's running time
; When the time expires, we call the scheduler to pick a new task to run and swap into it.
; A timer overflow occurs when the timer register goes over 0xFFFF
sys_timer1_overflow:
	rjmp 	sys_schedule
	reti

;
; Kernel message strings
;
str_sys_welcome: .ascii "AOS Starting up...\r\n"
.byte 0
str_sys_user_test: .ascii "Hello World!\r\n"
.byte 0
str_sys_user_test2: .ascii "Hello Woild!\r\n"
.byte 0
.byte 0

;
; Kernel Utility Functions
;
.text

; sys_print_string(void* str): str pointer stored in Z pointer register (r30-r31)
sys_print_string: 			; Prints a string stored in flash
	lpm 	r16, Z+
	cpi 	r16, 0
	breq 	sys_print_string_ret

	sys_print_string_loop:
	lds  	r2, UCSR0A
	sbrs 	r2, 5
	rjmp 	sys_print_string_loop
	sts 	UDR0, r16
	rjmp 	sys_print_string

	sys_print_string_ret:
	ret

;
; Kernel Initialization Routines
;
sys_init:
	eor		r1,r1			; Clear MCUSR
	out		MCUSR, r1

	; Initialize kernel stack
	ldi 	r16, 0x01
	ldi 	r17, KERN_STACK_START
	out 	SPH, r16
	out 	SPL, r17
	
	; Set up timer 1 to use I/O clock / 1024. This means the timer counter TCNT1 will be incremented
	; every 1024 CPU cycles. Since the processor speed is 16 MHz, or 16 million hertz, a 16-bit
	; timer will overflow rapidly, so we need to divide it by 1024 to "slow" it down. This timer
	; is primarily used to measure how long a task has been running so that it can swap out tasks
	; when a certain amount of time has expired.
	ldi		r24, 0x05
	sts		TCCR1B, r24 ; 0x05 sets timer 1's divider to 1024
	ldi 	r24, 0x01
	sts 	TIMSK1, r24 	; 0x01 enables overflow interrupts on timer

	rcall 	sys_init_uart   ; Initialize serial, which allows communication to a terminal

	ldi 	r30, lo8(str_sys_welcome) ; Now that we can print, print a welcome screen for the OS
	ldi 	r31, hi8(str_sys_welcome)
	rcall 	sys_print_string

	ldi 	r30, lo8(KERN_MEMORY_MAP) ; Clear out the memory map so that nothing is currently allocated
	ldi 	r31, hi8(KERN_MEMORY_MAP)
	eor 	r17, r17
	st 		Z+, r17
	st 		Z+, r17

	rcall 	sys_init_task   ; Initialize the shell task, as that is the first thing we are running

	; Here, we initialize the timer 1 counter to a very high number so an overflow will occur quickly.
	; The processor seems to take time before the timer is functional, and we need to wait for it to
	; function before we run processes, as the timer is crucial for scheduler operations. When the
	; timer is functional, we will know because an overflow will occur, setting the overflow flag
	; (bit 0) in the TIFR1 register. We won't start the shell until that bit is set
	cli 					; Disable interrupts
	out		TIFR1, r16 		; Writing 0x01 to TIFR1 clears the overflow flag, or sets it to 0
	ldi		r18, 0x00		; Very high number so an overflow occurs quickly
	ldi		r19, 0xFF 		; High byte of timer
	sts		TCNT1L, r18		; Set the actual timer 1 counter register (TCNT1)
	sts		TCNT1H, r19

	; Just zero out all of our kernel internal clocks
	sts 	KERN_SCHED_TASK_TIME, r18 ; Initialize clocks for scheduling and whatnot
	sts 	KERN_SCHED_TASK_TIME+1, r18
	sts 	KERN_CLOCK, r18
	sts 	KERN_CLOCK+1, r18
	sts 	KERN_CLOCK+2, r18
	sts 	KERN_CLOCK+3, r18
	ldi 	r18, 0x01 ; Scheduler is enabled by default
	sts 	KERN_SCHED_ENABLE, r18

	; This block is the actual loop to stall execution until the timer is initialized,
	; during which a timer overflow will occur and set the overflow flag in TIFR1
	sys_init_wait_timer: ; Wait for timer to initialize
	sbis	TIFR1, 0 ; sbis is skip if bit is set. The next jump instruction will be skipped if the flag is set
	rjmp 	sys_init_wait_timer

	out		TIFR1, r16  	; Clear out the overflow flag (it is set at this point)

	; Here, the timer is set to a value such that 0xFFFF - value is the number of timer ticks the first task will
	; have to execute. The timer inturrupt will be enabled soon, so when this time expires, the scheduler will be
	; invoked
	ldi		r18, 0x90		; Schedule time to execute
	ldi		r19, 0xff
	sts		TCNT1L, r18		; Set the timer
	sts		TCNT1H, r19

	; Here we set r3 to 0, which sys_task_start reads to start executing the task. At this point, only PID 0 is
	; created, so we have no choice but to start it (and it's the shell)
	eor 	r3, r3 ; Set task to 0
	rjmp 	sys_task_start ; Begin execution

	; We should not be here, but if we are, loop forever
	loop:
	rjmp 	loop

; The UART is a very simple serial communication scheme that is used to communicate to a computer, and the data
; travels over the USB. In this case, the computer will emulate a terminal, and we will treat is as such. Therefore,
; we can print text onto the screen via the UART. The UART has a number of control registers with fancy options, but
; this function sets up the UART to communicate at 9600 bytes per second and enables reading and writing to it (RX and TX)
sys_init_uart:
	ldi		r16, 103			; Set the baud rate to 9600 bytes/s
	ldi		r17, 0
	sts		UBRR0L, r16
	sts		UBRR0H, r17
	ldi		r16, 0x98
	sts		UCSR0B, r16
	ldi		r16, 0x06
	sts		UCSR0C, r16
	ldi		r16, 0x00
	sts		UCSR0A, r16
	ldi 	r16, 0x00
	sts 	KERN_LOCK_UART, r16 ; Init UART lock to PID 0
	ret

; This function initializes the first task in the system, the shell task. All is does is fill out the structure
; for pid 0 with some default parameters and gives it a space for its stack
sys_init_task:
; C definition of task structure
; struct task
; {
;	u8 r21 // registers first to speed up context switches
;	u8 r22
;	...
; 	u8 r31
; 	u8 SPH
; 	u8 SPL
; 	u16 PGR // Current program space
; 	u8 SREG // Status register
; }

	; Initialize first task (shell)
	ldi 	r30, lo8(KERN_TASK_STORE_START) ; r30 and r31 make up the Z pointer, which points to PID 0 task structure
	ldi 	r31, hi8(KERN_TASK_STORE_START)
	ldi 	r16, 0

	; Init generic regs
	st 		Z+, r16 ; st stores a register into the area of memory a pointer points to. Z+ means to use the Z pointer
	st 		Z+, r16 ; and to increment it after the store, so we can fill out the data structure
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16

	; Stack pointer
	ldi 	r16, 0x03
	ldi 	r17, 0x00
	st 		Z+, r16
	st 		Z+, r17

	; Here we load the address of the shell program and store it into the PGR
	; element of the data structure. This means that the program entry will
	; start executing at the entry area when the task is started
	ldi 	r16, hi8(shell_entry)
	ldi 	r17, lo8(shell_entry) 
	lsr 	r16 
	ror 	r17
	st 		Z+, r17
	st 		Z+, r16

	; clear sreg (status register)
	ldi 	r16, 0
	st 		Z+, r16

	; The task map is set so it reads 00000001 in binary, indicating PID 0 is taken
	ldi 	r30, lo8(KERN_TASK_MAP)
	ldi 	r31, hi8(KERN_TASK_MAP)
	ldi 	r16, 0x01
	st 		Z, r16

	; Current task is set to 0 since that is all we have
	ldi 	r30, lo8(KERN_TASK_CURRENT)
	ldi 	r31, hi8(KERN_TASK_CURRENT)
	ldi 	r16, 0x00
	st 		Z, r16

	; This just loops through the sleep table array and make sure nothing is sleeping yet
	; (set it all to 0x0000)
	ldi 	r30, lo8(KERN_TASK_SLEEP_TABLE_START)
	ldi 	r31, hi8(KERN_TASK_SLEEP_TABLE_START)
	clr 	r17
	sys_init_task_sleep_loop:
	cpi 	r17, KERN_MAX_TASKS*2
	breq 	sys_init_task_exit
	inc 	r17
	st 		Z+, r16
	rjmp 	sys_init_task_sleep_loop

	sys_init_task_exit:
	ret ; success

;;;;;;;;;;;;;;;;;;;;;;;
; Kernel System Calls ;
;;;;;;;;;;;;;;;;;;;;;;;

; sys_call_exec(u16 start): creates a new task to be executed by the scheduler
; start: mapped into r30 (high) and r31 (low) 

; This part needs to be up here because the branch instruction can only jump 64 words
sys_exec_loop_error:
	mov 	r30, r2   ; Restore Z pointer
	mov 	r31, r3
	ldi 	r21, 0xFF ; Return error code of 0xFF
	out 	SREG, r10
	sei 			  ; Reenable interupts
	ret

sys_call_exec:
	cli  			; No interupting in this stage
	in 		r10, SREG ; Save SREG
	mov 	r2, r30 ; store program address
	mov 	r3, r31
	ldi 	r30, lo8(KERN_TASK_MAP) ; load task map
	ldi 	r31, hi8(KERN_TASK_MAP)
	ld 		r4, Z
	eor 	r5, r5 ; PID counter
	ldi 	r16, KERN_MAX_TASKS ; max tasks to not exceed

	sys_exec_loop:
	sbrs 	r4, 0 ; See if pid is available
	rjmp 	sys_exec_loop_exit
	inc 	r5 ; Nope, next PID
	lsr 	r4 ; Shift PID map into place
	cp 		r5, r16 ; Are we past our limit?
	breq 	sys_exec_loop_error
	rjmp 	sys_exec_loop

	sys_exec_loop_exit:
	push 	r5 ; alloc() uses r5 so save it
	rcall 	sys_call_alloc ; Get ourselves a stack
	cli 	; NO RESCHEDULING!!!
	pop 	r5
	eor 	r15, r15 ; Check our stack pointer
	cp 		r15, r30
	cpc 	r15, r31
	breq 	sys_exec_loop_error ; No more memory
	ldi 	r16, KERN_USER_MEMORY_BLOCK_SIZE-3 ; Set SP to end of buffer (and leave room for return address)
	add 	r30, r16
	adc 	r31, r15
	mov 	r14, r30 ; Keep our SP for later
	mov 	r15, r31
	ldi 	r30, lo8(KERN_TASK_STORE_START) ; compute offset of new task
	ldi 	r31, hi8(KERN_TASK_STORE_START)
	ldi 	r16, KERN_TASK_SIZE
	eor 	r8, r8
	mul 	r16, r5
	add 	r30, r0
	adc 	r31, r8
	ldi 	r16, 0 ; Init generic regs
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r16
	st 		Z+, r15 ; Stack pointer
	st 		Z+, r14
	mov 	r16, r2 ; Load entry point
	mov 	r17, r3
	lsr 	r16
	ror 	r17
	st 		Z+, r17
	st 		Z+, r16
	ldi 	r16, 0 ; clear sreg
	st 		Z+, r16
	in 		r16, SPL ; Save current stack
	in 		r17, SPH
	out 	SPL, r14 ; Temporarily load our new stack
	out 	SPH, r15
	ldi 	r18, hi8(sys_task_exit) ; Load task exit function
	ldi 	r19, lo8(sys_task_exit)
	lsr 	r18 ; Divide by two
	ror 	r19
	pop 	r20 ; Add 2 to SP
	pop 	r20
	push 	r19 ; Push program end return address
	push 	r18
	out 	SPL, r16
	out 	SPH, r17
	ldi 	r30, lo8(KERN_TASK_MAP) ; reload task map
	ldi 	r31, hi8(KERN_TASK_MAP)
	ld 		r4, Z
	ldi 	r16, 0x01 ; load 1
	eor 	r6, r6 	  ; counter

	sys_exec_shift_loop:
	cp 		r6, r5
	breq 	sys_exec_shift_loop_end
	lsl 	r16
	inc 	r6
	rjmp 	sys_exec_shift_loop

	sys_exec_shift_loop_end:
	or 		r4, r16   ; Set PID bit to 1
	st 		Z, 	r4 	  ; Store new mask
	mov 	r30, r2   ; Restore Z pointer
	mov 	r31, r3
	mov 	r21, r5   ; Return PID
	out 	SREG, r10
	rjmp 	sys_schedule ; Reschedule on task start

; sys_call_kill(u8 pid): Kills a process with PID pid
; r21 - PID of process to kill
sys_call_kill:
	cli
	in 		r4, SREG ; Save SREG
	lds 	r6, KERN_TASK_MAP ; Load task map
	clr 	r17 ; Counter
	ldi 	r16, 0x01 ; bit mask
	1:
	cp 		r17, r21
	breq 	2f
	lsl 	r16
	inc 	r17
	rjmp 	1b
	2:
	com 	r16 ; One's complement of bitmask
	and 	r6, r16 ; Clear PID bit in bitmask
	sts 	KERN_TASK_MAP, r6 ; Install new pid map
	lds 	r7, KERN_TASK_CURRENT ; Load current task
	cp 		r21, r7 ; Are we killing ourself?
	breq 	3f ; Reschedule if that is the case
	out 	SREG, r4 ; Restore SREG
	sei
	ret
	3:
	out 	SREG, r4
	rjmp 	sys_schedule

; sys_call_alloc(): Allocates a 64-byte block of memory and stores the pointer in the Z register (stores 0x0000 if no memory left)
sys_call_alloc:
	cli
	in 		r4, SREG
	push 	r0 ; save multiplication destinations
	push 	r1
	lds 	r19, KERN_MEMORY_MAP ; Load the memory maps
	lds 	r20, KERN_MEMORY_MAP_2
	clr 	r5 ; Mem bank counter
	ldi 	r16, KERN_USER_MEMORY_BANKS

	sys_alloc_shift:
	sbrs 	r19, 0
	rjmp 	sys_alloc_shift_end
	inc 	r5 
	lsr 	r20
	ror 	r19
	cp 		r5, r16
	breq 	sys_alloc_no_memory ; Out of memory
	rjmp 	sys_alloc_shift

	sys_alloc_shift_end:
	ldi 	r16, 0x01
	ldi 	r17, 0x00
	clr 	r18 ; Shift counter

	sys_alloc_map_shift:
	cp 		r18, r5
	breq 	sys_alloc_map_shift_end
	inc 	r18
	lsl 	r16
	rol 	r17

	sys_alloc_map_shift_end:
	lds 	r19, KERN_MEMORY_MAP ; reload the memory maps
	lds 	r20, KERN_MEMORY_MAP_2
	or 		r19, r16 ; Mark bank as used
	or 		r20, r17
	sts 	KERN_MEMORY_MAP, r19
	sts 	KERN_MEMORY_MAP_2, r20
	ldi 	r30, lo8(KERN_USER_MEMORY_START) ; Load base address for user memory
	ldi 	r31, hi8(KERN_USER_MEMORY_START)
	ldi 	r16, KERN_USER_MEMORY_BLOCK_SIZE ; multiplier
	mul 	r5, r16
	add 	r30, r0
	adc 	r31, r1
	pop 	r1 ; Restore Mul destination
	pop 	r0
	out 	SREG, r4
	sei
	ret

	sys_alloc_no_memory:
	ldi 	r30, 0x00 ; Return NULL
	ldi 	r31, 0x00
	pop 	r1
	pop 	r0
	out 	SREG, r4
	reti

; sys_call_sleep(int t): Sleeps for a precise but undefined amount of time - r25-r26 sleep time
sys_call_sleep:
	cli
	push 	r0
	push 	r1
	mov 	r2, r30 ; Save Z
	mov 	r3, r31
	in 		r4, SREG
	ldi 	r30, lo8(KERN_TASK_SLEEP_TABLE_START) ; Sleep table
	ldi 	r31, hi8(KERN_TASK_SLEEP_TABLE_START)
	lds 	r5, KERN_TASK_CURRENT
	ldi 	r16, 2 ; 2 bytes for a sleep table entry
	mul 	r5, r16
	add 	r30, r0
	adc 	r31, r1
	st 		Z+, r25
	st 		Z+, r26
	mov 	r30, r2
	mov 	r31, r3
	pop 	r1
	pop 	r0
	out 	SREG, r4
	rjmp 	sys_schedule ; Since we are sleeping, reschedule

; sys_call_uart_lock(): Locks the UART to a specific process and blocks others from accessing it
sys_call_uart_lock:
	cli
	in 		r4, SREG ; save sreg
	lds 	r16, KERN_LOCK_UART ; Load the lock
	lds 	r17, KERN_TASK_CURRENT ; Current task
	cp 		r16, r17 ; Do we own it already?
	breq 	3f ; Don't lock
	cpi 	r16, 0 ; See if the lock is available
	brne 	2f ; Better luck next time
	sts 	KERN_LOCK_UART, r17 ; Lock the UART
	out 	SREG, r4 ; Restore SREG
	sei
	ret
	2: ; Unable to lock. We reschedule then try again next cycle
	ldi 	r16, hi8(sys_call_uart_lock) ; Load address for call so we can make it the return address
	ldi 	r17, lo8(sys_call_uart_lock)
	lsr 	r16
	ror 	r17
	push 	r17
	push 	r16
	out 	SREG, r4
	rjmp 	sys_schedule
	3: ; no need to lock. We already own it
	out 	SREG, r4
	sei
	ret

; sys_call_uart_unlock(): Unlocks the UART if the calling task owns it and gives it to the shell (PID 0)
sys_call_uart_unlock:
	cli
	in 		r4, SREG
	lds 	r16, KERN_LOCK_UART
	lds 	r17, KERN_TASK_CURRENT
	cp 		r16, r17
	brne 	1f ; We don't own the lock so we can't unlock it
	clr 	r16
	sts 	KERN_LOCK_UART, r16
	1:
	out 	SREG, r4
	sei
	ret

; sys_call_uart_write_byte(char byte): Writes a byte to the uart serial
; r25 - input byte
; return - r21, 0 on success, 1 when uart isn't open, 2 if locked by another task
sys_call_uart_write_byte:
	cli
	in 		r4, SREG
	lds 	r16, KERN_LOCK_UART ; Check if we have the UART locked
	lds 	r17, KERN_TASK_CURRENT
	cp 		r16, r17
	brne 	2f
	lds  	r2, UCSR0A ; Check if busy
	sbrs 	r2, 5
	rjmp 	1f
	sts 	UDR0, r25
	ldi 	r21, 0
	out 	SREG, r4
	sei
	ret
	1: ; Busy
	ldi 	r21, 0x01
	out 	SREG, r4
	sei
	ret
	2: ; No write access
	ldi 	r21, 0x01
	out 	SREG, r4
	sei
	ret

; sys_call_uart_read_byte()
; return: r21 - the read byte, r22 - 0 on success, 1 on busy
sys_call_uart_read_byte:
	cli
	in 		r4, SREG
	lds 	r16, KERN_LOCK_UART ; Check if we have the UART locked
	lds 	r17, KERN_TASK_CURRENT
	cp 		r16, r17
	brne 	2f
	lds 	r2, UCSR0A
	sbrs 	r2, 7
	rjmp 	1f
	lds 	r21, UDR0
	ldi 	r22, 0x00
	out 	SREG, r4
	sei
	ret
	1: ; Busy
	clr 	r21
	ldi 	r22, 0x01
	out 	SREG, r4
	sei
	ret
	2: ; No write access
	clr 	r21
	ldi 	r22, 0x02
	out 	SREG, r4
	sei
	ret

;;;;;;;;;;;;;;;;;;;;
; Kernel Scheduler ;
;;;;;;;;;;;;;;;;;;;;

; Exit scheduler (here because braches can only jump 64 bytes)
1:
	out 	SREG, r6
	reti

; sys_schedule(): picks the next task to execute and allocates a time slice for that task.
; The scheduler does 3 main things: First it calculates the time elapsed since the last scheduler invocation
; and updates the global kernel clock. It will then update the timers of sleeping processes, waking them up
; if their time expires. The scheduler will then pick a task in a simple round-robin algorithm (i.e. pick the
; next non-sleeping task in the sequence). Finally, a context switch will be performed and the new task will
; execute for the hardcoded quantum. Implementation of simple concepts in assembly is lengthy as usual.
sys_schedule:
	in 		r6, SREG
	lds 	r16, KERN_SCHED_ENABLE
	cpi 	r16, 0x01
	brne 	1b
	mov 	r4, r30 ; Save Z pointer
	mov 	r5, r31
	in 	r18, SPL ; Switch to kernel stack
	in 	r19, SPH
	ldi 	r16, KERN_STACK_START
	ldi 	r17, 0x01
	out 	SPL, r16
	out 	SPH, r17
	push 	r18
	push 	r19
	push 	r0 ; save r0 and r1
	push 	r1
	push 	r6
	mov 	r6, r21 ; Update system clock
	eor 	r7, r7
	lds 	r16, KERN_SCHED_TASK_TIME ; Delta time
	lds 	r17, KERN_SCHED_TASK_TIME+1
	;lds 	r18, TCNT1L ; TODO: read timer without slowing the OS down massively
	;lds 	r19, TCNT1H
	;add 	r16, r18
	;adc 	r17, r19
	lds 	r18, KERN_CLOCK
	lds 	r19, KERN_CLOCK+1
	lds 	r20, KERN_CLOCK+2
	lds 	r21, KERN_CLOCK+3
	add 	r18, r16
	adc 	r19, r17
	adc 	r20, r7
	adc 	r21, r7
	mov 	r21, r6
	ldi 	r30, lo8(KERN_TASK_SLEEP_TABLE_START) ; Update sleep timers
	ldi 	r31, hi8(KERN_TASK_SLEEP_TABLE_START)
	eor 	r7, r7 ; Counter

	sys_schedule_sleep_timer_loop:
	ld 		r18, Z+
	ld 		r19, Z+
	cp 		r18, r16
	cpc 	r19, r17
	brlo 	sys_schedule_sleep_timer_loop_set_zero
	rjmp 	sys_schedule_sleep_timer_loop_subtract
	sys_schedule_sleep_timer_loop_set_zero:
	eor 	r18, r18
	eor 	r19, r19
	rjmp 	sys_schedule_sleep_timer_loop_set_end
	sys_schedule_sleep_timer_loop_subtract:
	sub 	r18, r16
	sbc 	r19, r17

	sys_schedule_sleep_timer_loop_set_end:
	eor 	r6, r6
	subi 	r30, 0x02
	sbc 	r31, r6
	st 		Z+, r18
	st 		Z+, r19
	ldi 	r20, KERN_MAX_TASKS
	inc 	r7
	cp 		r7, r20
	brne 	sys_schedule_sleep_timer_loop
	ldi 	r30, lo8(KERN_TASK_CURRENT) ; load current task pid
	ldi 	r31, hi8(KERN_TASK_CURRENT)
	ld 		r16, Z
	mov 	r2, r16 ; first argument for sys_task_swap()
	ldi 	r30, lo8(KERN_TASK_MAP) ; load task map
	ldi 	r31, hi8(KERN_TASK_MAP)
	ld 		r17, Z
	ldi 	r18, 0

	sys_schedule_shift_map: ; shifts the map so that bit 0 indicates the current task
	cp 		r18, r16
	breq 	sys_schedule_pid_loop
	inc 	r18
	lsr 	r17
	rjmp 	sys_schedule_shift_map

	sys_schedule_pid_loop: ; loop to find appropriate task to swap to
	inc 	r16 ; Next task to choose
	lsr 	r17 ; Shift task bitmap so bit 0 indicates whether the task exists or not
	cpi 	r16, KERN_MAX_TASKS ; must be less than max number of tasks
	brne 	sys_schedule_skip_pid_round ; pid is 0-7, no need to round
	eor 	r16, r16 ; Set target pid to 0
	ldi 	r30, lo8(KERN_TASK_MAP) ; load task map
	ldi 	r31, hi8(KERN_TASK_MAP)
	ld 		r17, Z ; reload task bitmap so that bit 0 is for pid 0
	sys_schedule_skip_pid_round:
	sbrs 	r17, 0 ; Check if task exists
	rjmp 	sys_schedule_pid_loop ; If not load the next task
	ldi 	r30, lo8(KERN_TASK_SLEEP_TABLE_START) ; Sleep table
	ldi 	r31, hi8(KERN_TASK_SLEEP_TABLE_START)
	ldi 	r20, 2 ; 2 bytes for a sleep table entry
	mul 	r16, r20
	add 	r30, r0
	adc 	r31, r1
	ldi 	r20, 0x00
	ld 		r18, Z+
	ld 		r19, Z+
	cp 		r18, r20
	cpc 	r19, r20
	brne 	sys_schedule_pid_loop ; Sleeping, continue on

	mov 	r3, r16 ; target task
	sts 	KERN_TASK_CURRENT, r3
	mov 	r30, r4 ; Restore Z pointer
	mov 	r31, r5
	ldi 	r16, 0x01
	out		TIFR1, r16 ; clear timer overflow
	ldi		r18, 0x00		; Schedule time to execute
	ldi		r19, 0xff
	sts		TCNT1L, r18		; Set the timer
	sts		TCNT1H, r19
	ldi		r18, 0xff		; Set task time
	ldi		r19, 0x00
	sts 	KERN_SCHED_TASK_TIME, r18
	sts 	KERN_SCHED_TASK_TIME+1, r19
	pop 	r6
	out 	SREG, r6
	pop 	r1 ; Restore r0 and r1
	pop 	r0
	pop 	r19 ; Restore user stack
	pop 	r18
	out 	SPL, r18
	out 	SPH, r19
	rjmp 	sys_task_swap   ; switch contexts and execute new task

; sys_task_exit(): Called when a program returns. Frees the PID from the system and reschedules
sys_task_exit:
	cli
	lds 	r16, KERN_LOCK_UART ; We must free the UART lock if this task owns it
	lds 	r17, KERN_TASK_CURRENT ; Load current task
	cp 		r16, r17
	brne 	3f
	ldi 	r16, 0x00
	sts 	KERN_LOCK_UART, r16
	3:
	lds 	r18, KERN_TASK_MAP ; Load task map
	clr 	r15 ; Counter
	ldi 	r16, 0x01 ; bit mask
	1:
	cp 		r15, r17
	breq 	2f
	lsl 	r16
	inc 	r15
	rjmp 	1b
	2:
	com 	r16 ; One's complement of bitmask
	and 	r18, r16 ; Clear PID bit in bitmask
	sts 	KERN_TASK_MAP, r18 ; Install new pid map
	rjmp 	sys_schedule ; Reschedule


; inputs: r2 is incoming PID, r3 is swap target
; sys_task_swap(u8 in, u8 out): stores current task state, loads new task state, and begins execution
sys_task_swap:
	in 		r9, SREG ; Save SREG
	pop 	r4 ; pop return address pushed by interupt
	pop 	r5
	mov 	r6, r30 ; save contents of Z pointer
	mov 	r7, r31
	ldi 	r30, lo8(KERN_TASK_STORE_START) ; compute offset of current task
	ldi 	r31, hi8(KERN_TASK_STORE_START)
	ldi 	r16, KERN_TASK_SIZE
	eor 	r8, r8
	mul 	r16, r2
	add 	r30, r0
	adc 	r31, r8
	st 		Z+, r21 ; Save registers
	st 		Z+, r22
	st 		Z+, r23
	st 		Z+, r24
	st 		Z+, r25
	st 		Z+, r26
	st 		Z+, r27
	st 		Z+, r28
	st 		Z+, r29
	st 		Z+, r6
	st 		Z+, r7
	in 		r16, SPH
	in 		r17, SPL
	st 		Z+, r16
	st 		Z+, r17
	st 		Z+, r5
	st 		Z+, r4
	st 		Z+, r9
	ldi 	r30, lo8(KERN_TASK_STORE_START) ; compute offset of outgoing task
	ldi 	r31, hi8(KERN_TASK_STORE_START)
	ldi 	r16, KERN_TASK_SIZE
	eor 	r8, r8
	mul 	r16, r3
	add 	r30, r0
	adc 	r31, r8
	ld 		r21, Z+ ; Restore registers
	ld 		r22, Z+ 
	ld 		r23, Z+ 
	ld 		r24, Z+ 
	ld 		r25, Z+ 
	ld 		r26, Z+ 
	ld 		r27, Z+ 
	ld 		r28, Z+ 
	ld 		r29, Z+ 
	ld 		r6, Z+ 
	ld 		r7, Z+
	ld 		r16, Z+
	ld 		r17, Z+
	out 	SPH, r16
	out 	SPL, r17
	ld 		r5, Z+
	ld 		r4, Z+
	ld 		r9, Z+
	nop
	mov 	r30, r6
	mov 	r31, r7
	push 	r5 ; push return address
	push 	r4
	out 	SREG, r9 ; Restore SREG
	reti 	; continue execution

; inputs: r3 is start target
; sys_task_start(u8 out): loads task state and begins execution
sys_task_start:
	ldi 	r30, lo8(KERN_TASK_STORE_START) ; compute offset of outgoing task
	ldi 	r31, hi8(KERN_TASK_STORE_START)
	ldi 	r16, KERN_TASK_SIZE
	eor 	r8, r8
	mul 	r16, r3
	add 	r30, r0
	adc 	r31, r8
	ld 		r21, Z+ ; Restore registers
	ld 		r22, Z+ 
	ld 		r23, Z+ 
	ld 		r24, Z+ 
	ld 		r25, Z+ 
	ld 		r26, Z+ 
	ld 		r27, Z+ 
	ld 		r28, Z+ 
	ld 		r29, Z+ 
	ld 		r6, Z+ 
	ld 		r7, Z+
	ld 		r16, Z+
	ld 		r17, Z+
	out 	SPH, r16
	out 	SPL, r17
	ld 		r5, Z+
	ld 		r4, Z+
	mov 	r30, r6
	mov 	r31, r7
	push 	r5 ; push return address
	push 	r4
	sei
	reti 	; continue execution

;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Standard user functions ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;

; std_print_flash(void* str): str pointer stored in Z pointer register (r30-r31)
std_print_flash: 			; Prints a string stored in flash
	push 	r21
	push 	r25
	1:
	lpm 	r25, Z+
	cpi 	r25, 0
	breq 	3f
	2:
	call 	sys_call_uart_write_byte
	cpi 	r21, 1
	breq 	2b
	cpi 	r21, 2
	breq 	2b
	rjmp 	1b
	3:
	pop 	r25
	pop 	r21
	ret

; std_write_char(): r25 - byte to write
std_write_char:
	push r21
	1:
	call 	sys_call_uart_write_byte
	cpi 	r21, 0
	brne 	1b
	pop 	r21
	ret

; std_get_char(): r21 - returned char
std_get_char:
	push 	r22
	1:
	call 	sys_call_uart_read_byte
	cpi 	r22, 0
	breq 	2f
	rjmp 	1b
	2:
	pop 	r22
	ret

; std_string_cmp(char *flstring, char* cmpstring): returns r21: 0 if equal, 1 if not
; flstring: string stored in flash to be compared. Passed in r30-r31
; cmpstring: string stored in memory. Passed in r28-r29
std_string_cmp:
	push 	r30 ; Save temp variables (6 bytes on stack)
	push 	r31
	push 	r28
	push 	r29
	push 	r27
	push 	r26
	eor 	r21, r21
	1: 			; loop
	lpm 	r26, Z+ ; Load flash
	ld 		r27, Y+ ; Load memory
	cp 		r26, r27 ; Comapare
	brne 	3f ; String mismatch, return
	cp 		r26, r21 ; Do both strings terminate?
	cpc 	r27, r21
	breq 	2f ; Strings are equal, return
	rjmp 	1b ; Compare next character
	2:
	ldi 	r21, 0x00
	rjmp 	4f
	3:
	ldi 	r21, 0x01
	rjmp 	4f
	4:
	pop 	r26 ; Restore values
	pop 	r27
	pop 	r29
	pop 	r28
	pop 	r31
	pop 	r30
	ret

; std_string_cmp_len(char *flstring, char* cmpstring, u8 len): returns r21: 0 if equal, 1 if not
; flstring: string stored in flash to be compared. Passed in r30-r31
; cmpstring: string stored in memory. Passed in r28-r29
; len: length of string to compare. Passed in r25
std_string_cmp_len:
	push 	r30 ; Save temp variables (6 bytes on stack)
	push 	r31
	push 	r28
	push 	r29
	push 	r27
	push 	r26
	eor 	r21, r21
	1: 			; loop
	inc 	r21 ; Increment counter
	lpm 	r26, Z+ ; Load flash
	ld 		r27, Y+ ; Load memory
	cp 		r26, r27 ; Comapare
	brne 	3f ; String mismatch, return
	cp 		r26, r21 ; Do both strings terminate?
	cpc 	r27, r21
	breq 	2f ; Strings are equal, return
	cp 		r21, r25 ; Are we at the string length?
	breq 	2f ; Equal up to length, return
	rjmp 	1b ; Compare next character
	2:
	ldi 	r21, 0x00
	rjmp 	4f
	3:
	ldi 	r21, 0x01
	rjmp 	4f
	4:
	pop 	r26 ; Restore values
	pop 	r27
	pop 	r29
	pop 	r28
	pop 	r31
	pop 	r30
	ret

; std_mem_cpy(void* dest, void* src, u8 length)
; dest: Destination in memory to copy to. Passed in r28-r29
; src: Source in memory to copy from. Passed in r30-r31
; length: number of bytes to copy. Passed in r25
std_mem_cpy:
	push 	r28 ; Save scratch registers
	push 	r29
	push 	r30
	push 	r31
	push 	r21
	push 	r22
	clr 	r21 ; Counter
	1: ; loop
	cp 		r21, r25
	breq	2f
	inc 	r21
	ld 		r22, Z+ ; Load from source
	st 		Y+, r22
	rjmp 	1b
	2: ; loop break
	pop 	r22 ; Restore scratch registers
	pop 	r21
	pop 	r31
	pop 	r30
	pop 	r29
	pop 	r28
	ret

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Blink: Program that just blinks the led ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

blink_entry:
	sbi		DDRB, 5			; Set the LED pin as an output
	sbi		PORTB, 5
	cbi		PORTB, 5

	blink_loop:
	ldi 	r25, 0xFF
	ldi 	r26, 0x2F
	rcall 	sys_call_sleep
	sbi		PORTB, 5
	ldi 	r25, 0xFF
	ldi 	r26, 0x2F
	rcall 	sys_call_sleep
	cbi		PORTB, 5
	rjmp 	blink_loop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Hello: Prints hello world and tests UART locking ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

hello_string: .asciz "Hello World!\r\n"
.align 2

hello_entry:
	call 	sys_call_uart_lock
	ldi 	r30, lo8(hello_string)
	ldi 	r31, hi8(hello_string)
	call 	std_print_flash
	call 	sys_call_uart_unlock
	1:
	;rjmp 	1b
	ret

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Shell: Main program to start commands ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.align 2
shell_str_prefix_string: .ascii "Arduino$ "
.byte 0

; Shell program lookup table: Stores the addresses of all the programs that can be run
shell_program_table:
.word blink_entry ; Program 0: blink
.word hello_entry ; Program 1: hello
.word pong_entry ; Program 2: pong

; Command table: ASCII strings for all the commands
shell_command_blink: .asciz "blink"
shell_command_hello: .asciz "hello"
shell_command_pong: .asciz "pong"

; Shell messages
shell_command_known: .asciz "Yay! Command known\r\n"
shell_command_unknown: .asciz "Uknown command\r\n"
shell_exec_fail: .asciz "Error: Could not start command\r\n"

.align 2

; Command string pointer table
shell_command_string_table:
.word shell_command_blink
.word shell_command_hello
.word shell_command_pong

SHELL_LINE_LENGTH = 15 ; max chars for a command
SHELL_COMMAND_COUNT = 3

SHELL_PS_TASK_COUNT = 0x0010
; The PS buffer stores the minimun stuff to identify a tast started by the shell
; The first byte is the PID of the shell and the second byte is the index into the string table
SHELL_PS_BUFFER_START = SHELL_PS_TASK_COUNT + 1
SHELL_PS_BUFFER_LEN = 16

; Internal commands strings
shell_itl_cmd_ps: .asciz "ps" ; Commamd to list all the processes
shell_itl_cmd_kill: .asciz "kill " ; Command to kill a process

.align 2

.text
shell_entry:
	; Allocate memory for this shell
	rcall 	sys_call_alloc
	mov 	r28, r30
	mov 	r29, r31

	; Init global variables
	ldi 	r21, 0x00
	ldi 	r30, lo8(SHELL_PS_TASK_COUNT)
	ldi 	r31, hi8(SHELL_PS_TASK_COUNT)
	add 	r30, r28
	adc 	r31, r29
	st 		Z, r21

	shell_loop:
	rcall 	shell_wait_cmd
	rcall 	shell_process_cmd
	rjmp 	shell_loop

shell_wait_cmd:
	ldi 	r30, lo8(shell_str_prefix_string) ; Print shell cmd imput
	ldi 	r31, hi8(shell_str_prefix_string)
	rcall 	std_print_flash
	mov 	r30, r28 ; Load our memory into the Z pointer
	mov 	r31, r29
	eor 	r27, r27 ; r27 is our character counter
	shell_wait_cmd_loop:
	rcall 	std_get_char ; Recieve a character
	cpi 	r21, 0x1b ; We don't like escape sequences very much
	breq 	shell_ecape_cmds
	mov 	r25, r21
	cpi 	r25, 0x0d ; Escape char?
	breq 	shell_wait_cmd_end
	cpi 	r25, 0x08 ; Backspace?
	breq 	shell_delete_cmd
	cpi 	r27, SHELL_LINE_LENGTH ; Are we at our limit?
	breq 	shell_wait_cmd_loop
	rcall 	std_write_char ; Send it back out
	st 		Z+, r25 ; Put it in our buffer
	inc 	r27
	rjmp 	shell_wait_cmd_loop

	shell_ecape_cmds:
	rcall 	std_get_char ; Eat up the rest of the sequence
	rcall 	std_get_char
	;rcall 	std_get_char
	rjmp 	shell_wait_cmd_loop

	shell_delete_cmd:
	cpi 	r27, 0x00 ; Any characters to delete?
	breq 	shell_wait_cmd_loop
	dec 	r27 ; -1 character
	rcall 	std_write_char
	ldi 	r25, 0x00
	subi 	r30, 1
	sbc 	r31, r25
	ldi 	r25, 0x1b ; escape
	rcall 	std_write_char
	ldi 	r25, '['
	rcall 	std_write_char
	ldi 	r25, '1'
	rcall 	std_write_char
	ldi 	r25, 'P'
	rcall 	std_write_char
	rjmp 	shell_wait_cmd_loop

	shell_wait_cmd_end: ; Input feeder
	rcall 	std_write_char
	ldi 	r25, 0x0a
	rcall 	std_write_char
	ldi 	r25, 0x00
	st 		Z+, r25
	ret

shell_command_vector_ps:
 	rjmp 	shell_command_ps
shell_command_vector_kill:
	rjmp 	shell_command_kill

shell_process_cmd:
	; r28 and r29 are assumed to be located at the start of our memory bank, which points to the command buffer

	; First off, try and see if the command matches an internal command, and jump to the appropriate place
	ldi 	r30, lo8(shell_itl_cmd_ps) ; ps command
	ldi 	r31, hi8(shell_itl_cmd_ps)
	rcall	std_string_cmp
	cpi 	r21, 0x00
	breq 	shell_command_vector_ps

	ldi 	r30, lo8(shell_itl_cmd_kill) ; kill command
	ldi 	r31, hi8(shell_itl_cmd_kill)
	ldi 	r25, 5 ; Load length of 'kill '
	rcall 	std_string_cmp_len
	cpi 	r21, 0x00
	breq 	shell_command_vector_kill

	ldi 	r30, lo8(shell_command_string_table) ; Load string table
	ldi 	r31, hi8(shell_command_string_table)
	eor 	r25, r25 ; Counter for string table entries

	1: ; let's go
	cpi 	r25, SHELL_COMMAND_COUNT ; Are we out of commands?
	breq 	4f ; Uknown command
	inc 	r25 ; Increment counter
	lpm 	r26, Z+ ; Load string pointer
	lpm 	r27, Z+
	push 	r30 ; Save Z pointer
	push 	r31
	mov 	r30, r26
	mov 	r31, r27
	rcall 	std_string_cmp
	pop 	r31 ; Restore Z
	pop 	r30
	cpi 	r21, 0x00 ; Are the strings equal?
	breq 	3f ; Yes, go to execution
	rjmp 	1b ; Lol nope, try again

	3: ; Command known
	push 	r28 ; Save our address
	push 	r29
	ldi 	r30, lo8(shell_program_table) ; Load program table
	ldi 	r31, hi8(shell_program_table)
	eor 	r24, r24 ; Need a 0 register
	dec 	r25 ; Counter needs to be decremented for correct offset
	lsl 	r25 ; multiply counter by two
	add 	r30, r25 ; Offset pointer to table
	adc 	r31, r24
	lpm 	r29, Z+ ; Load program address
	lpm 	r28, Z+
	mov 	r30, r28 ; Load address into Z pointer
	mov 	r31, r29  
	call 	sys_call_exec ; Execute
	cpi 	r21, 0xff
	pop 	r29 ; Restore
	pop 	r28 
	breq 	5f ; exec() error
	ldi 	r30, lo8(SHELL_PS_TASK_COUNT)
	ldi 	r31, hi8(SHELL_PS_TASK_COUNT)
	add 	r30, r28
	adc 	r31, r29
	ld  	r22, Z ; Get our task count
	inc 	r22 ; Increment it
	st 		Z, r22 ; Store it
	dec 	r22
	lsl 	r22 ; Multiply by two
	ldi 	r30, lo8(SHELL_PS_BUFFER_START) ; Load our PS buffer
	ldi 	r31, hi8(SHELL_PS_BUFFER_START)
	add 	r30, r22 ; Offset
	adc 	r31, r24
	add 	r30, r28 ; Base memory address
	adc 	r31, r29
	st 		Z+, r21 ; Store PID
	st 		Z+, r25 ; Offset into string table (command name)
	ret

	4: ; Command unknown
	ldi 	r30, lo8(shell_command_unknown)
	ldi 	r31, hi8(shell_command_unknown)
	call 	std_print_flash
	ret

	5: ; execution error
	ldi 	r30, lo8(shell_exec_fail)
	ldi 	r31, hi8(shell_exec_fail)
	call 	std_print_flash
	ret

; PS Strings
shell_command_ps_string_pid: .asciz "pid\r\n"
shell_command_ps_string_space: .asciz "     "
.align 2

shell_command_ps:
	ldi 	r30, lo8(SHELL_PS_TASK_COUNT)
	ldi 	r31, hi8(SHELL_PS_TASK_COUNT)
	add 	r30, r28
	adc 	r31, r29
	ld  	r22, Z ; Get our task count
	ldi 	r30, lo8(shell_command_ps_string_pid) ; Print PID
	ldi 	r31, hi8(shell_command_ps_string_pid)
	call 	std_print_flash
	ldi 	r30, lo8(SHELL_PS_BUFFER_START) ; Load up PS buffer
	ldi 	r31, hi8(SHELL_PS_BUFFER_START)
	add 	r30, r28 ; Offset
	adc 	r31, r29
	clr 	r24 ; Counter

	1:          ; Begin loop
	cp 		r24, r22 ; Compare task counts
	breq 	2f ; All tasks printed
	ld 		r25, Z+ ; Load PID
	ldi 	r26, '0'
	add 	r25, r26 ; Convert PID to text
	call 	std_write_char ; Print it
	ld 		r25, Z+ ; String index
	push 	r30 ; save Z temporarily
	push 	r31 
	ldi 	r30, lo8(shell_command_ps_string_space) ; Print spacing
	ldi 	r31, hi8(shell_command_ps_string_space)
	call 	std_print_flash
	ldi 	r30, lo8(shell_command_string_table) ; Load the string table
	ldi 	r31, hi8(shell_command_string_table)
	clr 	r23 ; Zero
	add 	r30, r25 ; Add offset
	adc 	r31, r23
	lpm 	r25, Z+ ; Load string pointer
	lpm 	r26, Z+
	mov 	r30, r25 ; Move into Z pointer
	mov 	r31, r26
	call 	std_print_flash ; Print
	pop 	r31 ; Restore Z
	pop 	r30
	ldi 	r25, '\r'      ; New line
	call 	std_write_char
	ldi 	r25, '\n'
	call 	std_write_char
	inc 	r24 ; Next index
	rjmp 	1b

	2:  		; End loop
	ret

shell_command_kill_string_inv_pid: .asciz "Invalid PID\r\n"
.align 2

shell_command_kill:
	mov 	r30, r28 ; Load buffer pointer
	mov 	r31, r29
	ldi 	r26, 5 ; characters to skip
	clr 	r25 ; zero register
	add 	r30, r26 ; Offset command buffer to pid
	adc 	r31, r25
	ld 		r21, Z ; Load PID
	subi 	r21, '0' ; Convert to binary
	cpi 	r21, 8
	brsh 	1f
	call 	sys_call_kill ; KILL IT!
	push 	r28 ; Save pointer to beginning memory bank
	push 	r29
	ldi 	r30, lo8(SHELL_PS_TASK_COUNT)
	ldi 	r31, hi8(SHELL_PS_TASK_COUNT)
	add 	r30, r28
	adc 	r31, r29
	ld  	r26, Z ; Load task count
	push 	r26 ; Save for later :)
	dec 	r26
	st 		Z, r26
	pop 	r26
	push 	r26
	ldi		r30, lo8(SHELL_PS_BUFFER_START) ; Load buffer start
	ldi 	r31, hi8(SHELL_PS_BUFFER_START)
	add 	r30, r28 ; Offset
	adc 	r31, r29
	clr 	r22 ; counter

	2: ; Loop to find PID
	inc 	r22
	ld 		r27, Z+ ; Load PID
	cp 		r27, r21
	breq 	3f ; Ar we teh winnerz?
	cp 		r22, r26 ; See if we are past the buffer to find the PID
	breq 	4f
	ld 		r27, Z+ ; that 2nd thing we don't really care about
	rjmp 	2b

	3: ; Loop break
	subi 	r30, 1 ; Subtract one from address
	sbc 	r31, r25
	mov 	r28, r30 ; Make them equal
	mov 	r29, r31
	ldi 	r21, 2 ; Add two to Z (which is the source to copy from)
	add 	r30, r21
	adc 	r31, r25
	pop 	r25 ; Load task count to calculate bytes to move
	lsl 	r25 ; multiply by two
	lsl 	r22 ; Multiply index into PS table by two
	sub 	r25, r22 ; Calc byte count
	rcall 	std_mem_cpy ; Copy the memory
	pop 	r29 ; Restore memory pointer
	pop 	r28
	ret

	4:
	pop 	r26 ; Pop some old stuff off the stack
	pop 	r29
	pop 	r28
	ldi 	r30, lo8(SHELL_PS_TASK_COUNT) ; Restore old task count
	ldi 	r31, hi8(SHELL_PS_TASK_COUNT)
	add 	r30, r28
	adc 	r31, r29
	ld  	r26, Z ; Load task count
	inc 	r26
	st 		Z, r26

	1:
	ldi 	r30, lo8(shell_command_kill_string_inv_pid)
	ldi 	r31, hi8(shell_command_kill_string_inv_pid)
	rcall 	std_print_flash
	ret

;;;;;;;;;;;;;;;;;;;;;
; Pong: Enough said ;
;;;;;;;;;;;;;;;;;;;;;
PONG_SCREEN_WIDTH = 80
PONG_SCREEN_HEIGHT = 18
PONG_TITLE_LOC_X = 40
PONG_TITLE_LOC_Y = 9

pong_str_pong: .asciz "PONG"
.align 2

pong_entry:
	rcall 	sys_call_uart_lock ; Lock the UART
	rcall 	pong_clear_display ; Clear display
	rcall 	pong_display_title ; Display title
	1:
	rjmp 	1b
	ret

; Sets the cursor: r21 is x, r22 is y
pong_cursor_pos:
	push 	r25
	ldi 	r25, 0x1b ; ESC
	rcall	std_write_char
	ldi 	r25, '['
	rcall 	std_write_char
	;mov 	r25, r22
	ldi 	r25, 9 + '0'
	rcall 	std_write_char
	ldi 	r25, ';'
	rcall 	std_write_char
	;mov 	r25, r21
	ldi 	r25, 9 + '0'
	rcall 	std_write_char
	ldi 	r25, 'H'
	rcall 	std_write_char
	pop 	r25
	ret

pong_display_title:
	ldi 	r21, PONG_TITLE_LOC_X
	ldi 	r22, PONG_TITLE_LOC_Y
	rcall 	pong_cursor_pos
	ldi 	r30, lo8(pong_str_pong)
	ldi 	r31, hi8(pong_str_pong)
	rcall 	std_print_flash
	ret

pong_clear_display:
	push 	r25
	ldi 	r25, 0x1b ; Clear the screen
	rcall	std_write_char
	ldi 	r25, '['
	rcall 	std_write_char
	ldi 	r25, '2'
	rcall 	std_write_char
	ldi 	r25, 'J'
	rcall 	std_write_char
	pop 	r25
	ret
