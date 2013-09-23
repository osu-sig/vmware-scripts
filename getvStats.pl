#!/usr/bin/perl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use JSON;
use POSIX;
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
    'outfile' => {
        type      => "=s",
        variable  => "outfile",
        help      => "Filename to write output to" ,
        required => 0,
    },
);

Opts::add_options(%opts);
Opts::parse();
Opts::validate();

if (Opts::option_is_set('outfile')) {
    my $filename = Opts::get_option('outfile');
    if ((length($filename) == 0)) {
        Util::trace(0, "\n'$filename' Not Valid:\n$@\n");
    } else {
        open(OUTFILE, ">$filename");
        if ((length($filename) == 0) ||
            !(-e $filename && -r $filename && -T $filename)) {
            Util::trace(0, "\n'$filename' Not Valid:\n$@\n");
        }
    }
}

my %stat_store;
my $vcenter_uuid;

Util::connect();
doIt();
Util::disconnect();

sub doIt {
    getvCenterStats();
    getVMStats();
    getHostStats();
    getDatastoreStats();
    getClusterStats();

    #print Dumper %stat_store;
    my $encoded = encode_json(\%stat_store);

    if (Opts::option_is_set('outfile')) {
        print OUTFILE $encoded;
    } else {
        print $encoded;
    }
}

sub getvCenterStats {
    print "Retrieving vCenter stats...\n";
    my $sc = Vim::get_service_content();
    my $vcVersion = $sc->about->version;
    my $vcBuild = $sc->about->build;
    my $instanceUuid = $sc->about->instanceUuid;

    my %vc_store;

    $vc_store{'version'} = $vcVersion;
    $vc_store{'build'} = $vcBuild;
    $vc_store{'vmCount'} = 0;
    $vc_store{'hostCount'} = 0;
    $vc_store{'datastoreCount'} = 0;
    $vc_store{'clusterCount'} = 0;
    $stat_store{$instanceUuid} = \%vc_store;

    $vcenter_uuid = $instanceUuid;
}

sub getVMStats {
    print "Retrieving virtual machine stats...\n";
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
        ['name','guest.hostName','summary.config','summary.runtime.powerState','summary.runtime.faultToleranceState','summary.quickStats','summary.storage','config.hardware.device','config.version','config.template']);
    $elapsed = time() - $start;

    printf("Total size of vm properties: %.2f KB in %.2fs\n", total_size($vm_views)/1024, $elapsed);

    if ($vm_views) {
        foreach (@$vm_views) {
            my $vm_view = $_;
            my %vm_store;

            # parse results
            $vm_store{'uuid'} = $vm_view->{'summary.config'}->instanceUuid;
            $vm_store{'name'} = $vm_view->{'name'};
            $vm_store{'hostname'} = (defined $vm_view->{'guest.hostName'} ? $vm_view->{'guest.hostName'} : "unknown");
            $vm_store{'powerState'} = $vm_view->{'summary.runtime.powerState'}->val;
            $vm_store{'guestOS'} = $vm_view->{'summary.config'}->guestFullName;
            $vm_store{'cpuCount'} = $vm_view->{'summary.config'}->numCpu + 0;
            $vm_store{'cpuUsage'} = $vm_view->{'summary.quickStats'}->overallCpuUsage + 0;
            $vm_store{'cpuReservation'} = $vm_view->{'summary.config'}->cpuReservation + 0;
            $vm_store{'memSize'} = $vm_view->{'summary.config'}->memorySizeMB + 0;
            $vm_store{'memUsage'} = $vm_view->{'summary.quickStats'}->guestMemoryUsage + 0;
            $vm_store{'memReservation'} = $vm_view->{'summary.config'}->memoryReservation + 0;
            $vm_store{'nicCount'} = $vm_view->{'summary.config'}->numEthernetCards + 0;
            $vm_store{'diskCount'} = $vm_view->{'summary.config'}->numVirtualDisks + 0;
            $vm_store{'storageSize'} = ($vm_view->{'summary.storage'}->committed + $vm_view->{'summary.storage'}->uncommitted) / 1024^2;
            $vm_store{'storageUsage'} = $vm_view->{'summary.storage'}->committed / 1024^2;
            $vm_store{'uptime'} = ($vm_view->{'summary.quickStats'}->uptimeSeconds ? floor($vm_view->{'summary.quickStats'}->uptimeSeconds / 60) : "N/A");
            $vm_store{'faultToleranceState'} = $vm_view->{'summary.runtime.faultToleranceState'}->val;
            $vm_store{'hardwareVersion'} = $vm_view->{'config.version'};

            $stat_store{$vcenter_uuid}{'vmStats'}{$vm_store{'uuid'}} = \%vm_store;
            $stat_store{$vcenter_uuid}{'vmCount'}++;
        }
    }
}

