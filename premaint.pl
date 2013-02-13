#!/usr/bin/perl

use strict;
use warnings;

use Text::CSV_XS;
use Devel::Size qw(total_size);
use Time::HiRes qw(time);

use VMware::VIRuntime;
use SIG;

my %opts = (
    'vmname' => {
        type => "=s",
        help => "The name of the virtual machine",
        required => 0,
    },
    'guestos' => {
        type => "=s",
        help => "The guest OS running on virtual machine",
        required => 0,
    },
    'ipaddress' => {
        type => "=s",
        help => "The IP address of virtual machine",
        required => 0,
    },
    'toolsmounted' => {
        type     => "",
        help     => "VMware Tools mounted and installing",
        required => 0,
    },
    'datacenter' => {
        type     => "=s",
        variable => "datacenter",
        help     => "Name of the datacenter",
        required => 0,
    },
    'pool'  => {
        type     => "=s",
        variable => "pool",
        help     => "Name of the resource pool",
        required => 0,
    },
    'host' => {
        type      => "=s",
        variable  => "host",
        help      => "Name of the host" ,
        required => 0,
    },
    'folder' => {
        type      => "=s",
        variable  => "folder",
        help      => "Name of the folder" ,
        required => 0,
    },
    'powerstatus' => {
        type     => "=s",
        variable => "powerstatus",
        help     => "State of the virtual machine: poweredOn or poweredOff",
    },
#   'fields' => {
#      type => "=s",
#      help => "To specify vm properties for display",
#      required => 0,
#   },
    'out'=>{
        type => "=s",
        help => "The file name for storing the script output",
        required => 0,
    },
);

Opts::add_options(%opts);
Opts::parse();
Opts::validate(\&validate);

Util::connect();
doIt();
Util::disconnect();

#
# validate commandline options
#
sub validate {
    my $valid = 1;

    # validate output filename
    if (Opts::option_is_set('out')) {
        my $filename = Opts::get_option('out');
        if ((length($filename) == 0)) {
            Util::trace(0, "\n'$filename' Not Valid:\n$@\n");
            $valid = 0;
        } else {
            open(OUTFILE, ">$filename");
            if ((length($filename) == 0) || !(-e $filename && -r $filename && -T $filename)) {
                Util::trace(0, "\n'$filename' Not Valid:\n$@\n");
                $valid = 0;
            } else {
                #TODO
                #print OUTFILE "CSV COLUMN HEADERS GO HERE\n";
            }
        }
    }
    return $valid;
}

#
# this is where the magic happens
#
sub doIt {
    my %filter_hash = create_hash(Opts::get_option('ipaddress'),
        Opts::get_option('powerstatus'),
        Opts::get_option('guestos'),
        Opts::get_option('toolsmounted'));

    my ($start, $elapsed);
    $start = time();
    my $vm_views = SIG::AppUtil::VMUtil::get_vms_props('VirtualMachine',
        Opts::get_option ('vmname'),
        Opts::get_option ('datacenter'),
        Opts::get_option ('folder'),
        Opts::get_option ('pool'),
        Opts::get_option ('host'),
        \%filter_hash,
        ['name', 'guest']);
    $elapsed = time() - $start;

    printf("Total size of HostSystem (All Properties): %.2f KB in %.2fs\n", total_size($vm_views)/1024, $elapsed);

    if ($vm_views) {
        foreach (@$vm_views) {
            my $vm_view = $_;
            my ($vm_name, $vm_hostname, $vm_hwVersion, $vm_toolsStatus, $vm_toolsInstalling);
            $vm_name = $vm_view->get_property('name');
            if (defined ($vm_view->get_property('guest.hostName'))) {
                $vm_hostname = $vm_view->get_property('guest.hostName');
            } else {
                $vm_hostname = "unknown";
            }
            print_out($vm_name, $vm_hostname);
        }
    }
}

#
# print output to stdout or as csv
#
# accepts a scalar or an array
#
sub print_out($@) {
    if (@_ > 1) {
        if (defined (Opts::get_option('out'))) {
            #TODO
        } else {
            Util::trace(0, join(",", @_) . "\n");
        }
    } else {
        if (defined (Opts::get_option('out'))) {
            #TODO
        } else {
            Util::trace(0, shift(@_) . "\n");
        }
    }
}

#
# create hash for filtering by ip, guest os, power status, or VMware Tools
# installation state
#
# from VMware vminfo.pl
#
sub create_hash {
    my ($ipaddress, $powerstatus, $guestos, $toolsmounted) = @_;
    my %filter_hash;
    if ($ipaddress) {
        $filter_hash{'guest.ipAddress'} = $ipaddress;
    }
    if ($powerstatus) {
        $filter_hash{'runtime.powerState'} = $powerstatus;
    }
    # bug 299213
    if ($guestos) {
        # bug 456626
        $filter_hash{'config.guestFullName'} = qr/^\Q$guestos\E$/i;
    }
    if ($toolsmounted) {
        $filter_hash{'config.extraConfig["vmware.tools.installstate"]'} = "true";
    }
    return %filter_hash;
}

# disable SSL hostname verification for vCenter self-signed certificate
BEGIN {
    $ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;
}
