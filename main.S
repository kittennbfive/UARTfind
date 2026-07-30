#include <avr/io.h>

/*
firmware for UARTfind v0.4 Copyright (c) 2026 by kittennbfive
https://github.com/kittennbfive

AGPLv3+ and NO WARRANTY!

Please read the fine manual.
*/


//--- USER CONFIGURABLE DEFINES (can be overriden at runtime via UART) ---
#define NB_SAMPLES_DEFAULT 8
#define NB_MATCHES_MIN_DEFAULT 5
#define VOLTAGE_LEVEL_INDEX_DEFAULT 1 //1.1V

#define NB_SAMPLES_MAX 32 //for RAM memory allocation (bottom of file) - maximum 99 because of command parser (2 digits only, should be more than enough)

//this should be fine?
#define PER_VALUE_TIMEOUT 15625 //=50ms with prescaler 64 @20MHz


//--- INTERNAL DEFINES (do not change) ---
#define BAUD_VALUE 694 //for 115200 @20MHz
#define NB_DEFINED_BAUDRATES 14 //see constant data way below
#define VOLTAGE_LEVEL_INDEX_MAX 4 //by specification of Attiny402
#define RX_BUFFER_SZ 5 //for current command parser protocol
#define PIN_BUZZER 6 //PA6 = pin 2
#define FLAG_DO_PARSE_RX_bp 0 //inside GPIOR0, for current command parser protocol


//--- BASIC CHECKS ---
#if NB_MATCHES_MIN_DEFAULT>NB_SAMPLES_DEFAULT
#error "NB_MATCHES_MIN_DEFAULT must be smaller than NB_SAMPLES_DEFAULT"
#endif

#if VOLTAGE_LEVEL_INDEX_DEFAULT>VOLTAGE_LEVEL_INDEX_MAX
#error "VOLTAGE_LEVEL_INDEX_DEFAULT can be at most VOLTAGE_LEVEL_INDEX_MAX"
#endif

#if NB_SAMPLES_MAX>99
#error "NB_SAMPLES_MAX must be smaller than 100 due to command parser limitation"
#endif


//--- REGISTER ---
zero_reg=0 //r0, always 0
conf_nb_samples=1
conf_nb_matches_min=2
conf_voltage_level_index=3
rx_nb_bytes=4
measL=5
measH=6
val_maxL=7
val_maxH=8
val_minL=9
val_minH=10
last_found_index=11 //0xff means invalid / no UART found yet
temp=16
temp2=17
temp3=18
temp4=19
arg0=20
nb_samples=21
match_cnt=22
highest_match_cnt=23
index_highest_match=24
isr_flag_reset=25
//caution X-Y-Z starting at 26
//27:26 X -> used for UART RX (INT)
//29:28 Y -> samples
//31:30 Z -> sendstring, baudrates for check (lpm)


//--- CODE ---
.text

.global __vector_8 //TCA0 OVF

__vector_8:
	//timeout, reset
	//no need to save SREG here as none of the used instructions is messing with the flags
	sts TCA0_SINGLE_INTFLAGS, isr_flag_reset
	ldi YL, lo8(samples)
	ldi YH, hi8(samples)
	mov nb_samples, conf_nb_samples
	reti

.global __vector_22 //UART TXC

__vector_22:
	push temp
	in temp, SREG
	push temp
	push temp2
	lds temp, USART0_RXDATAL
	mov temp2, rx_nb_bytes
	cpi temp2, RX_BUFFER_SZ
	breq 4f //no space
	sbic GPIOR0, FLAG_DO_PARSE_RX_bp
	rjmp 4f //parsing of last command still todo
	cpi temp, 8 //backspace
	brne 1f
	tst temp2
	breq 1f //nothing in buffer
	dec temp2
	st -X, zero_reg //store something to decrement pointer to buffer!
	rjmp 3f
1:
	cpi temp, '\r'
	breq 1f
	cpi temp, '\n'
	brne 2f
