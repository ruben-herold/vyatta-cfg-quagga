#!/usr/bin/perl
#
# Module: vyatta-interfaces.pl
# 
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
# 
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# A copy of the GNU General Public License is available as
# `/usr/share/common-licenses/GPL' in the Debian GNU/Linux distribution
# or on the World Wide Web at `http://www.gnu.org/copyleft/gpl.html'.
# You can also obtain it by writing to the Free Software Foundation,
# Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
# MA 02110-1301, USA.
# 
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007 Vyatta, Inc.
# All Rights Reserved.
# 
# Author: Stig Thormodsrud
# Date: November 2007
# Description: Script to assign addresses to interfaces.
# 
# **** End License ****
#

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Config;
use Vyatta::Misc qw(generate_dhclient_intf_files
		    getInterfaces getIP get_sysfs_value
 		    is_address_enabled is_dhcp_enabled is_ip_v4_or_v6);
use Vyatta::Interface;

use Getopt::Long;
use POSIX;
use NetAddr::IP;
use Fcntl;

use strict;
use warnings;

my $dhcp_daemon = '/sbin/dhclient';

my ($eth_update, $eth_delete, $addr_set, @addr_commit, $dev, $mac, $mac_update);
my ($check_name, $show_names, $intf_cli_path, $vif_name, $warn_name);
my ($check_up, $show_path, $dhcp_command);
my @speed_duplex;

sub usage {
    print <<EOF;
Usage: $0 --dev=<interface> --check=<type>
       $0 --dev=<interface> --warn
       $0 --dev=<interface> --valid-mac=<aa:aa:aa:aa:aa:aa>
       $0 --dev=<interface> --eth-addr-update=<aa:aa:aa:aa:aa:aa>
       $0 --dev=<interface> --eth-addr-delete=<aa:aa:aa:aa:aa:aa>
       $0 --dev=<interface> --valid-addr-set={<a.b.c.d>|dhcp}
       $0 --dev=<interface> --valid-addr-commit={addr1 addr2 ...}
       $0 --dev=<interface> --speed-duplex=speed,duplex
       $0 --dev=<interface> --path
       $0 --dev=<interface> --isup
       $0 --show=<type>
EOF
    exit 1;
}

GetOptions("eth-addr-update=s" => \$eth_update,
	   "eth-addr-delete=s" => \$eth_delete,
	   "valid-addr=s"  => \$addr_set,
	   "valid-addr-set=s"  => \$addr_set,
	   "valid-addr-commit=s{,}" => \@addr_commit,
           "dev=s"             => \$dev,
	   "valid-mac=s"       => \$mac,
	   "set-mac=s"	       => \$mac_update,
	   "dhcp=s"	       => \$dhcp_command,
	   "check=s"	       => \$check_name,
	   "show=s"	       => \$show_names,
	   "vif=s"	       => \$vif_name,
	   "warn"	       => \$warn_name,
	   "path"	       => \$show_path,
	   "isup"	       => \$check_up,
	   "speed-duplex=s{2}" => \@speed_duplex,
) or usage();

update_eth_addrs($eth_update, $dev)	if ($eth_update);
delete_eth_addrs($eth_delete, $dev)	if ($eth_delete);
is_valid_addr_set($addr_set, $dev)	if ($addr_set);
is_valid_addr_commit($dev, @addr_commit) if (@addr_commit);
is_valid_mac($mac, $dev)		if ($mac);
update_mac($mac_update, $dev)		if ($mac_update);
dhcp($dhcp_command, $dev)	if ($dhcp_command);
is_valid_name($check_name, $dev)	if ($check_name);
exists_name($dev)			if ($warn_name);
show_interfaces($show_names)		if ($show_names);
show_config_path($dev)	       		if ($show_path);
is_up($dev)			        if ($check_up);
set_speed_duplex($dev, @speed_duplex)   if (@speed_duplex);
exit 0;

sub is_ip_configured {
    my ($intf, $ip) = @_;
    my $found = grep { $_ eq $ip } Vyatta::Misc::getIP($intf);
    return ($found > 0);
}

sub is_ip_duplicate {
    my ($intf, $ip) = @_;

    # get a map of all ipv4 and ipv6 addresses
    my %ipaddrs_hash = map { $_ => 1 } getIP();

    return unless($ipaddrs_hash{$ip});

    # allow dup if it's the same interface
    return !is_ip_configured($intf, $ip);
}

sub is_up {
    my $name = shift;
    my $intf = new Vyatta::Interface($name);
    
    die "Unknown interface type for $name" unless $intf;
    
    exit 0 if ($intf->up());
    exit 1;
}

sub touch {
    my $file = shift;
    my $t = time;

    sysopen (my $f, $file, O_RDWR|O_CREAT)
	or die "Can't touch $file: $!";
    close $f;
    utime $t, $t, $file;
}

