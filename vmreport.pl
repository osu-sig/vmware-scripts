#!/usr/bin/perl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use YAML::XS qw(LoadFile);
use Text::CSV_XS;
use MIME::Lite::TT;
use POSIX qw(floor);
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

open my $fh, '<', $FindBin::Bin . '/config.yml' or die "can't open config file: $!";
my $config = LoadFile($fh);

my ($out_fh, $csv);
if (!Opts::option_is_set('noop')) {
    # open tmp file
    open $out_fh, '>', '/tmp/vmreport.csv' or die "can't open tmp file: $!";

    # prepare CSV output
    $csv = Text::CSV_XS->new ({ binary => 1, eol => "\015\012" }) or die "Cannot open CSV: " . Text::CSV_XS->error_diag();
    $csv->print($out_fh, ['vm path', 'vm name', 'vm hostname', 'cpu cores', 'memory', 'disk']);
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
    
    my @vms;

    foreach (@$datacenters) {
        my $d_view = $_;
        my $datacenter_name = $d_view->get_property('name');

        my @excluded = grep($_ eq $datacenter_name, @exclude_datacenters);
        next if (@excluded);

        get_vms($datacenter_name, \@vms);
    }

    my @sorted = sort {((lc $a->[0] cmp lc $b->[0]) || ($a->[1] cmp $b->[1]))} @vms;
    @vms = @sorted;

    if (!Opts::option_is_set('noop')) {
        foreach my $vm (@vms) {
            my ($vm_path, $vm_name, $vm_hostname, $vm_cpu, $vm_mem, $vm_storage) = @$vm;
            $csv->bind_columns(\($vm_path, $vm_name, $vm_hostname, $vm_cpu, $vm_mem, $vm_storage));
            $csv->print($out_fh, undef);
        }
        send_report();
    } else {
        foreach my $vm (@vms) {
            my ($vm_path, $vm_name, $vm_hostname, $vm_cpu, $vm_mem, $vm_storage) = @$vm;
            print_out($vm_path, $vm_name, $vm_hostname, $vm_cpu, $vm_mem, $vm_storage);
        }
    }
}

#
# get VMs in the given datacenter
#
sub get_vms {
    my ($datacenter, $vms) = @_;
    my %filter_hash;

    print_out("Scanning $datacenter...");

    my ($start, $elapsed);
    $start = time();
    my $vm_views = SIG::AppUtil::VMUtil::get_vms_props('VirtualMachine',
        undef,
        $datacenter,
        undef,
        undef,
        undef,
        \%filter_hash,
        ['name', 'parent', 'guest', 'summary.config', 'summary.storage']);

    $elapsed = time() - $start;
    printf("Total size of VM properties for datacenter %s: %.2f KB in %.2fs\n", $datacenter, total_size($vm_views)/1024, $elapsed);

    if ($vm_views) {
        foreach (@$vm_views) {
            my $vm_view = $_;
            my ($vm_name, $vm_hostname, $vm_path, $vm_memory, $vm_cpu, $vm_storage);

            $vm_name = $vm_view->{'name'};
            if (defined $vm_view->{'guest.hostName'}) {
                $vm_hostname = $vm_view->{'guest.hostName'};
            } else {
                $vm_hostname = "unknown";
            }
            if (defined $vm_view->{'summary.config'}->memorySizeMB) {
                $vm_memory = $vm_view->{'summary.config'}->memorySizeMB + 0;
            } else {
                $vm_memory = "unknown";
            }
            if (defined $vm_view->{'summary.config'}->numCpu) {
                $vm_cpu = $vm_view->{'summary.config'}->numCpu + 0;
            } else {
                $vm_cpu = "unknown";
            }
            if (defined $vm_view->{'summary.storage'}) {
                $vm_storage = floor(($vm_view->{'summary.storage'}->committed + $vm_view->{'summary.storage'}->uncommitted) / 1024**2);
            } else {
                $vm_storage = "unknown";
            }
            if (defined $vm_view->parent) {
                $vm_path = get_folderpath($vm_view->parent);
            } else {
                $vm_path = '';
            }

            push(@$vms, [$vm_path, $vm_name, $vm_hostname, $vm_cpu, $vm_memory, $vm_storage]);
        }
    }
}

sub get_folderpath {
    my $folder_ref = shift;
    my $f_view = Vim::get_view(mo_ref => $folder_ref, properties => ['name', 'parent']);
    
    my $path = $f_view->get_property('name');
    if (defined ($f_view->parent)) {
        $path = get_folderpath($f_view->parent) . "/" . $path;
    }
    return $path;
}

sub send_report {
    my %params;
    $params{'message'} = 'VMware VM usage report attached';

    my %options = (
        INCLUDE_PATH => $FindBin::Bin . '/templates/'
    );

    my $msg = MIME::Lite::TT->new(
        From        =>  $config->{'vmreport'}->{'email_from'},
        To          =>  $config->{'vmreport'}->{'email_to'},
        Subject     =>  'VMware usage report',
        Template    =>  'simple.txt.tt',
        TmplOptions =>  \%options,
        TmplParams  =>  \%params,
    );

    $msg->attach(
        Type        => 'text/csv',
        Path        => '/tmp/vmreport.csv',
        Filename    => 'vmreport.csv',
        Disposition => 'attachment'
    );
    
    if (Opts::option_is_set('noop')) {
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

vmreport.pl - Report on all VMs in a given vCenter

=head1 SYNOPSIS

 vmreport.pl [options]

=head1 DESCRIPTION

This VI Perl command-line utility generates a report containing basic statistical
information for all VMs in the given vCenter.

The resulting report is sent via email by default. In dry run mode, the report
is printed to stdout.

=head1 CONFIGURATION

Configuration is stored in B<config.yml> under the B<vmreport> heading.

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

Report on all VMs on this vCenter.

  ./vmreport.pl --url https://vcenter.url.com --username username
                     --password password

Report on all VMs on this vCenter, excluding the "Dev" and "Dev 2" datacenters.

  ./vmreport.pl --url https://vcenter.url.com --username username
                     --password password --exclude "Dev,Dev 2"