1:
	sbi GPIOR0, FLAG_DO_PARSE_RX_bp //enter -> set flag
	rjmp 3f
2:
	st X+, temp
	inc temp2
	cpi temp2, RX_BUFFER_SZ
	brne 3f //buffer not full
	sbi GPIOR0, FLAG_DO_PARSE_RX_bp //buffer full -> set flag
3:
	mov rx_nb_bytes, temp2
4:
	pop temp2
	pop temp
	out SREG, temp
	pop temp
	reti

.global main

main:
	//clear r0 first to not forget it!
	clr zero_reg

	//unlock register for changing main clock prescaler
	ldi temp, 0xd8
	sts CPU_CCP, temp
	//disable prescaler -> full speed internal 20MHz oscillator
	sts CLKCTRL_MCLKCTRLB, zero_reg

	//prepare some registers
	ldi temp, NB_SAMPLES_DEFAULT
	mov conf_nb_samples, temp
	ldi temp, NB_MATCHES_MIN_DEFAULT
	mov conf_nb_matches_min, temp
	ldi temp, VOLTAGE_LEVEL_INDEX_DEFAULT
	mov conf_voltage_level_index, temp
	ser temp
	mov last_found_index, temp

	//prepare UART RX-buffer
	mov rx_nb_bytes, zero_reg
	out GPIOR0, zero_reg
	ldi XL, lo8(rx_buffer)
	ldi XH, hi8(rx_buffer)

	//relocate TxD, RxD
	ldi temp, (1<<PORTMUX_USART0_bp)
	sts PORTMUX_CTRLB, temp

	//enable pullup to be able to check for standalone mode below
	cbi VPORTA_DIR, 3 //needed!?
	ldi temp, (1<<PORT_PULLUPEN_bp)
	sts PORTA_PIN3CTRL, temp

	//buzzer/LED
	sbi VPORTA_DIR, PIN_BUZZER
	cbi VPORTA_OUT, PIN_BUZZER

	//config UART
	//set TxD to output and high as per datasheet
	sbi VPORTA_OUT, 1
	sbi VPORTA_DIR, 1
	//set baud
	ldi temp, lo8(BAUD_VALUE)
	sts USART0_BAUDL, temp
	ldi temp, hi8(BAUD_VALUE)
	sts USART0_BAUDH, temp
	//enable INT on RX
	ldi temp, (1<<USART_RXCIE_bp)
	sts USART0_CTRLA, temp
	//enable UART
	ldi temp, (1<<USART_RXEN_bp)|(1<<USART_TXEN_bp)
	sts USART0_CTRLB, temp

	//config TIMER A (TCA) for timeout
	ldi temp, lo8(PER_VALUE_TIMEOUT)
	sts TCA0_SINGLE_PERL, temp
	ldi temp, hi8(PER_VALUE_TIMEOUT)
	sts TCA0_SINGLE_PERH, temp
	//enable INT on overflow
	ldi temp, (1<<TCA_SINGLE_OVF_bp)
	sts TCA0_SINGLE_INTCTRL, temp
	//prescaler 64 and enable timer
	ldi temp, (5<<TCA_SINGLE_CLKSEL_gp)|(1<<TCA_SINGLE_ENABLE_bp)
	sts TCA0_SINGLE_CTRLA, temp

	//set voltage reference level
	rcall config_voltage_reference

	//config analog comparator
	//disable GPIO-function of AINP0 (PA7, pin 3) but enable pullup
	ldi temp, (1<<PORT_PULLUPEN_bp)|(4<<PORT_ISC_gp)
	sts PORTA_PIN7CTRL, temp
	//set AINP0 to PA7 (pin 3), AINN0 to voltage reference
	ldi temp, (2<<AC_MUXNEG_gp)
	sts AC0_MUXCTRLA, temp
	//enable
	ldi temp, (1<<AC_ENABLE_bp)
	sts AC0_CTRLA, temp

	//route output of analog comparator to input of TIMER B via Event System
	ldi temp, 3
	sts EVSYS_ASYNCUSER0, temp
	ldi temp, 0x03
	sts EVSYS_ASYNCCH0, temp

	//config TIMER B (TCB) for pulse width measurement
	//select Input Capture Pulse-Width Measurement mode
	ldi temp, (4<<TCB_CNTMODE_gp)
	sts TCB0_CTRLB, temp
	//enable input filter, invert edges, enable input
	ldi temp, (1<<TCB_FILTER_bp)|(1<<TCB_EDGE_bp)|(1<<TCB_CAPTEI_bp)
	sts TCB0_EVCTRL, temp
	//enable timer
	ldi temp, (1<<TCB_ENABLE_bp)
	sts TCB0_CTRLA, temp

	//print startup message
	ldi ZL, lo8(str_welcome_msg)
	ldi ZH, hi8(str_welcome_msg)
	rcall sendstring

	sei

