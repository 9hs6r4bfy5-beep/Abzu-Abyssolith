DESTDIR?=
PREFIX?=/usr/local
BINDIR=$(DESTDIR)$(PREFIX)/bin
SBINDIR=$(DESTDIR)$(PREFIX)/sbin
SHAREDIR=/usr/share/a2pi

BIN=a2joy a2joymou a2joypad a2mon a2term fusea2pi a2pidcmd dskread dskwrite bload brun nibread dskformat eddread
SBIN=a2pid

A2PIDEFS=-DSETSERCLK

# Use pkg-config for FUSE 3 flags. More portable than hardcoding
# -I/usr/include/fuse3 and -lfuse3. The .pc file is installed by fuse3-devel.
FUSE3_CFLAGS := $(shell pkg-config --cflags fuse3)
FUSE3_LIBS   := $(shell pkg-config --libs fuse3)

all: $(BIN) $(SBIN)

a2pid: a2pid.c gpclk.c
	$(CC) $(A2PIDEFS) a2pid.c -o a2pid

fusea2pi: fusea2pi.c a2lib.c
	@if [ -z "$(FUSE3_CFLAGS)" ]; then \
		echo "ERROR: pkg-config could not find fuse3." >&2; \
		echo "       Ensure 'fuse3-devel' and 'pkgconf-pkg-config' are installed." >&2 \
		exit 1; \
	fi
	$(CC) $(FUSE3_CFLAGS) -D_FILE_OFFSET_BITS=64 fusea2pi.c $(FUSE3_LIBS) -o fusea2pi

clean:
	-rm -f $(BIN) $(SBIN) *~ *.tar.gz

install:
	mkdir -p $(BINDIR)
	cp $(BIN) a2mount a2setvd $(BINDIR)
	mkdir -p $(SBINDIR)
	cp $(SBIN) $(SBINDIR)
	mkdir -p $(SHAREDIR)
	cp -R ../share/* $(SHAREDIR)
	-ln -s $(SHAREDIR)/A2PI-1.8.PO $(SHAREDIR)/A2VD1.PO
	-ln -s $(SHAREDIR)/UTILS.PO $(SHAREDIR)/A2VD2.PO

uninstall:
	cd $(BINDIR); rm -f $(BIN) a2mount a2setvd
	cd $(SBINDIR); rm -f $(SBIN)
