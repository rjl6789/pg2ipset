all: build install

build:
	gcc -O3 -o pg2ipset pg2ipset.c

clean:
	rm pg2ipset

install:
	install pg2ipset /usr/local/bin/pg2ipset
	install ipset-update.sh /usr/local/bin/ipset-update
	cp -a 20-blocklist.conf /etc/rsyslog.d/20-blocklist.conf
