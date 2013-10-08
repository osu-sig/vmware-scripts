#!/usr/bin/perl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use DateTime;
use DateTime::Format::Strptime;
use DateTime::Format::ISO8601;
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
        help     => "Cutoff period in hours",
        required => 0,
    },
    'nuke' => {
        type     => "",
        variable => "nuke",
        help     => "Delete snaps older than the cutoff period. Script defaults to dry-run mode if this option is not present",
        required => 0,
    },
    'debug' => {
        type     => "",
        variable => "debug",
        help     => "Print verbose debugging output",
        required => 0,
    },
);

Opts::add_options(%opts);
Opts::parse();
Opts::validate();

my $DEBUG = 0;
if (defined (Opts::get_option('debug'))) {
    $DEBUG = 1;
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

    print_out("Deleting snapshots for $datacenter...") if $DEBUG;

    my $cutoff_period = 24;
    if (defined(Opts::get_option('period'))) {
        $cutoff_period = Opts::get_option('period');
    }

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
    printf("Total size of VM properties for datacenter %s: %.2f KB in %.2fs\n", $datacenter, total_size($vm_views)/1024, $elapsed) if $DEBUG;

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

    foreach my $snap (@snapshots) {
        my ($snap_vm, $snap_name, $snap_date, $snap_moref) = @$snap;

        # convert snapshot date from UTC to local timezone
        my $dtsnap = DateTime::Format::ISO8601->parse_datetime($snap_date);
        $dtsnap->set_time_zone("America/Los_Angeles");
        $snap_date = $dtsnap->strftime("%Y-%m-%d %H:%M:%S %Z");

        # skip this snapshot if it is newer than the cutoff date
        my $dtnow = DateTime->now(time_zone=>'local');
        #my $dtcutoff = $dtnow->clone->subtract(hours => $cutoff_period);
        my $dtcutoff = $dtnow->clone->subtract(minutes => 15);
        next if $dtsnap > $dtcutoff;

        # do nothing if nuke flag is not set
        print_out("$snap_vm snapshot $snap_name is older than $cutoff_period hours, deleting...") if $DEBUG;
        next if not defined(Opts::get_option('nuke'));

        my $snap_view = Vim::get_view(mo_ref => $snap_moref);
        my $remove_snap_task = $snap_view->RemoveSnapshot_Task(removeChildren => 'false', consolidate => 'true');
        my $running = 1;
        while ($running) {
            my $remove_snap_task_view = Vim::get_view(mo_ref => $remove_snap_task);
            my $remove_snap_task_state = $remove_snap_task_view->info->state;
            print_out("\t" . $remove_snap_task_view->info->entityName . "->" . $snap_moref->value . ": RemoveSnapshot_Task Status - " . $remove_snap_task_state->{'val'}) if $DEBUG;
            if (($remove_snap_task_state->{'val'} ne "error") && ($remove_snap_task_state->{'val'} ne "success")) {
                $running = 1; # task state is queued or running
            } else {
                $running = 0;
            }
            sleep 5;
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
        push(@$snapshots_ref,[$vmname, $node->name, $node->createTime, $node->snapshot]);
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

This VI Perl command-line utility locates snapshots older than a given period of
time and deletes them.

=head1 OPTIONS

=over

=item B<exclude>

Optional. Datacenter(s) to exclude. Multiple datacenters can be specified in a
quoted, comma-separated list. See examples for usage.

=item B<period>

Optional. Cutoff time period in hours. Defaults to 24.

=item B<nuke>

Optional flag. Delete snapshots that are older than the cutoff time period. NOTE: if
this option is not provided, the script will take no action and produce no output
unless the B<--verbose> flag is given.

=item B<debug>

Optional flag. Print additional debugging output.

=back

=head1 EXAMPLES

Locate all snapshots on this vCenter older than 24 hours and delete them.

  ./nukesnaps.pl --url https://vcenter.url.com --username username
                 --password password --nuke

Locate all snapshots on this vCenter, excluding snaps in the "Dev" and "Dev 2" datacenters,
that are older than 24 hours and delete them.

  ./nukesnaps.pl --url https://vcenter.url.com --username username
                 --password password --exclude "Dev,Dev 2" --nuke

Locate all snapshots on this vCenter older than 72 hours and delete them.

  ./nukesnaps.pl --url https://vcenter.url.com --username username
                 --password password --period 72 --nuke
