#!/bin/bash
# Author @cr4zyGoat (Xavier Oriol)


# Colours
declare -r turquoiseColour="\e[0;36m\033[1m"
declare -r blueColour="\e[0;34m\033[1m"
declare -r greenColour="\e[0;32m\033[1m"
declare -r yellowColour="\e[0;33m\033[1m"
declare -r redColour="\e[0;31m\033[1m"
declare -r endColour="\033[0m\e[0m"


# Global variables
declare -r nmap_file="nmap-output"
declare -r ldap_file="ldap-dump"
declare -r smb_folder="smb_loot"
declare -r ftp_folder="ftp_loot"

declare -i download_files=0

declare -i nmap_pid

declare -a tcp_ports=()
declare -a domains=()
declare -a users=()

declare target=""
declare username=""
declare password=""


# Function
function help {
    echo -e "\n${yellowColour}Usage: $0 [options] target
    Required arguments:
	target			    Address of the target to scan
    Optional arguments:
	-d, --domain		    Domain name
	-u, --username		    Username (Default: blank)
	-p, --password		    Password (Default: blank)
	-f, --download-files	    Download files from target (Default: no)
    ${endColour}"
    exit 1
}

function control_c {
    tput cnorm
    echo -e "${yellowColour}Exiting...${endColour}"
    exit 0
}