sub getHostStats {
    print "Retrieving host stats...\n";

    my ($start, $elapsed);
    $start = time();

    my $host_views = Vim::find_entity_views(view_type => 'HostSystem', properties => ['name','config.product','summary.hardware','summary.runtime','summary.quickStats','configManager.storageSystem','datastore','vm'], filter => {'summary.runtime.connectionState' => 'connected'});

    $elapsed = time() - $start;
    printf("Total size of host properties: %.2f KB in %.2fs\n", total_size($host_views)/1024, $elapsed);

    my %lun_store;

    if ($host_views) {
        foreach (@$host_views) {
            my $host_view = $_;

            my %host_store;

            $host_store{'name'} = $host_view->{'name'};
            $host_store{'uuid'} = $host_view->{'summary.hardware'}->uuid;
            $host_store{'powerState'} = $host_view->{'summary.runtime'}->powerState->val;
            $host_store{'version'} = $host_view->{'config.product'}->version;
            $host_store{'build'} = $host_view->{'config.product'}->build;
            $host_store{'vendor'} = $host_view->{'summary.hardware'}->vendor;
            $host_store{'model'} = $host_view->{'summary.hardware'}->model;
            $host_store{'cpuVendor'} = $host_view->{'summary.hardware'}->cpuModel;
            $host_store{'cpuSocket'} = $host_view->{'summary.hardware'}->numCpuPkgs + 0;
            $host_store{'cpuCores'} = $host_view->{'summary.hardware'}->numCpuCores + 0;
            $host_store{'cpuSpeed'} = $host_view->{'summary.hardware'}->cpuMhz + 0;
            $host_store{'cpuUsage'} = $host_view->{'summary.quickStats'}->overallCpuUsage + 0;
            $host_store{'cpuThread'} = $host_view->{'summary.hardware'}->numCpuThreads + 0;
            $host_store{'memSize'} = $host_view->{'summary.hardware'}->memorySize / 1024^2;
            $host_store{'memUsage'} = $host_view->{'summary.quickStats'}->overallMemoryUsage + 0;
            $host_store{'hbaCount'} = $host_view->{'summary.hardware'}->numHBAs + 0;
            $host_store{'nicCount'} = $host_view->{'summary.hardware'}->numNics + 0;
            $host_store{'uptime'} = floor($host_view->{'summary.quickStats'}->uptime / 60);

            $host_store{'datastoreCount'} = scalar(@{Vim::get_views(mo_ref_array => $host_view->{'datastore'}, properties => ['name'])});
            $host_store{'vmCount'} = scalar(@{Vim::get_views(mo_ref_array => $host_view->{'vm'}, properties => ['name'])});

            my $host_storage_system = Vim::get_view(mo_ref => $host_view->{'configManager.storageSystem'});
            my $luns = $host_storage_system->storageDeviceInfo->scsiLun;
            foreach my $lun (@$luns) {
                if ($lun->lunType eq "disk" && $lun->isa('HostScsiDisk')) {
                    my $lunUuid = $lun->canonicalName;
                    if (!defined($lun_store{$lunUuid})) {
                        $lun_store{$lunUuid}{'lunVendor'} = $lun->vendor;
                        $lun_store{$lunUuid}{'lunCapacity'} = $lun->capacity->block * $lun->capacity->blockSize;
                    }
                }
            }

            $stat_store{$vcenter_uuid}{'hostStats'}{$host_store{'uuid'}} = \%host_store;
            $stat_store{$vcenter_uuid}{'hostCount'}++;
        }

        $stat_store{$vcenter_uuid}{'lunCount'} = scalar(keys %lun_store);
        $stat_store{$vcenter_uuid}{'lunStats'} = \%lun_store
    }
}

