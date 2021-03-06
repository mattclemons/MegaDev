# Each Bro script must have a unique module name in order to be imported into other Bro scripts
module DNSBeacon;

# Imported module from Bro containing data structures used in DNS logs
@load base/protocols/dns

# These data structures can be referenced if this script is imported into another script
export {
    # Standard definition of custom log
    redef enum Log::ID += { LOG };
    
    # Custom data structure to store abnormal DNS event information
    type abnormalDnsRecord: record {
        # Unique ID for each type of abnormal event
        event_id: count &log &optional;
        # Unique name that directly maps to event_id
        event_name: string &log &optional;
        # The artifact that causes the abnormality
        # such as base64 string or reserved subnet in reply
        event_artifact: string &log &optional;
    };

    # Custom data structure to store metadata about abnormal DNS event
    type Info: record {
        ts: time &log;
        local_host: addr &log;
        remote_host: addr &log;
        abnormal: abnormalDnsRecord &log &optional;
    };

    # Redefines default DNS log entry to optionally append abnormal information if it exists
    redef record DNS::Info += {
        abnormal: abnormalDnsRecord &log &optional;
    };

}

# Whitelist of known benign subdomains or already blocked subdomains
global whitelist_domains: set[string] = {"naples", "arpa", "bluenet", "ssg"};

#Reference: https://en.wikipedia.org/wiki/Reserved_IP_addresses
# 10.0.0.0/8 and removed b/c local traffic = many false positives
global set_reserved_ipv4_subnets: set[subnet] = {0.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24,
192.88.99.0/24, 192.168.0.0/16, 192.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4, 255.255.255.255/32};

global reserved_ipv4_subnets = [0.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24,
192.88.99.0/24, 192.168.0.0/16, 192.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4, 255.255.255.255/32];
# fd00 removed b/c local traffic = many false positives
global reserved_ipv6_subnets = [[::1]/128, [::ffff:0:0]/96, [100::]/64, [64:ff9b::]/96, [2001::]/30, [2001:10::]/28, [2001:20::]/28, [2001:db8::]/32, [2002::]/16,
[fc00::]/8, [fe80::]/10, [ff00::]/8];

#A map of domain names to IPv4 addresses
global dn_record_store: table[string] of set[addr];

#A map of domain names to IPv6 addresses
global dn_aaaa_record_store: table[string] of set[addr];

# Standard procedure to initialize custom log names abnormal_dns.log
event bro_init()
{
    Log::create_stream(DNSBeacon::LOG, [$columns=Info, $path="abnormal_dns"]);
}

#Input: addr
#Output: subnet that corrosponds to the classiful network id
function get_class_network(a: addr): subnet {
	if(a < 128.0.0.0){ #Class A
		return a/8;
	}
	else if(a < 192.0.0.0){ #Class B
		if(a < 172.16.0.0 || a > 172.32.0.0) return a/16;
		else return a/12;
	}	
	else if(a < 224.0.0.0){
		if(a > 192.18.0.0 && a < 192.19.0.0) return a/15;
		else if(a > 192.168.0.0 && a < 192.169.0.0) return a/16;
		else return a/24; #Class C
	}
	else if(a < 240.0.0.0){ #Class D
		return a/4;
	}
	else if(a < 255.255.255.255){ #Class E
		return a/4;
	}
	else return a/32; #255.255.255.255
}

# Input: Vector of subdomains
# Output : True/False which indicates whether one of the subdomains is only 4 or more hexadecimal characters 
function check_hex_only_subdomain(subdomains: vector of string): bool {
    for (d in subdomains) {
        local subdomain = subdomains[d];
        # Check to see if subdomain is just three or more hex characters
        local patternMatchResult = match_pattern(subdomain, /[a-fA-F0-9]{4,}$/);
        if (patternMatchResult$matched) {
            return T;
        }
    }
    return F;
}

# Input: Vector of subdomains
# Output: True/False which indicates whether one of the subdomains is whitelisted
function whitelist_domain_check(subdomains: vector of string): bool {
    for(i in subdomains) {
        local subdomain_string = cat(subdomains[i]);
        if(subdomain_string in whitelist_domains) {
            return T;
        }
    }
    return F;
}