//--- MAIN LOOP START ---

main_loop:
	ldi YL, lo8(samples)
	ldi YH, hi8(samples)
	mov nb_samples, conf_nb_samples
	//force restart of TIMER A (TCA)
	//caution: because of silicon bug this will reset counting direction to default = upwards, which is fine here
	ldi temp, (2<<TCA_SINGLE_CMD_gp)
	sts TCA0_SINGLE_CTRLESET, temp
	
record_loop:
	//if command received via UART parse it and restart
	sbis GPIOR0, FLAG_DO_PARSE_RX_bp
	rjmp 1f
	rcall parse_rx
	rjmp main_loop
1:
	//if value from TCB -> save it
	lds temp, TCB0_INTFLAGS
	sbrc temp, TCB_CAPT_bp
	rjmp save_record
	//force restart of TIMER A (TCA)
	//caution: because of silicon bug this will reset counting direction to default = upwards, which is fine here
	ldi temp, (2<<TCA_SINGLE_CMD_gp)
	sts TCA0_SINGLE_CTRLESET, temp
	rjmp record_loop

save_record:
	lds temp, TCB0_CCMPL
	st Y+, temp
	lds temp, TCB0_CCMPH
	st Y+, temp
	dec nb_samples
	brne record_loop //not enough samples yet -> go for another round

	//check received samples
	clr highest_match_cnt
	clr index_highest_match
	
	ldi ZL, lo8(baudrates)
	ldi ZH, hi8(baudrates)
	ldi temp, NB_DEFINED_BAUDRATES
	clr temp2
	
loop_baudrates:
	lpm val_maxL, Z+
	lpm val_maxH, Z+

	lpm val_minL, Z+
	lpm val_minH, Z+

	ldi YL, lo8(samples)
	ldi YH, hi8(samples)
	mov nb_samples, conf_nb_samples
	clr match_cnt
	
loop_samples:
	ld measL, Y+
	ld measH, Y+

	cp val_minL, measL
	cpc val_minH, measH
	brlo 1f

	cp measL, val_maxL
	cpc measH, val_maxH
	brlo 1f

	//match
	inc match_cnt
	
	1:
	dec nb_samples
	brne loop_samples

	cp highest_match_cnt, match_cnt
	brsh 1f

	mov highest_match_cnt, match_cnt
	mov index_highest_match, temp2

	1:
	inc temp2
	dec temp
	brne loop_baudrates

	//enough matches?
	cp highest_match_cnt, conf_nb_matches_min
	brlo main_loop

	//yes -> possible UART found -> send message with baudrate to user

	//save for recall via command interface
	mov last_found_index, index_highest_match
	
	ldi ZL, lo8(str_found1)
	ldi ZH, hi8(str_found1)
	rcall sendstring
	
	ldi ZL, lo8(baudrates_str)
	ldi ZH, hi8(baudrates_str)
	//add indexing/offset
	1:
	tst index_highest_match
	breq 1f
	adiw ZL, 8
	dec index_highest_match
	rjmp 1b
	1:
	rcall sendstring

	ldi ZL, lo8(str_found2)
	ldi ZH, hi8(str_found2)
	rcall sendstring

	mov arg0, highest_match_cnt
	rcall senddec8

	ldi arg0, '/'
	rcall sendchar

	mov arg0, conf_nb_samples
	rcall senddec8

	ldi ZL, lo8(str_found3)
	ldi ZH, hi8(str_found3)
	rcall sendstring

	rcall buzzer_ctrl

	rjmp main_loop


