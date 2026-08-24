ENTRY(_start)

SECTIONS
{
	. = 0;
	.text : ALIGN(4)
	{
		KEEP(*(.text.entry))
	}

	/DISCARD/ :
	{
		*(.comment)
		*(.note*)
	}
}

ASSERT(SIZEOF(.text) <= 1024, "UART baud stub exceeds one YMODEM block")
