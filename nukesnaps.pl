#!/usr/bin/perl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use Date::Format;
use Date::Parse;
use Devel::Size qw(total_size);
use Time::HiRes qw(time);
use Data::Dumper;

use VMware::VIRuntime;
use SIG;

my %opts = (
    'exclude' => {
        type     => "=s",
        variable => "exclude",
        help     => "Names of datacenters to exclude from this script",
        required => 0,
    },
    'period' => {
        type     => "=i",
        variable => "period",
        help     => "Delete snaps older than this period (in hours)",
        required => 0,
    },
    'noop' => {
        type     => "",
        variable => "noop",
        help     => "Dry run, take no action",
        required => 0,
    },
);

Opts::add_options(%opts);
Opts::parse();
Opts::validate();

# open log file if necessary
my $log_fh;
my $filename = 'logs/nukesnaps.log';
open($log_fh, '>', $filename);
if ((length($filename) == 0) || !(-e $filename && -r $filename && -T $filename)) {
    Util::trace(0, "\n'$filename' Not Valid:\n$@\n");
    die "$filename not valid\n";
} 

Util::connect();
do_it();
Util::disconnect();

#
# this is where the magic happens
#
sub do_it {
    # build array of datacenters to exclude, if any
    my @exclude_datacenters;
    if (defined(Opts::get_option('exclude'))) {
        @exclude_datacenters = split(',', Opts::get_option('exclude'));
    }

    # get datacenters in this vCenter
    my $datacenters = Vim::find_entity_views(view_type => 'Datacenter', properties => ['name']); 
    if (!$datacenters) {
        Util::trace(0, "No datacenters found\n");
        die "No datacenters found\n";
    }
    foreach (@$datacenters) {
        my $d_view = $_;
        my $datacenter_name = $d_view->get_property('name');

        my @excluded = grep($_ eq $datacenter_name, @exclude_datacenters);
        next if (@excluded);

        delete_snapshots($datacenter_name);
    }
}

#
# delete snapshots by datacenter
#
sub delete_snapshots {
    my $datacenter = shift;
    my %filter_hash;

    print_out("Deleting snapshots for $datacenter...");

    my ($start, $elapsed);
    $start = time();
    my $vm_views = SIG::AppUtil::VMUtil::get_vms_props('VirtualMachine',
        undef,
        $datacenter,
        undef,
        undef,
        undef,
        \%filter_hash,
        ['name', 'guest', 'snapshot']);

    $elapsed = time() - $start;
    printf("Total size of VM properties for datacenter %s: %.2f KB in %.2fs\n", $datacenter, total_size($vm_views)/1024, $elapsed);

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
    }
    #print Dumper @snapshots;
    foreach (@snapshots) {
        my $snap = $_;
        my $snapvm = @$snap[0];
        my $snapname = @$snap[1];
        my $snaptime = @$snap[2];
        printf("\t%s %s %s\n", $snapvm, $snapname, $snaptime);
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

# disable SSL hostname verification for vCenter self-signed certificate
BEGIN {
    $ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;
}

=head1 NAME

nukesnaps.pl - Delete VM snapshots older than the specified time period

=head1 SYNOPSIS

 nukesnaps.pl [options]

=head1 DESCRIPTION

TODO

=head1 OPTIONS

=over

=item B<excludeclusters>

Optional. TODO

=item B<period>

Optional. TODO

=item B<noop>

Optional. TODO

=back

=head1 EXAMPLES

