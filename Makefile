BINPATH = /Applications/Arduino.app/Contents/Resources/Java/hardware/tools/avr/bin
INCLUDEPATH = /Applications/Arduino.app/Contents/Resources/Java/hardware/tools/avr/avr/include
MCU_TARGET = atmega328p
LD_OPT = 

.PHONY: clean
.SUFFIXES: .S .a .o .hex
.SECONDARY:

.S.o:
	$(BINPATH)/avr-as -mmcu=$(MCU_TARGET) -a -I$(INCLUDEPATH) -o $@ $^ >$*.lst

.o.a:
	$(BINPATH)/avr-ld $(LD_OPT) -o $@ $^

.a.hex:
	$(BINPATH)/avr-objcopy -O ihex $^ $@

all: sys.hex

clean:
	rm *.o
	rm *.a
	rm *.hex
	rm *.lst

