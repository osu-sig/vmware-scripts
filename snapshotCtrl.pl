#!/usr/bin/perl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use Text::CSV_XS;
use Date::Format;
use Date::Parse;
use Devel::Size qw(total_size);
use Time::HiRes qw(time);
use Data::Dumper;

use VMware::VIRuntime;
use SIG;

my %opts = (
    'vmname' => {
        type => "=s",
        variable => "vmname",
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
    'datesort'=>{
        type => "=s",
        help => "Sort by date and time: asc or desc",
        required => 0,
    },
);


Opts::add_options(%opts);
Opts::parse();
Opts::validate();

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
    $csv->print($out_fh, ['vm name','snapshot name','created time']);
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
        ['name', 'guest', 'snapshot']);

    $elapsed = time() - $start;
    #printf("Total size of HostSystem (All Properties): %.2f KB in %.2fs\n", total_size($vm_views)/1024, $elapsed);

    my @snapshots;

    if ($vm_views) {
        foreach (@$vm_views) {
            my $vm_view = $_;
            my ($vm_name, $vm_hostname);

            $vm_name = $vm_view->get_property('name');
            if (defined ($vm_view->get_property('guest.hostName'))) {
                $vm_hostname = $vm_view->get_property('guest.hostName');
            } else {
                $vm_hostname = "unknown";
            }

            if (defined $vm_view->snapshot) {
                get_snapshots($vm_view->snapshot->currentSnapshot, $_->snapshot->rootSnapshotList, $vm_name, \@snapshots);
            }
        }

        #print Dumper @snapshots;
        my @sorted;
        if (defined (Opts::get_option('datesort'))) {
            if (Opts::get_option('datesort') eq 'desc') {
                @sorted = sort {((lc $a->[0] cmp lc $b->[0]) || ($b->[2] cmp $a->[2]))} @snapshots;
            } else {
                @sorted = sort {((lc $a->[0] cmp lc $b->[0]) || ($a->[2] cmp $b->[2]))} @snapshots;
            }
        } else {
            @sorted = sort {((lc $a->[0] cmp lc $b->[0]) || ($a->[2] cmp $b->[2]))} @snapshots;
        }
        @snapshots = @sorted;

        #print Dumper @snapshots;

        foreach my $snap (@snapshots) {
            my $tmptime = str2time @$snap[2];
            my @tmpt = gmtime($tmptime);
            @$snap[2] = strftime("%Y-%m-%d %H:%M:%S", @tmpt);
            if (defined (Opts::get_option('out'))) {
                $csv->bind_columns(\(@$snap[0], @$snap[1], @$snap[2]));
                $csv->print($out_fh, undef);
            } else {
                print_out(@$snap[0], @$snap[1], @$snap[2]);
            }
        }
    }
}

#
# loop through snapshot tree
#
sub get_snapshots {
    my ($ref, $snaptree, $vmname, $snapshots_ref) = @_;
    my $head = " ";
    foreach my $node (@$snaptree) {
        $head = ($ref->value eq $node->snapshot->value) ? " " : " " if (defined $ref);
        #print_out($vmname, $node->name, $node->createTime);
        push(@$snapshots_ref,[$vmname, $node->name, $node->createTime]);
        get_snapshots($ref, $node->childSnapshotList, $vmname, $snapshots_ref);
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

# disable SSL hostname verification for vCenter self-signed certificate
BEGIN {
    $ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;
}

=head1 NAME

snapshotCtrl.pl - Reporting and management script for VM snapshots

=head1 SYNOPSIS

 snapshotCtrl.pl [options]

=head1 DESCRIPTION

This VI Perl command-line utility provides an interface for displaying
a report of VMs and their associated snapshots. If no options are 
specified, the default report is displayed.

=head1 OPTIONS

=over

=item B<vmname>

Optional. The name of the virtual machine. It will be used to select the
virtual machine.

=item B<guestos>

Name of the operating system running on the virtual machine. For example,
if you specify Windows, all virtual machines running Windows are displayed. 

=item B<ipaddress>

Optional. ipaddress of the virtual machine.

=item B<datacenter>

Optional. Name of the  datacenter for the virtual machine(s). Parameters of the
all the virtual machine(s) in a particular datacenter will be displayed

=item B<pool>

Optional. Name of the resource pool of the virtual machine(s). Parameters of 
the all the virtual machine(s) in the given pool will be displayed.

=item B<folder>

Optional. Name of the folder which contains the virtual machines

=item B<powerstatus>

Optional. Powerstatus of the virtual machine: poweredOn or poweredOff. If 
poweron is given, parameters of all the virtual machines which are powered on 
will be displayed

=item B<host>

Optional. Hostname for selecting the virtual machines. Parameters of all
the virtual machines in a particular host will be displayed.

=item B<out>

Optional. Filename in which output is to be displayed. If the file option
is not given then output will be displayed on the console.

=item B<datesort>

Optional. Sort by snapshot created datetime: asc or desc. If this option
is not specified the output will be sorted in ascending order.

=back

=head1 EXAMPLES

Displays a report for the VM named myVM to standard out.

 snapshotCtrl.pl --url https://<ipaddress>:<port>/sdk/webService
             --username myuser --password mypassword --vmname myVM

Displays a report for all VMs in the folder named "Foldername" to stdout.

 snapshotCtrl.pl --url https://<ipaddress>:<port>/sdk/webService
             --username myuser --password mypassword --folder "Foldername" 

Displays a report for all VMs in the "My Datacenter" datacenter, sorts
by snapshot creation date in descending order, and writes the report 
to a CSV file.

 snapshotCtrl.pl --url https://<ipaddress>:<port>/sdk/webService
             --username myuser --password mypassword 
             --datacenter "My Datacenter" --out output.csv

Sample Output

 bbapp-template,Vmwaretools install,2012-06-01 18:14:53
 bbapp-template,snapshot after unbanning,2012-06-15 21:46:20
 bbapp-template,ready for Bb install,2012-08-02 12:26:06
 bbapp-template,bb primary installed,2013-01-15 11:50:22
 bbdev-vd02,workingDevBBInstall,2013-01-16 14:27:47
 bbdevnfs-vd01,before_vment3_tools,2012-09-19 22:24:19