#Input: string representing domain name
#Output: the top three subdomains i.e. the root and two subdomains under it
#NOTE: will return 2 or less subdomains if the argument is less than 
#three subdomains 
function get_top_domains(dn: string): string {
	local dn_vector = split_string(dn, /\./);
	local ans = "";
	local index = |dn_vector|-1;
	if(index < 3) return dn;
	local cnt = 0;
	while(index >= 0 && cnt < 3){
		ans = dn_vector[index]+"."+ans; 
		index-=1;
		cnt+=1;	
	}
	return ans;
}

function push_ab_dns_log(c: connection, evnt_id: count, evnt_name: string, art: string){
	# Create abnormalDNSRecord 
	    local abnormalrecordinfo: DNSBeacon::abnormalDnsRecord = [$event_id = evnt_id, $event_name = evnt_name, $event_artifact = art];
        # Creates abnormalInfo record
            local dnsrecordinfo: DNSBeacon::Info = [$ts=c$start_time, $local_host=c$id$orig_h, $remote_host=c$id$resp_h, $abnormal=abnormalrecordinfo];
        # Write abnormalDNS record to its own log file
            Log::write(DNSBeacon::LOG, dnsrecordinfo);
            # Append abnormalDNS record to standard DNS log file
            c$dns$abnormal = abnormalrecordinfo;
} 

# DNS Request - Event IDs 40 to 59
# Input: DNS Request information
# Output: Log entries that indicate one (or more) of the following abnormal signatures was found:
#   - High number of subdomains
#   - Hexadecimal subdomain
event dns_request(c: connection, msg:dns_msg, query: string, qtype: count, qclass: count) {
    local event_id = 40;
    local subdomains = split_string(query, /\./);
    local whitelisted = whitelist_domain_check(subdomains);
    local base_domain = get_top_domains(query); #cat_sep(".", "", subdomains[|subdomains|-3], subdomains[|subdomains|-2], subdomains[|subdomains|-1]);
    # EVENT ID 45 - HIGH NUMBER OF SUBDOMAINS
    if ((|subdomains| > 4) && ! whitelisted) {
        # Reconstructs the subdomains to remove subdomains (i.e. foo.bar.xyz.cnn.org -> xyz.cnn.org )
        push_ab_dns_log(c, event_id+5, "High Number of Subdomains", query+"==>"+base_domain);
    }
    # EVENT ID 50 - HEXADECIMAL SUBDOMAIN
    if (check_hex_only_subdomain(subdomains) && ! whitelisted) {
        push_ab_dns_log(c, event_id+10, "Hexadecimal Subdomain", query+"==>"+base_domain);
	}
}

# EVENT ID 55 - A RECORD REPLY RESERVED IP ADDRESS
# Detects whether the IPv4 address is in reserved subnet
event dns_A_reply(c: connection, msg: dns_msg, ans: dns_answer, a: addr) {
    if(get_class_network(a) in set_reserved_ipv4_subnets) push_ab_dns_log(c,55,"A Record Reply Reserved IP Address",fmt("%s",a)); 
    local top = get_top_domains(ans$query);
    if(top in dn_record_store){
    	local top_set = dn_record_store[top]; 
	add top_set[a]; 
	if( |top_set| > 9) push_ab_dns_log(c, 57, fmt("A Record Reply that maps too many (%s) IPs to a subdomain", |top_set|),fmt(top+" ==> %s",a));
	dn_record_store[top]=top_set;     
	}
    else{
	dn_record_store[top] = set(a);	    
    }
}


# EVENT ID 65 - AAAA RECORD REPLY RESERVED IP ADDRESS
# Detects whether the IPv6 address is in reserved subnet
event dns_AAAA_reply(c: connection, msg: dns_msg, ans: dns_answer, a: addr) {
    for (cidr in reserved_ipv6_subnets) {
    	if (a in cidr) {
           push_ab_dns_log(c,65,"AAAA Record Reply Reserved IP Address",fmt("%s",a)); 
        }
    } 
    local top = get_top_domains(ans$query);
    if(top in dn_aaaa_record_store){
    	local top_set = dn_aaaa_record_store[top]; 
	add top_set[a]; 
	if( |top_set| > 9) push_ab_dns_log(c, 67, fmt("AAAA Record Reply that maps too many (%s) IPs to a subdomain", |top_set|),fmt(top+" ==> %s",a));
	dn_aaaa_record_store[top]=top_set;     
	}
    else{
	dn_aaaa_record_store[top] = set(a);	    
    }
    
}
