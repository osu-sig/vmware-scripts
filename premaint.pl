#!/usr/bin/perl

use strict;
use warnings;

use Text::CSV_XS;
use Devel::Size qw(total_size);
use Time::HiRes qw(time);

use VMware::VIRuntime;
use SIG;

my $vmware_tool_versionfile = "vmtools_versions.txt";

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
    'out'=>{
        type => "=s",
        help => "The file name for storing the script output",
        required => 0,
    },
);

Opts::add_options(%opts);
Opts::parse();
Opts::validate();

my %toolsStatus = (
    'toolsNotInstalled' => 'not installed',
    'toolsNotRunning' => 'not running',
    'toolsOk' => 'up to date',
    'toolsOld' => 'out of date',
);

my %toolsVersions = get_tools_versions($vmware_tool_versionfile);

# open output file if necessary
my $out_fh;
if (Opts::option_is_set('out')) {
    my $filename = Opts::get_option('out');
    if ((length($filename) == 0)) {
        Util::trace(0, "\n'$filename' Not Valid:\n$@\n");
        die "$filename not valid\n";
    } else {
        open($out_fh, '>', $filename);
        if ((length($filename) == 0) || !(-e $filename && -r $filename && -T $filename)) {
            Util::trace(0, "\n'$filename' Not Valid:\n$@\n");
            die "$filename not valid\n";
        } 
    }
}

# prepare CSV output
my $csv;
if (Opts::option_is_set('out')) {
    $csv = Text::CSV_XS->new ({ binary => 1, eol => "\015\012" }) or die "Cannot open CSV: " . Text::CSV_XS->error_diag();
    $csv->print($out_fh, ['vmname','hostname','hardware version','vmware tools status','vmware tools version','vmware tools installation']);
}

Util::connect();
doIt();
Util::disconnect();


#
# this is where the magic happens
#
sub doIt {
    my %filter_hash = create_hash(Opts::get_option('ipaddress'),
        Opts::get_option('powerstatus'),
        Opts::get_option('guestos'));

    my ($start, $elapsed);
    $start = time();
    my $vm_views = SIG::AppUtil::VMUtil::get_vms_props('VirtualMachine',
        Opts::get_option ('vmname'),
        Opts::get_option ('datacenter'),
        Opts::get_option ('folder'),
        Opts::get_option ('pool'),
        Opts::get_option ('host'),
        \%filter_hash,
        ['name', 'guest', 'config.version', 'config.extraConfig["vmware.tools.installstate"]', 'guest.toolsStatus', 'guest.toolsVersion']);
    $elapsed = time() - $start;

    printf("Total size of HostSystem (All Properties): %.2f KB in %.2fs\n", total_size($vm_views)/1024, $elapsed);

    if ($vm_views) {
        foreach (@$vm_views) {
            my $vm_view = $_;
            my ($vm_name, $vm_hostname, $vm_hwVersion, $vm_toolsStatus, $vm_toolsStatusPretty, $vm_toolsVersion, $vm_toolsVersionPretty, $vm_toolsInstallState);

            # parse results
            $vm_name = $vm_view->get_property('name');
            #print Dumper $vm_name;
            if (defined ($vm_view->get_property('guest.hostName'))) {
                $vm_hostname = $vm_view->get_property('guest.hostName');
            } else {
                $vm_hostname = "unknown";
            }
            #print Dumper $vm_hostname;
            if (defined ($vm_view->get_property('config.version'))) {
                $vm_hwVersion = $vm_view->get_property('config.version');
            } else {
                $vm_hwVersion = "unknown";
            }
            #print Dumper $vm_hwVersion;
            if (defined ($vm_view->get_property('guest.toolsStatus'))) {
                my $vm_toolsStatusRaw = $vm_view->get_property('guest.toolsStatus');
                $vm_toolsStatus = $vm_toolsStatusRaw->val;
            } else {
                $vm_toolsStatus = "unknown";
            }
            $vm_toolsStatusPretty = $toolsStatus{$vm_toolsStatus};
            #print Dumper $vm_toolsStatus;
            if (defined ($vm_view->get_property('guest.toolsVersion'))) {
                $vm_toolsVersion = $vm_view->get_property('guest.toolsVersion');
            } else {
                $vm_toolsVersion = "unknown";
            }
            $vm_toolsVersionPretty = $toolsVersions{$vm_toolsVersion};
            #print Dumper $vm_toolsVersion;
            if (defined ($vm_view->get_property('config.extraConfig["vmware.tools.installstate"]'))) {
                my $vm_toolsInstallStateRaw = $vm_view->get_property('config.extraConfig["vmware.tools.installstate"]');
                $vm_toolsInstallState = $vm_toolsInstallStateRaw->value;
            } else {
                $vm_toolsInstallState = "unknown";
            }
            #print Dumper $vm_toolsInstallState;

            # check for toolsmounted option, and skip if the vm is not currently installing vmware tools
            if (defined (Opts::get_option('toolsmounted')) && $vm_toolsInstallState ne "initiated") {
                next;
            }
            
            if (defined (Opts::get_option('out'))) {
                $csv->bind_columns(\($vm_name, $vm_hostname, $vm_hwVersion, $vm_toolsStatusPretty, $vm_toolsVersionPretty, $vm_toolsInstallState));
                $csv->print($out_fh, undef);
            } else {
                print_out($vm_name, $vm_hostname, $vm_hwVersion, $vm_toolsStatusPretty, $vm_toolsVersionPretty, $vm_toolsInstallState);
            }
        }
    }
}

#
# print output to stdout
#
# accepts a scalar or an array
#
sub print_out($@) {
    if (@_ > 1) {
        Util::trace(0, join(",", @_) . "\n");
    } else {
        Util::trace(0, shift(@_) . "\n");
    }
}

#
# create hash for filtering by ip, guest os, or power status
#
# from VMware vminfo.pl
#
sub create_hash {
    my ($ipaddress, $powerstatus, $guestos) = @_;
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
    return %filter_hash;
}

#
# get VMware Tools versions from version file
#
sub get_tools_versions {
    my $versionfile = shift;
    my %version_hash;
    
    open(INPUTFILE, "<$versionfile") or die "error opening $versionfile: $!\n";
    my(@lines) = <INPUTFILE>;
    close(INPUTFILE);

    my($line, $version_num, $version_name);
    foreach $line (@lines) {
        next if substr($line, 0, 1) eq "#";
        ($version_num, $version_name) = split(/\s+/, $line);
        $version_hash{$version_num} = $version_name;
    }

    return %version_hash;
}

# disable SSL hostname verification for vCenter self-signed certificate
BEGIN {
    $ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;
}