//--- SUBS ---

config_voltage_reference: //this is a sub so we can also call it from the command parser
	//VREF_DAC0REFSEL_gp is 0 so we can directly save conf_voltage_level_index
	sts VREF_CTRLA, conf_voltage_level_index
	ret

delay_short: //delay (uncalibrated), arg0 times
	push temp
	push temp2
	push temp3
	push arg0
4:
	ldi temp3, 2
3:
	ldi temp2, 255
2:
	ldi temp, 255
1:
	dec temp
	brne 1b
	dec temp2
	brne 2b
	dec temp3
	brne 3b
	dec arg0
	brne 4b
	pop arg0
	pop temp3
	pop temp2
	pop temp
	ret

buzzer_ctrl:
	push temp
	push arg0
	ldi arg0, 5
	sbi VPORTA_OUT, PIN_BUZZER
	rcall delay_short
	//check for standalone mode
	cbi VPORTA_OUT, PIN_BUZZER
	sbic VPORTA_IN, 3
	rjmp buzzer_ctrl_end //not standalone -> end
	//wait short before beeping out baudrate index
	ldi arg0, 5
	rcall delay_short
	//standalone mode: output index of found baudrate via buzzer (short beeps)
	mov temp, last_found_index
	inc temp //index 0 must beep once at least -> +1 (also this avoids underflow and 255 beeps for lowest baudrate...)
1:
	ldi arg0, 1
	sbi VPORTA_OUT, PIN_BUZZER
	rcall delay_short
	cbi VPORTA_OUT, PIN_BUZZER
	ldi arg0, 3
	rcall delay_short
	dec temp
	brne 1b	
buzzer_ctrl_end:
	pop arg0
	pop temp
	ret

sendchar: //arg0
	push temp
	1:
	lds temp, USART0_STATUS
	sbrs temp, USART_DREIF_bp
	rjmp 1b
	sts USART0_TXDATAL, arg0
	pop temp
	ret

sendnewline:
	push arg0
	ldi arg0, '\n'
	rcall sendchar
	pop arg0
	ret

sendstring: //r31:r30 == Z
	push arg0
	1:
	lpm arg0, Z+
	tst arg0
	breq 1f
	rcall sendchar
	rjmp 1b
	1:
	pop arg0
	ret

senddec8: //arg0, removes leading '0's - not pretty but works fine
	push temp
	push temp2
	clr temp2
	mov temp, arg0
	clr arg0
	1:
	cpi temp, 100
	brlo 2f
	subi temp, 100
	inc arg0
	rjmp 1b
	2:
	tst arg0
	breq 1f
	ldi temp2, 1
	subi arg0, -'0'
	rcall sendchar
	clr arg0
	1:
	cpi temp, 10
	brlo 2f
	subi temp, 10
	inc arg0
	rjmp 1b
	2:
	tst arg0
	brne 1f
	tst temp2
	brne 1f
	rjmp 2f
	1:
	subi arg0, -'0'
	rcall sendchar
	2:
	mov arg0, temp
	subi arg0, -'0'
	rcall sendchar
	pop temp2
	pop temp
	ret

parse_rx:
	push temp
	push temp2
	push temp3
	push temp4
	push ZL
	push ZH
	rcall sendnewline
	mov temp, rx_nb_bytes
	cpi temp, 2
	breq 1f
	cpi temp, 3
	breq 1f
	cpi temp, 4
	breq 1f
	rjmp parse_rx_invalid_command //invalid length