sub dhcp_write_file {
    my ($file, $data) = @_;

    open(my $fh, '>', $file) || die "Couldn't open $file - $!";
    print $fh $data;
    close $fh;
}

sub dhcp_conf_header {
    my $output;

    my $date = `date`;
    chomp $date;
    $output  = "#\n# autogenerated by vyatta-interfaces.pl on $date\n#\n";
    return $output;
}

sub get_hostname {
    my $config = new Vyatta::Config;
    $config->setLevel("system");
    return $config->returnValue("host-name");
}

sub is_domain_name_set {
    my $config = new Vyatta::Config;
    $config->setLevel("system");
    return $config->returnValue("domain-name");
}

sub get_mtu {
    my $name = shift;
    my $intf = new Vyatta::Interface($name);
    return $intf->mtu();
}

sub dhcp_update_config {
    my ($conf_file, $intf) = @_;
    
    my $output = dhcp_conf_header();
    my $hostname = get_hostname();

    $output .= "interface \"$intf\" {\n";
    if (defined($hostname)) {
       $output .= "\tsend host-name \"$hostname\";\n";
    }
    $output .= "\trequest subnet-mask, broadcast-address, routers, domain-name-servers";
    my $domainname = is_domain_name_set();
    if (!defined($domainname)) {
       $output .= ", domain-name";
    } 

    my $mtu = get_mtu($intf);
    $output .= ", interface-mtu" unless $mtu;

    $output .= ";\n";
    $output .= "}\n\n";

    dhcp_write_file($conf_file, $output);
}

# Is interface disabled in configuration (only valid in config mode)
sub is_intf_disabled {
    my $name = shift;
    my $intf = new Vyatta::Interface($name);
    $intf or die "Unknown interface name/type: $name\n";

    my $config = new Vyatta::Config;
    $config->setLevel($intf->path());

    return $config->exists("disable");
}

sub run_dhclient {
    my $intf = shift;

    my ($intf_config_file, $intf_process_id_file, $intf_leases_file) 
	= generate_dhclient_intf_files($intf);
    dhcp_update_config($intf_config_file, $intf);

    return if is_intf_disabled($intf);

    my $cmd = "$dhcp_daemon -pf $intf_process_id_file -x $intf 2> /dev/null; rm -f $intf_process_id_file 2> /dev/null;";
    $cmd .= "$dhcp_daemon -q -nw -cf $intf_config_file -pf $intf_process_id_file  -lf $intf_leases_file $intf 2> /dev/null &";
    # adding & at the end to make the process into a daemon immediately
    system ($cmd) == 0
	or warn "start $dhcp_daemon failed: $?\n";
}

sub stop_dhclient {
    my $intf = shift;

    return if is_intf_disabled($intf);

    my ($intf_config_file, $intf_process_id_file, $intf_leases_file)
	= generate_dhclient_intf_files($intf);
    my $release_cmd = "$dhcp_daemon -q -cf $intf_config_file -pf $intf_process_id_file -lf $intf_leases_file -r $intf 2> /dev/null;";
    $release_cmd .= "rm -f $intf_process_id_file 2> /dev/null";
    system ($release_cmd) == 0
	or warn "stop $dhcp_daemon failed: $?\n";
}

sub update_eth_addrs {
    my ($addr, $intf) = @_;

    if ($addr eq "dhcp") {
	touch("/var/lib/dhcp3/$intf");
	run_dhclient($intf);
	return;
    } 
    my $version = is_ip_v4_or_v6($addr);
    die "Unknown address not IPV4 or IPV6" unless $version;

    if (is_ip_configured($intf, $addr)) {
	#
	# treat this as informational, don't fail
	#
	print "Address $addr already configured on $intf\n";
	exit 0;
    }

    if ($version == 4) {
	exec (qw(ip addr add),$addr,qw(broadcast + dev), $intf)
	    or die "ip addr command failed: $!";
    }
    if ($version == 6) {
	exec (qw(ip -6 addr add), $addr, 'dev', $intf)
	    or die "ip addr command failed: $!";
    }
    die "Error: Invalid address/prefix [$addr] for interface $intf\n";
}

sub delete_eth_addrs {
    my ($addr, $intf) = @_;

    if ($addr eq "dhcp") {
	stop_dhclient($intf);
	unlink("/var/lib/dhcp3/dhclient_$intf\_lease");
	unlink("/var/lib/dhcp3/$intf");
	unlink("/var/run/vyatta/dhclient/dhclient_release_$intf");
        unlink("/var/lib/dhcp3/dhclient_$intf\.conf");
	exit 0;
    } 
    my $version = is_ip_v4_or_v6($addr);
    if ($version == 6) {
	    exec 'ip', '-6', 'addr', 'del', $addr, 'dev', $intf
		or die "Could not exec ip?";
    }

    ($version == 4) or die "Bad ip version";

    if (is_ip_configured($intf, $addr)) {
	# Link is up, so just delete address
	# Zebra is watching for netlink events and will handle it
	exec 'ip', 'addr', 'del', $addr, 'dev', $intf
	    or die "Could not exec ip?";
    }
	
    exit 0;
}