function check_dependencies {
    declare -a missing=()

    for dependency in $*; do
	if [[ -z $(which $dependency) ]] > /dev/null 2>&1; then
	    missing+=($dependency)
	fi
    done

    if [[ ${#missing[*]} -gt 0 ]]; then
	echo -e "${redColour}[!] Missing ${#missing[*]} dependencies: ${missing[*]}${endColour}"
        return 1
    else
	return 0
    fi
}

function check_os {
    declare -i ttl
    echo -e "\n${blueColour}Operative System according to the TTL...${endColour}"
    ttl=$(ping -c1 $target | grep -ioP 'ttl=\d{2,3}' | cut -d= -f2)
    echo -en "TTL=$ttl -> "
    if [[ $ttl -le 64 ]]; then
	echo "Linux/Unix"
    elif [[ $ttl -le 128 ]]; then
	echo "Windows"
    elif [[ $ttl -le 254 ]]; then
	echo "Solaris/AIX"
    else
	echo -e "${yellowColour}Unrecognized${endColour}"
    fi

}

function nmap_scan {
    echo -e "\n${blueColour}Scanning ports...${endColour}"
    declare ports=$(nmap -Pn --min-rate=5000 -p- $target | grep -iP '\d{0,5}/tcp' | tee /dev/tty)
    tcp_ports+=$(echo "$ports" | grep open | cut -d/ -f1 | xargs)
    echo -e "\n${turquoiseColour}Nmap complete scan in background, check the results in the file '$nmap_file'...${endColour}"
    nmap -Pn -sV --script "default or (vuln and safe)" -p$(echo ${tcp_ports[*]} | tr ' ' ',') -oN $nmap_file $target > /dev/null 2>&1 &
    nmap_pid=$!
}

function parse_nmap_results {
    domains+=($(grep -ioP '(commonName|Domain)[=:]\s*\w+\.\w+' $nmap_file | \
	while read line; do echo $line | awk -F'[=:]' '{print $NF}'; done | tr -d '[:blank:]' | sort -u | xargs))

    echo -e "\n${turquoiseColour}Domain names found:${endColour}"
    if [[ ${#domains[*]} -gt 0 ]]; then
	echo "${domains[*]}" | tr ' ' '\n'
    else
	echo -e "${yellowColour}No Domain names found${endColour}"
    fi
}

function scan_ports {
    declare ports=" ${tcp_ports[*]} "

    if (echo "$ports" | grep -P ' (21) ' > /dev/null); then scan_ftp; fi
    if (echo "$ports" | grep -P ' (80|443) ' > /dev/null); then scan_http; fi
    if (echo "$ports" | grep -P ' (135|593) ' > /dev/null); then scan_msrpc; fi
    if (echo "$ports" | grep -P ' (139|445) ' > /dev/null); then scan_smb; fi

    echo -e "\n${turquoiseColour}Waiting for complete nmap scan to finish...${endColour}"; wait $nmap_pid
    cat $nmap_file; unset nmap_pid
    parse_nmap_results

    if (echo "$ports" | grep -P ' (53) ' > /dev/null); then scan_dns; fi
    if (echo "$ports" | grep -P ' (389|636|3268|3269) ' > /dev/null); then scan_ldap; fi
}

function scan_ftp {
    echo -e "\n${blueColour}Scanning FTP service...${endColour}"
    if (check_dependencies ftp wget); then
	declare credentials="$([[ -n $username ]] && echo $username || echo 'anonymous') $([[ -n $password ]] && echo $password || echo 'anonymous')"
	declare output=$(echo -e "user $credentials" | ftp -n $target)
	if [[ -z $output ]]; then
	    echo -e "user $credentials \nls" | ftp -n $target
	    if [[ $download_files -gt 0 ]]; then
		echo -e "${turquoiseColour}Downloading files to folder '$ftp_folder'...${endColour}"
		wget -m -P $ftp_folder ftp://$target --user "$(echo $credentials | cut -d' ' -f1)" --password "$(echo $credentials | cut -d' ' -f2)" 2>/dev/null
	    fi
	else
	    echo -e "${yellowColour}Cannot connect to FTP with the credentials '$credentials'${endColour}"
	fi
    fi
}

function scan_dns {
    echo -en "\n${blueColour}Scanning Domain Name Server...${endColour}"
    if (check_dependencies dig); then
	dig axfr @$target
	for domain in ${domains[*]}; do
	    dig axfr @$target $domain
	done
    fi
}

function scan_http {
    echo -e "\n${blueColour}Scanning HTTP service...${endColour}"
    if (check_dependencies whatweb); then
	whatweb -a 3 $target
    fi

    echo -e "\n${turquoiseColour}Bruteforce with http-enum.nse script...${endColour}"
    nmap --script http-enum -p80 $target
}

function scan_msrpc {
    echo -e "\n${blueColour}Scanning MSRPC service...${endColour}"
    if (check_dependencies rpcclient); then
	declare rid=""
	declare output=""
	declare -a admins=()
	declare -a nodescription=()

	output=$(rpcclient -U '' -N $target -c 'enumdomusers' 2>/dev/null)
	if [[ $? -eq 0 ]]; then
	    users+=($(echo $output | grep -ioP '\[.*?\]' | grep -iv '0x' | tr -d '[]' | xargs))
	    
	    echo "Users with description:"
	    for user in ${users[*]}; do
		output=$(rpcclient -U '' -N $target -c  "queryuser $user")
		if (echo "$output" | grep -iP '^\s*Description\s*:\s*$' > /dev/null); then
		    nodescription+=($user)
		else
		    echo "$output" | grep -iP '^\s*(User Name|Description)'; echo ''
		fi
	    done
	    echo "Users without description: ${nodescription[*]}"

	    rpcclient -U '' -N $target -c 'enumdomgroups' | grep -i 'Admin' | while read group_line; do
		echo -en "\nUsers in group '$(echo $group_line | grep -ioP '\[.*?\]' | head -n1 | tr -d '[]')': "
		rpcclient -U '' -N $target -c "querygroupmem $(echo $group_line | grep -ioP '0x[0-9a-f]+')" | while read user_line; do
		    rid=$(echo "$user_line" | grep -ioP '0x[0-9a-f]+' | head -n1 )
		    output=$(rpcclient -U '' -N $target -c "queryuser $rid") 
		    if (echo "$output" | grep -i 'User Name' > /dev/null); then
			echo -n "$(echo "$output" | grep -i 'User Name' | cut -d: -f2 | xargs) "
		    else
			echo -n "$rid "
		    fi
		done
	    done; echo ''
	else
	    echo -e "${yellowColour}Cannont connect to MSRPC with user '$username' and password '$password'${endColour}"
	fi
    fi
}

function scan_smb {
    echo -e "\n${blueColour}Scanning SMB service...${endColour}"
    if (check_dependencies crackmapexec smbclient); then
	declare output=$(crackmapexec smb $target -u "$username" -p "$password" --shares 2>/dev/null | grep -iv 'KTHXBYE' | \
	    sed -r "s/[[:cntrl:]]\[[0-9]{1,3}m//g" | tee /dev/tty)

	if (echo $output | grep -i 'Enumerating shares' > /dev/null && [[ $download_files -gt 0 ]]); then
	    mkdir -p $smb_folder
	    echo -en "\n${turquoiseColour}Downloading SMB shares to folder '$smb_folder':${endColour}"
	    echo "$output" | tail +5 | grep READ | awk '{print $4}' | while read share; do
		smbclient -U '' --no-pass //$target/$share -Tc $smb_folder/${share}_files.tar > /dev/null 2>&1
		echo -n " $share"
	    done; echo ''
	else
	    echo -e "${yellowColour}Cannot connect to SMB with user '$username' and password '$password'${endColour}"
	fi
    fi
}

function scan_ldap {
    echo -e "\n${blueColour}Scanning LDAP service...${endColour}"
    if (check_dependencies ldapsearch); then
	cat /dev/null > $ldap_file
	for domain in ${domains[*]}; do
	    ldapsearch -x -h $target -D "$username" -w "$password" -b "$(echo $domain | awk -F. '{print "DC="$1",DC="$2}')" >> $ldap_file
	    echo -e "\n" >> $ldap_file
	done

	echo -e "${turquoiseColour}LDAP data dumped into file '$ldap_file'. Suspicious lines found:${endColour}"
	grep -iP '(userpas|pwd|password|secret)\w*:' $ldap_file | grep -viP '(LastSet|Count|Age|Length|Propert|History|Time)\w*:'
    fi
}


# Arguments parser
declare -i counter=0
declare params=""

while [[ $# -gt 0 ]]; do
    case $1 in 
	-h|--help) help;;
	-d|--domain) domains+=($2); shift 2;;
	-u|--username) username=$2; shift 2;;
	-p|--password) password=$2; shift 2;;
	-f|--download-files) download_files=1; shift;;
	*) params="$params $1"; counter+=1; shift;;
    esac
done

if [[ $counter -lt 1 ]]; then help; fi;
unset counter; eval set -- "$params"
target=$1


# Main program
tput civis
trap control_c SIGINT

if (! check_dependencies nmap); then
    echo -e "${redColour}[!] Nmap is needed. Please, install it to continue!${endColour}"
    tput cnorm
    exit 1
fi

check_os
nmap_scan
scan_ports

echo -e "\n${blueColour}Waiting for all the child processes...${endColour}"; wait
echo -e "\n${greenColour}Enjoy the results ;)${endColour}\n"
tput cnorm