1:
	ldi XL, lo8(rx_buffer)
	ldi XH, hi8(rx_buffer)
	ld temp2, X+
	cpi temp2, '?'
	breq parse_rx_get
	cpi temp2, '!'
	breq parse_rx_set
	rjmp parse_rx_invalid_command

parse_rx_get:
	cpi temp, 2
	breq 1f
	rjmp parse_rx_invalid_command //invalid length for get
1:
	ld temp2, X+
	cpi temp2, 'i' //device identification
	brne 1f
	ldi ZL, lo8(msg_device_ident)
	ldi ZH, hi8(msg_device_ident)
	rcall sendstring
	rjmp parse_rx_end
1:
	cpi temp2, 's' //number of samples
	brne 1f
	ldi ZL, lo8(msg_nb_samples)
	ldi ZH, hi8(msg_nb_samples)
	rcall sendstring
	mov arg0, conf_nb_samples
	rcall senddec8
	rcall sendnewline
	rjmp parse_rx_end
1:
	cpi temp2, 'm' //minimum number of valid samples
	brne 1f
	ldi ZL, lo8(msg_min_valid_samples)
	ldi ZH, hi8(msg_min_valid_samples)
	rcall sendstring
	mov arg0, conf_nb_matches_min
	rcall senddec8
	rcall sendnewline
	rjmp parse_rx_end
1:
	cpi temp2, 'v' //voltage level index
	brne 1f
	ldi ZL, lo8(msg_voltage_level_index)
	ldi ZH, hi8(msg_voltage_level_index)
	rcall sendstring
	mov arg0, conf_voltage_level_index
	rcall senddec8
	rcall sendnewline
	rjmp parse_rx_end
1:	
	cpi temp2, 'f' //last found baudrate
	breq 1f
	rjmp parse_rx_invalid_command
1:
	ldi ZL, lo8(msg_last_found_baudrate)
	ldi ZH, hi8(msg_last_found_baudrate)
	rcall sendstring
	mov temp2, last_found_index
	cpi temp2, 0xff
	brne 1f
	ldi ZL, lo8(msg_no_uart_found)
	ldi ZH, hi8(msg_no_uart_found)
	rcall sendstring
	rjmp parse_rx_end
1:
	ldi ZL, lo8(baudrates_str)
	ldi ZH, hi8(baudrates_str)
	//add indexing/offset
1:
	tst temp2
	breq 1f
	adiw ZL, 8
	dec temp2
	rjmp 1b
1:
	rcall sendstring
	rcall sendnewline
	rjmp parse_rx_end

parse_rx_set:
	cpi temp, 3
	breq 1f
	cpi temp, 4
	brne parse_rx_invalid_command //invalid length for set
1:
	ld temp2, X+ //char
	ld temp3, X+ //new value low or high
	subi temp3, '0'
	cpi temp, 4
	brne 1f
	ld temp4, X+ //new value low if existing
	subi temp4, '0'
	//temp3=10*temp3+temp4
	push temp
	mov temp, temp3
	lsl temp3
	lsl temp3
	lsl temp3
	lsl temp
	add temp3, temp
	pop temp
	add temp3, temp4
1:
	cpi temp2, 's' //number of samples
	brne 2f
	tst temp3 //arg==zero?
	breq parse_rx_invalid_arg
	cpi temp3, NB_SAMPLES_MAX //for brlo argument order must be changed, not possible with cp*i*
	breq 1f //equal to NB_SAMPLES_MAX is fine
	brsh parse_rx_invalid_arg
1:
	mov conf_nb_samples, temp3
	cp conf_nb_matches_min, conf_nb_samples
	brlo 1f
	mov conf_nb_matches_min, conf_nb_samples
	ldi ZL, lo8(msg_nb_matches_min_adjusted)
	ldi ZH, hi8(msg_nb_matches_min_adjusted)
	rcall sendstring
1:
	rjmp parse_rx_set_ok