sub getDatastoreStats {
    print "Retrieving datastore stats...\n";

    my ($start, $elapsed);
    $start = time();

    my $ds_views = Vim::find_entity_views(view_type => 'Datastore', properties => ['summary','vm','info'], filter => {'summary.accessible' => 'true'});

    $elapsed = time() - $start;
    printf("Total size of datastore properties: %.2f KB in %.2fs\n", total_size($ds_views)/1024, $elapsed);

    if ($ds_views) {
        foreach (@$ds_views) {
            my $ds_view = $_;

            my %ds_store;

            $ds_store{'name'} = $ds_view->{'info'}->name;
            $ds_store{'uuid'} = $vcenter_uuid . "-" . $ds_view->{'mo_ref'}->value;
            $ds_store{'type'} = $ds_view->{'summary'}->type;
            $ds_store{'isSSD'} = "false";
            $ds_store{'vmfsVersion'} = "N/A";
            if ($ds_store{'type'} eq "VMFS") {
                $ds_store{'isSSD'} = ($ds_view->{'info'}->vmfs->ssd ? "true" : "false");
                $ds_store{'vmfsVersion'} = $ds_view->{'info'}->vmfs->version;
            }
            $ds_store{'storageSize'} = $ds_view->{'summary'}->capacity / 1024^2;
            $ds_store{'storageAvailable'} = $ds_view->{'summary'}->freeSpace / 1024^2;
            $ds_store{'vmCount'} = scalar(@{Vim::get_views(mo_ref_array => $ds_view->vm, properties => ['name'])});

            $stat_store{$vcenter_uuid}{'datastoreStats'}{$ds_store{'uuid'}} = \%ds_store;
            $stat_store{$vcenter_uuid}{'datastoreCount'}++;
        }
    }
}

sub getClusterStats {
    print "Retrieving cluster stats...\n";

    my ($start, $elapsed);
    $start = time();

    my $cluster_views = Vim::find_entity_views(view_type => 'ClusterComputeResource', properties => ['name','summary','datastore','resourcePool','configurationEx']);

    $elapsed = time() - $start;
    printf("Total size of cluster properties: %.2f KB in %.2fs\n", total_size($cluster_views)/1024, $elapsed);

    if ($cluster_views) {
        foreach (@$cluster_views) {
            my $cluster_view = $_;

            my %cluster_store;

            $cluster_store{'name'} = $cluster_view->{'name'};
            $cluster_store{'uuid'} = $vcenter_uuid . "-" . $cluster_view->{'mo_ref'}->value;
            $cluster_store{'cpuTotal'} = $cluster_view->{'summary'}->totalCpu + 0;
            $cluster_store{'memSize'} = $cluster_view->{'summary'}->totalMemory / 1024^2;
            $cluster_store{'cpuAvailable'} = $cluster_view->{'summary'}->effectiveCpu + 0;
            $cluster_store{'memAvailable'} = $cluster_view->{'summary'}->effectiveMemory + 0;

            $cluster_store{'isHA'} = "N/A";
            $cluster_store{'isDRS'} = "N/A";

            if ($cluster_view->{'configurationEx'}->isa('ClusterConfigInfoEx')) {
                $cluster_store{'isHA'} = ($cluster_view->{'configurationEx'}->dasConfig->enabled ? "true" : "false");
                $cluster_store{'isDRS'} = ($cluster_view->{'configurationEx'}->drsConfig->enabled ? "true" : "false");
            }
            $cluster_store{'hostCount'} = $cluster_view->{'summary'}->numHosts + 0;
            $cluster_store{'datastoreCount'} = scalar(@{Vim::get_views(mo_ref_array => $cluster_view->{'datastore'}, properties => ['name'])});
            $cluster_store{'vmCount'} = scalar(@{Vim::find_entity_views(view_type => 'VirtualMachine', begin_entity => $cluster_view, properties => ['name'])});

            $stat_store{$vcenter_uuid}{'clusterStats'}{$cluster_store{'uuid'}} = \%cluster_store;
            $stat_store{$vcenter_uuid}{'clusterCount'}++;
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


# disable SSL hostname verification for vCenter self-signed certificate
BEGIN {
    $ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;
}


=head1 NAME

 getvStats.pl - collects basic reporting data from vCenter

=head1 SYNOPSIS

 getvStats.pl [options]

=head1 DESCRIPTION

This VI Perl command-line utility collects basic reporting data from
vCenter: VMs, hosts, datastores, and clusters.

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

=item B<outfile>

Optional. Filename to send output to.


=back

