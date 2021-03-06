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
declare -r users_file="users.txt"
declare -r smb_folder="smb_loot"
declare -r ftp_folder="ftp_loot"

declare -a tcp_ports=()
declare -a domains=()
declare -a local_domain=()
declare -a users=()

declare -i nmap_pid
declare -i download_files=0

declare target=""
declare username=""
declare password=""


# Functions
function help {
    echo -e "\n${yellowColour}Usage: $0 [options] target
    Required arguments:
	target			    Address of the target to scan

    Optional arguments:
	-d, --domain		    Domain name
	-u, --username		    Username (Default: blank)
	-p, --password		    Password (Default: blank)
	-f, --download-files	    Download files from target (Default: no)

    Usage examples:
	$0 127.0.0.1
	$0 -u user -p pass 127.0.0.1
	$0 -f 127.0.0.1
    ${endColour}"
    exit 1
}

function control_c {
    tput cnorm
    echo -e "${yellowColour}Exiting...${endColour}\n"
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

function check_existing_files {
    declare -a existing=()

    for file in $nmap_file $ldap_file $users_file; do
	if [[ -e $file ]]; then existing+=($file); fi
    done

    for dir in $smb_folder $ftp_folder; do
	if [[ -d $dir ]]; then existing+=($dir); fi
    done

    if [[ ${#existing[*]} -gt 0 ]]; then
	echo -e "${yellowColour}[!] The following files or folders already exists: ${existing[*]}${endColour}"
	return 1
    else
	return 0
    fi
}

function delete_existing_files {
    rm -f $nmap_file $ldap_file $users_file
    rm -rf $smb_folder $ftp_folder
}

function check_os {
    declare -i ttl=0
    echo -e "\n${blueColour}Operative System according to the TTL...${endColour}"
    ttl=$(ping -c1 $target | grep -ioP 'ttl=\d{2,3}' | cut -d= -f2)
    echo -en "TTL=$ttl -> "
    if [[ $ttl -eq 0 ]]; then
	echo -e "${yellowColour}No PING received. Could the target be down?${endColour}"
    elif [[ $ttl -le 64 ]]; then
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
    tcp_ports+=($(echo "$ports" | grep open | cut -d/ -f1 | xargs))
    
    if [[ ${#tcp_ports[*]} -gt 0 ]]; then
	echo -e "\n${turquoiseColour}Nmap complete scan in background, check the results in the file '$nmap_file'...${endColour}"
	nmap -Pn -sV --script "default or (vuln and safe)" -p$(echo "${tcp_ports[*]}" | tr ' ' ',') -oN $nmap_file $target > /dev/null 2>&1 &
	nmap_pid=$!
    else
	echo -e "${redColour}[!] No open ports!${endColour}"
    fi
}

function parse_nmap_results {
    if [[ $nmap_pid ]]; then
	echo -e "\n${turquoiseColour}Waiting for complete nmap scan to finish...${endColour}"
	wait $nmap_pid; unset nmap_pid
    fi;

    domains+=($(grep -ioP '(commonName|Domain)[=:]\s*\w+\.\w+' $nmap_file | \
	while read line; do echo $line | awk -F'[=:]' '{print $NF}'; done | tr -d '[:blank:]' | sort -u | xargs))
    domains=($(echo "${domains[*]}" | tr ' ' '\n' | sort -u | xargs))
}

function print_domains {
    echo -e "\n${blueColour}Domain names found:${endColour}"
    if [[ ${#domains[*]} -gt 0 ]]; then
	echo "${domains[*]}" | tr ' ' '\n'
    else
	echo -e "${yellowColour}No Domain names found${endColour}"
    fi
}

function scan_ports {
    declare ports=" ${tcp_ports[*]} "

    if (echo "$ports" | grep -P ' (135|593) ' > /dev/null); then scan_msrpc; fi
    if (echo "$ports" | grep -P ' (139|445) ' > /dev/null); then scan_smb; fi
    if (echo "$ports" | grep -P ' (80|443) ' > /dev/null); then scan_http; fi
    if (echo "$ports" | grep -P ' (21) ' > /dev/null); then scan_ftp; fi
    if (echo "$ports" | grep -P ' (389|636|3268|3269) ' > /dev/null); then scan_ldap; fi

    if [[ -z $local_domain && ${#domains[*]} -eq 0 && $nmap_pid ]]; then parse_nmap_results; fi
    if (echo "$ports" | grep -P ' (88) ' > /dev/null); then scan_kerberos; fi

    if [[ $nmap_pid ]]; then parse_nmap_results; fi
    if (echo "$ports" | grep -P ' (53) ' > /dev/null); then scan_dns; fi
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
	declare output=$(dig axfr @$target | head -n -5 | tail -n +5);
	if [[ -n $output ]]; then echo -e "\n$output"; fi
	for domain in ${domains[*]}; do
	    output=$(dig axfr @$target $domain | head -n -5 | tail -n +5)
	    if [[ -n $output ]]; then echo -e "\n$output"; fi
	done
    fi
}

function scan_http {
    echo -e "\n${blueColour}Scanning HTTP service...${endColour}"
    if (check_dependencies whatweb); then
	whatweb -a 3 $target
    fi

    echo -e "\n${turquoiseColour}Bruteforce with http-enum.nse script...${endColour}"
    nmap --script http-enum -p80 $target | head -n -2 | tail -n +6
}

function scan_msrpc {
    echo -e "\n${blueColour}Scanning MSRPC service...${endColour}"
    if (check_dependencies rpcclient); then
	declare rid=""
	declare output=""
	declare -a admins=()
	declare -a nodescription=()
	declare credentials="${username}%${password}"

	if (rpcclient -U $credentials $target -c 'quit' 2>/dev/null); then
	    output=$(rpcclient -U $credentials $target -c 'enumdomusers' 2>/dev/null)
	    users+=($(echo $output | grep -ioP '\[.*?\]' | grep -iv '0x' | tr -d '[]' | xargs))
	    users=($(echo ${users[*]} | tr ' ' '\n' | sort -u | xargs))
	    echo "${users[*]}" | tr ' ' '\n' > $users_file
	    
	    echo "Users with description:"
	    for user in ${users[*]}; do
		output=$(rpcclient -U $credentials $target -c  "queryuser $user")
		if (echo "$output" | grep -iP '^\s*Description\s*:\s*$' > /dev/null); then
		    nodescription+=($user)
		else
		    echo "$output" | grep -iP '^\s*(User Name|Description)'; echo ''
		fi
	    done
	    echo "Users without description: ${nodescription[*]}"

	    rpcclient -U $credentials $target -c 'enumdomgroups' | grep -i 'Admin' | while read group_line; do
		echo -en "\nUsers in group '$(echo $group_line | grep -ioP '\[.*?\]' | head -n1 | tr -d '[]')': "
		rpcclient -U $credentials $target -c "querygroupmem $(echo $group_line | grep -ioP '0x[0-9a-f]+')" | while read user_line; do
		    rid=$(echo "$user_line" | grep -ioP '0x[0-9a-f]+' | head -n1 )
		    output=$(rpcclient -U $credentials $target -c "queryuser $rid") 
		    if (echo "$output" | grep -i 'User Name' > /dev/null); then
			echo -n "$(echo "$output" | grep -i 'User Name' | cut -d: -f2 | xargs) "
		    else
			echo -n "$rid "
		    fi
		done
	    done; echo ''

	    if [[ -z $local_domain ]]; then
		local_domain=$(rpcclient -U $credentials $target -c "enumdomains" 2>/dev/null | grep -oP '\[.*?\]' | head -n1 | tr -d '[]')
	    fi; echo -e "\nLocal domain: $local_domain"
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
	if [[ -z $local_domain ]]; then local_domain=$(echo "$output" | grep -ioP 'domain:\w+' | cut -d: -f2); fi

	if (echo "$output" | grep -i 'Enumerating shares' > /dev/null); then
	    if [[ $download_files -gt 0 ]]; then
		mkdir -p $smb_folder
		echo -en "\n${turquoiseColour}Downloading SMB shares to folder '$smb_folder':${endColour}"
		echo "$output" | tail +5 | grep READ | awk '{print $4}' | while read share; do
		    smbclient -U '' --no-pass //$target/$share -Tc $smb_folder/${share}_files.tar > /dev/null 2>&1
		    echo -n " $share"
		done; echo ''
	    fi
	else
	    echo -e "${yellowColour}Cannot connect to SMB with user '$username' and password '$password'${endColour}"
	fi
    fi
}

function scan_ldap {
    echo -e "\n${blueColour}Scanning LDAP service...${endColour}"
    if (check_dependencies ldapsearch); then
	declare domain=$(ldapsearch -LLL -x -H ldap://$target -b '' -s base '(objectclass=*)' | grep -i 'ldapServiceName' | cut -d: -f2 | xargs)
	domains=($(echo "${domains[*]} $domain" | tr ' ' '\n' | sort -u | xargs))

	ldapsearch -x -h $target -D "$username" -w "$password" -b "$(echo $domain | awk -F. '{print "DC="$1",DC="$2}')" > $ldap_file
	echo -e "${turquoiseColour}LDAP data dumped into file '$ldap_file'. Suspicious lines found:${endColour}"
	grep -iP '(userpas|pwd|password|secret)\w*:' $ldap_file | grep -viP '(LastSet|Count|Age|Length|Propert|History|Time)\w*:'
    fi
}

function scan_kerberos {
    echo -e "\n${blueColour}Scanning Kerberos...${endColour}"
    if (check_dependencies GetNPUsers.py); then
	declare domain="$local_domain"; if [[ -z $domain ]]; then domain=$(echo "${domains[0]}" | cut -d. -f1); fi
	declare credentials="$username"; if [[ -n $password ]]; then credentials="$credentials:$password"; fi

	if [[ -n $domain ]]; then
	    if [[ -e $users_file ]]; then
		GetNPUsers.py -request -usersfile $users_file -dc-ip $target $domain/$credentials | tail -n +3
	    else
		echo -e "${yellowColour}No users file available...${endColour}"
		GetNPUsers.py -dc-ip $target $domain/$credentials | tail -n +3
	    fi
	else
	    echo -e "${yellowColour}No domain found so far, so kerberos service cannot be analyzed...${endColour}"
	fi
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
    echo -e "${redColour}[!] Nmap is needed. Please, install it to continue!${endColour}\n"
    tput cnorm; exit 1
fi

if (! check_existing_files); then
    declare answer=""; tput cnorm
    while [[ ! $answer =~ [Yy][Ee]?[Ss]? ]]; do
	read -p 'The existing files will be deleted. Do you want to continue anyway (Yes|No)? ' answer
	if [[ $answer =~ [Nn][Oo]? ]]; then echo ''; exit 0; fi
    done; tput civis
    delete_existing_files
fi

check_os
nmap_scan
if [[ ${#tcp_ports[*]} -eq 0 ]]; then
    echo -e "\n${yellowColour}Nothing else to scan... exiting...${endColour}\n"
    tput cnorm; exit 0
fi
scan_ports

if [[ $nmap_pid ]]; then parse_nmap_results; fi
echo -e "\n${blueColour}This is the Nmap complete scan output:${endColour}"
head -n -3 $nmap_file | tail -n +5

echo -e "\n${turquoiseColour}Waiting for all the child processes...${endColour}"; wait
echo -e "\n${greenColour}Enjoy the results ;)${endColour}\n"
tput cnorm
