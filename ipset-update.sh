#!/bin/bash

# ipset-update.sh (C) 2012-2015 Matt Parnell http://www.mattparnell.com
# Licensed under the GNU-GPLv2+

# place to keep our cached blocklists
LISTDIR="/var/cache/blocklists"

# create cache directory for our lists if it isn't there
[ ! -d $LISTDIR ] && mkdir $LISTDIR

# countries to block, must be lcase
COUNTRIES=(af ae ir iq tr cn sa sy ru tw ua uz hk id kz kw ly vn zw)

# bluetack lists to use - they now obfuscate these so get them from
# https://www.iblocklist.com/lists.php
BLUETACKALIAS=(DShield Hijacked DROP ForumSpam WebExploit Ads Proxies BadSpiders CruzIT Malicious Malcode Adservers)
BLUETACK=(xpbqleszmajjesnzddhv usrcshglbiilevmyfhse zbdlwrqkabxbcppvrnos ficutxiwawokxlcyoeye ghlzqtqxnzctvvajwwag dgxtneitpuvgqqcpfulq xoebmbyexwuiogmbyprb mcvxsnihddgutbjfbghy czvaehmjpsnwwttrdoyl npkuuhuxcsllnhoamkvm pbqcylkejciyhmwttify zhogegszwduurnvsyhdf) 
# ports to block tor users from
PORTS=(80 443 6667 22 21)
DELETE_RULES=0

# enable bluetack lists?
ENABLE_BLUETACK=1

# enable country blocks?
ENABLE_COUNTRY=1

# enable tor blocks?
ENABLE_TORBLOCK=1

#cache a copy of the iptables rules
IPTABLES=$(iptables-save)

importList(){
	if [ -f $LISTDIR/$1.txt ] || [ -f $LISTDIR/$1.gz ]; then
		echo "Importing $1 blocks...using $2"

		ipset create -exist $1 hash:net maxelem 4294967295
		ipset create -exist $1-TMP hash:net maxelem 4294967295
		ipset flush $1-TMP &> /dev/null

	#the second param determines if we need to use zcat or not
		if [ $2 = 1 ]; then
			echo "unzipping $LISTDIR/$1.gz and creating list"
			zcat $LISTDIR/$1.gz | grep  -v \# | grep -v ^$ | grep -v 127\.0\.0 | pg2ipset - - $1-TMP | ipset restore
		else
			echo "parsing $LISTDIR/$1.txt with awk and creating list"
			awk '!x[$0]++' $LISTDIR/$1.txt | grep  -v \# | grep -v ^$ |  grep -v 127\.0\.0 | sed -e "s/^/add\ \-exist\ $1\-TMP\ /" | ipset restore
		fi
	
		ipset swap $1 $1-TMP &> /dev/null
		ipset destroy $1-TMP &> /dev/null
	
		# only create if the iptables rules don't already exist
		if ! echo $IPTABLES|grep -q "\-A\ INPUT\ \-m\ set\ \-\-match\-set\ $1\ src\ \-\j\ DROP"; then
			iptables -I INPUT -m set --match-set $1 src -j DROP
			iptables -I INPUT -m set --match-set $1 src -j LOG --log-prefix "[BLOCK-IPSET IN] $1 " --log-level 4
	
			iptables -I FORWARD -m set --match-set $1 src -j DROP
			iptables -I FORWARD -m set --match-set $1 src -j LOG --log-prefix "[BLOCK-IPSET FW] $1 " --log-level 4
	
			iptables -I OUTPUT -m set --match-set $1 src -j LOG --log-prefix "[BLOCK-IPSET OUT] $1 " --log-level 4
			iptables -I OUTPUT -m set --match-set $1 src -j DROP
	
			iptables -I FORWARD -m set --match-set $1 dst -j REJECT
			iptables -I FORWARD -m set --match-set $1 dst -j LOG --log-prefix "[BLOCK-IPSET FW] $1 " --log-level 4
	
			iptables -I OUTPUT -m set --match-set $1 dst -j REJECT
			iptables -I OUTPUT -m set --match-set $1 dst -j LOG --log-prefix "[BLOCK-IPSET OUT] $1 " --log-level 4
	
		else
			echo "iptables rules already exist - not updating"
		fi
	else
		echo "List $1.txt does not exist."
	fi
}


