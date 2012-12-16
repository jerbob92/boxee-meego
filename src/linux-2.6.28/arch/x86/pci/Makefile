###################################################################
 
#Includes Intel Corporation's changes/modifications dated: 03/2009.
#Changed/modified portions - Copyright(c) 2009, Intel Corporation. 
#All rights reserved.

###################################################################

obj-y				:= i386.o init.o

obj-$(CONFIG_PCI_BIOS)		+= pcbios.o
obj-$(CONFIG_PCI_MMCONFIG)	+= mmconfig_$(BITS).o direct.o mmconfig-shared.o
obj-$(CONFIG_PCI_DIRECT)	+= direct.o
obj-$(CONFIG_PCI_OLPC)		+= olpc.o

obj-y				+= fixup.o
obj-$(CONFIG_ARCH_GEN3)         += intel_media_proc_gen3.o
obj-$(CONFIG_ACPI)		+= acpi.o
obj-y				+= legacy.o irq.o

obj-$(CONFIG_X86_VISWS)		+= visws.o

obj-$(CONFIG_X86_NUMAQ)		+= numaq_32.o

obj-y				+= common.o early.o
obj-y				+= amd_bus.o