sub update_mac {
    my ($mac, $intf) = @_;

    open my $fh, "<", "/sys/class/net/$intf/flags"
	or die "Error: $intf is not a network device\n";

    my $flags = <$fh>;
    chomp $flags;
    close $fh or die "Error: can't read state\n";

    if (POSIX::strtoul($flags) & 1) {
	# NB: Perl 5 system return value is bass-ackwards
	system "sudo ip link set $intf down"
	    and die "Could not set $intf down ($!)\n";
	system "sudo ip link set $intf address $mac"
	    and die "Could not set $intf address ($!)\n";
	system "sudo ip link set $intf up"
	    and die "Could not set $intf up ($!)\n";
    } else {
	system "sudo ip link set $intf address $mac"
	    and die "Could not set $intf address ($!)\n";
    }
    exit 0;
}
 
sub is_valid_mac {
    my ($mac, $intf) = @_;
    my @octets = split /:/, $mac;
    
    ($#octets == 5) or die "Error: wrong number of octets: $#octets\n";

    (($octets[0] & 1) == 0) or die "Error: $mac is a multicast address\n";

    my $sum = 0;
    $sum += strtoul('0x' . $_) foreach @octets;
    ( $sum != 0 ) or die "Error: zero is not a valid address\n";

    exit 0;
}

# Validate an address parameter at the time the user enters it via
# a "set" command.  This validates the parameter for syntax only.
# It does not validate it in combination with other parameters.
# Valid values are:  "dhcp", <ipv4-address>/<prefix-len>, or 
# <ipv6-address>/<prefix-len>
#
sub is_valid_addr_set {
    my ($addr_net, $intf) = @_;

    if ($addr_net eq "dhcp") { 
	if ($intf eq "lo") {
	    print "Error: can't use dhcp client on loopback interface\n";
	    exit 1;
	}
	exit 0; 
    }

    my ($addr, $net);
    if ($addr_net =~ m/^([0-9a-fA-F\.\:]+)\/(\d+)$/) {
	$addr = $1;
	$net  = $2;
    } else {
	exit 1;
    }

    my $version = is_ip_v4_or_v6($addr_net);
    if (!defined $version) {
	exit 1;
    }

    my $ip = NetAddr::IP->new($addr_net);
    my $network = $ip->network();
    my $bcast   = $ip->broadcast();
    
    if ($ip->version == 4 and $ip->masklen() == 31) {
       #
       # RFC3021 allows for /31 to treat both address as host addresses
       #
    } elsif ($ip->masklen() != $ip->bits()) {
       #
       # allow /32 for ivp4 and /128 for ipv6
       #
       if ($ip->addr() eq $network->addr()) {
          print "Can not assign network address as the IP address\n";
          exit 1;
       }
       if ($ip->addr() eq $bcast->addr()) {
          print "Can not assign broadcast address as the IP address\n";
          exit 1;
       }
    }

    if (is_ip_duplicate($intf, $addr_net)) {
	print "Error: duplicate address/prefix [$addr_net]\n";
	exit 1;
    }

    if ($version == 4) {
	if ($net > 0 && $net <= 32) {
	    exit 0;
	}
    } 
    if ($version == 6) {
	if ($net > 1 && $net <= 128) {
	    exit 0;
	}
    }

    exit 1;
}

# Validate the set of address values configured on an interface at commit
# time.  Syntax of address values is checked at set time, so is not
# checked here.  Instead, we check that full set of address address
# values are consistent.  The only rule that we enforce here is that
# one may not configure an interface with both a DHCP address and a static
# IPv4 address.
#
sub is_valid_addr_commit {
    my ($intf, @addrs) = @_;

    my $static_v4 = 0;
    my $dhcp = 0;

    foreach my $addr (@addrs) {
	if ($addr eq "dhcp") {
	    $dhcp = 1;
	} else {
	    my $version = is_ip_v4_or_v6($addr);
	    if ($version == 4) {
		$static_v4 = 1;
	    }
	}
    }

    if ($static_v4 == 1 && $dhcp == 1) {
	printf("Error configuring interface $intf: Can't configure static\n");
	printf("IPv4 address and DHCP on the same interface.\n");
	exit 1;
    }

    exit 0;
}

# Is interface currently in admin down state?
sub is_intf_down {
    my $name = shift;
    my $intf = new Vyatta::Interface($name);

    return 1 unless $intf;
    return ! $intf->up();
}

sub dhcp {
    my ($request, $intf) = @_;

    die "$intf is not using DHCP to get an IP address\n"
	unless is_dhcp_enabled($intf);
    
    die "$intf is disabled. Unable to release/renew lease\n"
	if is_intf_down($intf);

    my $tmp_dhclient_dir = '/var/run/vyatta/dhclient/';
    my $release_file = $tmp_dhclient_dir . 'dhclient_release_' . $intf;
    if ($request eq "release") {
	die "IP address for $intf has already been released.\n"
	    if (-e $release_file);

	print "Releasing DHCP lease on $intf ...\n";
	stop_dhclient($intf);
	mkdir ($tmp_dhclient_dir) if (! -d $tmp_dhclient_dir );
	touch ($release_file);
    } elsif ($request eq "renew") {
        print "Renewing DHCP lease on $intf ...\n";
        run_dhclient($intf);
	unlink ($release_file);
    } else {
	die "Unknown DHCP request: $request\n";
    }

    exit 0;
}

sub is_valid_name {
    my ($type, $name) = @_;
    die "Missing --dev argument\n" unless $name;

    my $intf = new Vyatta::Interface($name);
    die "$name does not match any known interface name type\n"
	unless $intf;
    die "$name is a ", $intf->type(), " interface not an $type interface\n"
	if ($type ne 'all' and $intf->type() ne $type);
    die "$type interface $name does not exist on system\n"
	unless grep { $name eq $_ } getInterfaces();
    exit 0;
}

sub exists_name {
    my $name = shift;
    die "Missing --dev argument\n" unless $name;

    warn "interface $name does not exist on system\n"
	unless grep { $name eq $_ } getInterfaces();
    exit 0;
}

# generate one line with all known interfaces (for allowed)
sub show_interfaces {
    my $type = shift;
    my @interfaces = getInterfaces();
    my @match;

    foreach my $name (@interfaces) {
	my $intf = new Vyatta::Interface($name);
	next unless $intf;		# skip unknown types
	next unless ($type eq 'all' || $type eq $intf->type());

	if ($vif_name) {
	    next unless $intf->vif();
	    push @match, $intf->vif()
		if ($vif_name eq $intf->physicalDevice());
	} else {
	    push @match, $name
		unless $intf->vif() and $type ne 'all';
	}
    }
    print join(' ', @match), "\n";
}

sub show_config_path {
    my $name = shift;
    die "Missing --dev argument\n" unless $name;
    my $intf = new Vyatta::Interface($name);
    die "$name does not match any known interface name type\n"
	unless $intf;
    my $level = $intf->path();
    $level =~ s/ /\//g;
    print "/opt/vyatta/config/active/$level\n";
}

sub get_ethtool {
    my $dev = shift;

    open( my $ethtool, "sudo /usr/sbin/ethtool $dev 2>/dev/null |" )
      or die "ethtool failed: $!\n";

    # ethtool produces:
    #
    # Settings for eth1:
    # Supported ports: [ TP ]
    # ...
    # Speed: 1000Mb/s
    # Duplex: Full
    # ...
    # Auto-negotiation: on
    my ($rate, $duplex, $autoneg);
    while (<$ethtool>) {
	chomp;
	if ( /^\s+Speed: ([0-9]+)Mb\/s|^\s+Speed: (Unknown)/ ) {
	    $rate = $1;
	} elsif ( /^\s+Duplex:\s(.*)$/ ) {
	    $duplex = lc $1;
        } elsif ( /^\s+Auto-negotiation: on/ ) {
	    $autoneg = 1;
	}
    }
    close $ethtool;
    return ($rate, $duplex, $autoneg);
}

sub set_speed_duplex {
    my ($intf, $nspeed, $nduplex) = @_;
    die "Missing --dev argument\n" unless $intf;

    my ($ospeed, $oduplex, $autoneg) = get_ethtool($intf);
    unless ($ospeed) {
	# Device does not support ethtool or does not report speed
	die "Device $intf does not support setting speed/duplex\n"
	    unless ($nspeed eq 'auto');
    } elsif ($autoneg) {
	# Device is in autonegotiation mode
	return if ($nspeed eq 'auto');
    } else {
	# Device has explicit speed/duplex
	return if (($nspeed eq $ospeed) && ($nduplex eq $oduplex));
    }

    my @cmd = ('sudo', 'ethtool', '-s', $intf );
    if ($nspeed eq 'auto') {
	push @cmd, qw(autoneg on);
    } else {
	push @cmd, 'speed', $nspeed, 'duplex', $nduplex, 'autoneg', 'off';
    }
    exec @cmd;

    die "Command failed: ", join(' ', @cmd);
}