removeRule(){
	echo "Removing $1 blocks..."

	# only remove if the iptables rules already exist
	if echo $IPTABLES|grep -q "\-A\ INPUT\ \-m\ set\ \-\-match\-set\ $1\ src\ \-\j\ DROP"; then
		iptables -D INPUT -m set --match-set $1 src -j DROP || true
		iptables -D INPUT -m set --match-set $1 src -j LOG --log-prefix "[BLOCK-IPSET IN] $1 " --log-level 4 || true

		iptables -D FORWARD -m set --match-set $1 src -j DROP || true
		iptables -D FORWARD -m set --match-set $1 src -j LOG --log-prefix "[BLOCK-IPSET FW] $1 " --log-level 4 || true

		iptables -D OUTPUT -m set --match-set $1 src -j DROP || true
		iptables -D OUTPUT -m set --match-set $1 src -j LOG --log-prefix "[BLOCK-IPSET OUT] $1 " --log-level 4 || true

		iptables -D FORWARD -m set --match-set $1 dst -j REJECT || true
		iptables -D FORWARD -m set --match-set $1 dst -j LOG --log-prefix "[BLOCK-IPSET FW] $1 " --log-level 4 || true

		iptables -D OUTPUT -m set --match-set $1 dst -j REJECT || true
		iptables -D OUTPUT -m set --match-set $1 dst -j LOG --log-prefix "[BLOCK-IPSET OUT] $1 " --log-level 4 || true
	else
		echo "iptables rules don't exist - not removing"
	fi

	ipset destroy $1 &> /dev/null
}

updateLists() {
	if [ $ENABLE_BLUETACK = 1 ] && [ $DELETE_RULES = 0 ]; then
		# get, parse, and import the bluetack lists
		# they are special in that they are gz compressed and require
		# pg2ipset to be inserted
		i=0
		for list in ${BLUETACK[@]}; do  
			if [ eval $(wget --quiet -O /tmp/${BLUETACKALIAS[i]}.gz http://list.iblocklist.com/?list=$list&fileformat=p2p&archiveformat=gz) ]; then
				mv /tmp/${BLUETACKALIAS[i]}.gz $LISTDIR/${BLUETACKALIAS[i]}.gz
			else
				echo "Using cached list for ${BLUETACKALIAS[i]}."
			fi

			echo "Importing bluetack list ${BLUETACKALIAS[i]}..."

			importList ${BLUETACKALIAS[i]} 1

			i=$((i+1))
		done
	fi

	if [ $ENABLE_COUNTRY = 1 ] && [ $DELETE_RULES = 0 ]; then
		# get the country lists and cat them into a single file
		for country in ${COUNTRIES[@]}; do
			if [ eval $(wget --quiet -O /tmp/$country.txt http://www.ipdeny.com/ipblocks/data/countries/$country.zone) ]; then
				cat /tmp/$country.txt >> $LISTDIR/countries.txt
				rm /tmp/$country.txt
			fi
		done

		importList "countries" 0
	fi


	if [ $ENABLE_TORBLOCK = 1 ] && [ $DELETE_RULES = 0 ]; then
		# get the tor lists and cat them into a single file
		for ip in $(ip -4 -o addr | awk '!/^[0-9]*: ?lo|link\/ether/ {gsub("/", " "); print $4}'); do
			for port in ${PORTS[@]}; do
				if [ eval $(wget --quiet -O /tmp/$port.txt https://check.torproject.org/cgi-bin/TorBulkExitList.py?ip=$ip&port=$port) ]; then
					cat /tmp/$port.txt >> $LISTDIR/tor.txt
					rm /tmp/$port.txt
				fi
			done
		done 

		importList "tor" 0
	fi
}


removeLists() {
	if [ $ENABLE_BLUETACK = 1 ] && [ $DELETE_RULES = 1 ]; then
		i=0
		for list in ${BLUETACK[@]}; do  
			removeRule ${BLUETACKALIAS[i]} 1
			i=$((i+1))
		done
	fi

	if [ $ENABLE_COUNTRY = 1 ] && [ $DELETE_RULES = 1 ]; then
		removeRule "countries" 0
	fi


	if [ $ENABLE_TORBLOCK = 1 ] && [ $DELETE_RULES = 1 ]; then
		# get the tor lists and cat them into a single file
		removeRule "tor" 0
	fi
}

addExisting() {
	if [ $ENABLE_BLUETACK = 1 ] && [ $DELETE_RULES = 0 ]; then
		i=0
		for list in ${BLUETACK[@]}; do  
			importList ${BLUETACKALIAS[i]} 1
			i=$((i+1))
		done
	fi

	if [ $ENABLE_COUNTRY = 1 ] && [ $DELETE_RULES = 0 ]; then
		importList "countries" 0
	fi


	if [ $ENABLE_TORBLOCK = 1 ] && [ $DELETE_RULES = 0 ]; then
		# get the tor lists and cat them into a single file
		importList "tor" 0
	fi
}

case "$1" in
	remove)
	   DELETE_RULES=1
	   removeLists
	   ;;
	existing)
	   addExisting
	   ;;
	*)
	   # remove old countries list
           [ -f $LISTDIR/countries.txt ] && rm $LISTDIR/countries.txt

	   # remove the old tor node list
	   [ -f $LISTDIR/tor.txt ] && rm $LISTDIR/tor.txt
	
	   updateLists
	   ;;
esac
# add any custom import lists below
# ex: importTextList "custom"

