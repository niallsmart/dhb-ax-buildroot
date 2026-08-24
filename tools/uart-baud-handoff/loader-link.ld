ENTRY(loader_entry)

SECTIONS
{
	. = 0x83000000;
	.text : ALIGN(4)
	{
		KEEP(*(.text.entry))
		*(.text*)
		*(.rodata*)
	}

	. = 0x83003000;
	.params : ALIGN(4)
	{
		KEEP(*(.params))
	}

	/DISCARD/ :
	{
		*(.comment)
		*(.note*)
		*(.ARM.attributes)
		*(.ARM.exidx*)
		*(.ARM.extab*)
	}
}

ASSERT(ADDR(.text) + SIZEOF(.text) <= 0x83003000,
       "YMODEM-G loader overlaps its parameter record")
ASSERT(ADDR(.params) == 0x83003000,
       "YMODEM-G loader parameter record moved")
ASSERT(SIZEOF(.params) == 32,
       "YMODEM-G loader parameter record changed size")