2:
	cpi temp2, 'm' //minimum number of valid samples
	brne 1f
	tst temp3 //arg==zero?
	breq parse_rx_invalid_arg
	cp conf_nb_samples, temp3
	breq parse_rx_invalid_arg
	mov conf_nb_matches_min, temp3
	rjmp parse_rx_set_ok
1:
	cpi temp2, 'v' //voltage level index
	brne parse_rx_invalid_command
	cpi temp3, 5
	brsh parse_rx_invalid_arg
	mov conf_voltage_level_index, temp3
	rcall config_voltage_reference
	
parse_rx_set_ok:
	ldi ZL, lo8(msg_new_value_set)
	ldi ZH, hi8(msg_new_value_set)
	rcall sendstring
	rjmp parse_rx_end
parse_rx_invalid_command:
	ldi ZL, lo8(msg_invalid_command)
	ldi ZH, hi8(msg_invalid_command)
	rcall sendstring
	rjmp parse_rx_end
parse_rx_invalid_arg:
	ldi ZL, lo8(msg_invalid_argument)
	ldi ZH, hi8(msg_invalid_argument)
	rcall sendstring
parse_rx_end:
	//reset whats needed
	mov rx_nb_bytes, zero_reg
	cbi GPIOR0, FLAG_DO_PARSE_RX_bp
	ldi XL, lo8(rx_buffer)
	ldi XH, hi8(rx_buffer)
	pop ZH
	pop ZL
	pop temp4
	pop temp3
	pop temp2
	pop temp
	ret

//--- CONSTANT DATA --- (in FLASH -> lpm!)

str_welcome_msg:
	.asciz "\nThis is UARTfind v0.4\nCopyright (c) 2026 by kittennbfive\nAGPLv3+ and NO WARRANTY\nhttps://github.com/kittennbfive\n\n"

//adjust NB_DEFINED_BAUDRATES if you add/remove something here!!
baudrates:
//300 Baud is too slow / timer would overflow
.short 32333, 34333 //600
.short 16166, 17166 //1200
.short 8083, 8583 //2400
.short 4041, 4291 //4800
.short 2018, 2142 //9600
.short 1011, 1073 //19200
.short 504, 536 //38400
.short 338, 358 //57600
.short 168, 179 //115200
.short 84, 89 //230400
.short 42, 45 //460800
.short 33, 36 //576000
.short 21, 22 //921600
.short 19, 21 //1M

//for indexing each entry must be exactly 8 bytes long including '\0'
baudrates_str:
.ascii "600\0\0\0\0\0"
.ascii "1200\0\0\0\0"
.ascii "2400\0\0\0\0"
.ascii "4800\0\0\0\0"
.ascii "9600\0\0\0\0"
.ascii "19200\0\0\0"
.ascii "38400\0\0\0"
.ascii "57600\0\0\0"
.ascii "115200\0\0"
.ascii "230400\0\0"
.ascii "460800\0\0"
.ascii "576000\0\0"
.ascii "921600\0\0"
.ascii "1000000\0"

str_found1:
.asciz "UART found: " //+"$baudrate"
str_found2:
.asciz " Baud (" //+"$a/$b"
str_found3:
.asciz " matches)\n"

//strings for command parser
msg_invalid_command:
	.asciz "invalid command\n"
msg_device_ident:
	.asciz "UARTfind v0.4 by kittennbfive\n"
msg_nb_samples:
	.asciz "number of samples: "
msg_min_valid_samples:
	.asciz "minimum number of valid samples: "
msg_voltage_level_index:
	.asciz "voltage level index: "
msg_last_found_baudrate:
	.asciz "last found baudrate: "
msg_no_uart_found:
	.asciz "(none)\n"
msg_invalid_argument:
	.asciz "invalid argument\n"
msg_new_value_set:
	.asciz "new value set\n"
msg_nb_matches_min_adjusted:
	.asciz "minimum number of valid samples adjusted to number of samples\n"

//--- SRAM ---

.data
.org 0

rx_buffer:
.zero RX_BUFFER_SZ

samples:
.zero (2*NB_SAMPLES_MAX) //each sample is 16 bits
