#
# A Makefile for OS/2 Server
# (c) osFree project,
# author, date
#

# host operating system
# os2 linux win32
#

ARCH  = $(%env)
PROJ0 = main

!ifeq ARCH linux
EXE_SUF = l
!else
!ifeq ARCH win32
EXE_SUF = w
!else
!ifeq ARCH os2
EXE_SUF = p
!endif
!endif
!endif

PROJ = $(PROJ0)$(EXE_SUF)

DESC = OS/2 Personality Server
DEST = .
DIRS = Shared $(ARCH)
srcfiles = $(p)main$(e)
# defines additional options for C compiler

!include $(%ROOT)/mk/os2server.mk

TARGETS  = subdirs $(PATH)$(PROJ).exe
