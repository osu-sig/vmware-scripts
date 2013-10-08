#!/usr/bin/perl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use YAML::XS qw(LoadFile);
use MIME::Lite::TT;
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

open my $fh, '<', 'config.yml' or die "can't open config file: $!";
my $config = LoadFile($fh);

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
    
    my @borked_vms;

    foreach (@$datacenters) {
        my $d_view = $_;
        my $datacenter_name = $d_view->get_property('name');

        my @excluded = grep($_ eq $datacenter_name, @exclude_datacenters);
        next if (@excluded);

        find_borked_vms($datacenter_name, \@borked_vms);
    }

    my @sorted = sort {((lc $a->[0] cmp lc $b->[0]) || ($a->[1] cmp $b->[1]))} @borked_vms;
    @borked_vms = @sorted;

    if (@borked_vms > 0) {
        send_report(\@borked_vms);
    }
}

#
# find VMs affected by KB article 1007487
# http://kb.vmware.com/selfservice/microsites/search.do?language=en_US&cmd=displayKC&externalId=1007487
#
sub find_borked_vms {
    my ($datacenter, $borked_vms) = @_;
    my %filter_hash;

    #print_out("Scanning $datacenter...");

    my ($start, $elapsed);
    $start = time();
    my $vm_views = SIG::AppUtil::VMUtil::get_vms_props('VirtualMachine',
        undef,
        $datacenter,
        undef,
        undef,
        undef,
        \%filter_hash,
        ['name', 'guest', 'datastore']);

    $elapsed = time() - $start;
    #printf("Total size of VM properties for datacenter %s: %.2f KB in %.2fs\n", $datacenter, total_size($vm_views)/1024, $elapsed);

    my %borked_vms;

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

            next if not defined ($vm_view->datastore);

            my @datastores;
            my $ds_views = Vim::get_views(mo_ref_array => $vm_view->datastore, properties => ['name']);
            foreach my $ds_view (@$ds_views) {
                push(@datastores, $ds_view->name);
            }

            if (@datastores > 1 && 'vmware-templates' ~~ @datastores) {
                push(@$borked_vms, [$datacenter, $vm_name, $vm_hostname]);
            }
        }
    }
}

sub send_report {
    my $borked_vms = shift;

    my %params;
    $params{'borked'} = $borked_vms;

    my %options = (
        INCLUDE_PATH => $FindBin::Bin . '/templates/'
    );

    my $msg = MIME::Lite::TT->new(
        From        =>  $config->{'findBorkedVMs'}->{'email_from'},
        To          =>  $config->{'findBorkedVMs'}->{'email_to'},
        Subject     =>  'VMware: evil experimental hardware edits found',
        Template    =>  'findBorkedVMs.txt.tt',
        TmplOptions =>  \%options,
        TmplParams  =>  \%params,
    );
    
    if (defined (Opts::get_option('noop'))) {
        $msg->stringify;
        $msg->print(\*STDOUT);
    } else {
        $msg->send();
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

findBorkedVMs.pl - Find VMs affected by KB article 1007487

=head1 SYNOPSIS

 findBorkedVMs.pl [options]

=head1 DESCRIPTION

This VI Perl command-line utility identifies VMs in which the experimental
edit hardware feature was used to change the disk size before a VM was deployed
from a template. See KB article 1007487 for details.

The resulting report is sent via email by default. In dry run mode, the report
is printed to stdout.

=head1 CONFIGURATION

Configuration is stored in B<config.yml> under the B<findBorkedVMs> heading.

=over

=item B<email_to>

Email address(es) to send report to. Multiple addresses can be specified in a comma separated list.

=item B<email_from>

Email address that should appear in the "From" field of the report.

=back

=head1 OPTIONS

=over

=item B<exclude>

Optional. Datacenter(s) to exclude. Multiple datacenters can be specified in a quoted, comma-separated list. See examples for usage.

=item B<noop>

Optional. Dry run, take no action.

=back

=head1 EXAMPLES

Find all affected VMs on this vCenter.

  ./findBorkedVMs.pl --url https://vcenter.url.com --username username
                     --password password

Find all affected VMs on this vCenter, excluding the "Dev" and "Dev 2" datacenters.

  ./findBorkedVMs.pl --url https://vcenter.url.com --username username
                     --password password --exclude "Dev,Dev 2"
