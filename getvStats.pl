#!/usr/bin/perl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use JSON;
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
$stat_store{'vmCount'} = 0;
$stat_store{'hostCount'} = 0;
$stat_store{'datastoreCount'} = 0;
$stat_store{'clusterCount'} = 0;

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


    $stat_store{'vcVersion'} = $vcVersion;
    $stat_store{'vcBuild'} = $vcBuild;
    $stat_store{'instanceUuid'} = $instanceUuid;
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
            $vm_store{'vmUuid'} = $vm_view->{'summary.config'}->instanceUuid;
            $vm_store{'vmName'} = $vm_view->{'name'};
            $vm_store{'vmHostname'} = (defined $vm_view->{'guest.hostName'} ? $vm_view->{'guest.hostName'} : "unknown");
            $vm_store{'vmState'} = $vm_view->{'summary.runtime.powerState'}->val;
            $vm_store{'vmGuestOS'} = $vm_view->{'summary.config'}->guestFullName;
            $vm_store{'vmCPUCount'} = $vm_view->{'summary.config'}->numCpu;
            $vm_store{'vmCPUUsage'} = $vm_view->{'summary.quickStats'}->overallCpuUsage;
            $vm_store{'vmCPUReservation'} = $vm_view->{'summary.config'}->cpuReservation;
            $vm_store{'vmMemSize'} = $vm_view->{'summary.config'}->memorySizeMB;
            $vm_store{'vmMemUsage'} = $vm_view->{'summary.quickStats'}->guestMemoryUsage;
            $vm_store{'vmMemReservation'} = $vm_view->{'summary.config'}->memoryReservation;
            $vm_store{'vmNicCount'} = $vm_view->{'summary.config'}->numEthernetCards;
            $vm_store{'vmDiskCount'} = $vm_view->{'summary.config'}->numVirtualDisks;
            $vm_store{'vmStorageTotal'} = $vm_view->{'summary.storage'}->committed + $vm_view->{'summary.storage'}->uncommitted;
            $vm_store{'vmStorageUsed'} = $vm_view->{'summary.storage'}->committed;
            $vm_store{'vmUptime'} = ($vm_view->{'summary.quickStats'}->uptimeSeconds ? $vm_view->{'summary.quickStats'}->uptimeSeconds : "N/A");
            $vm_store{'vmFaultToleranceState'} = $vm_view->{'summary.runtime.faultToleranceState'}->val;
            $vm_store{'vmHWVersion'} = $vm_view->{'config.version'};

            $stat_store{'vmStats'}{$vm_store{'vmUuid'}} = \%vm_store;
            $stat_store{'vmCount'}++;
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

            $host_store{'hostName'} = $host_view->{'name'};
            $host_store{'hostUuid'} = $host_view->{'summary.hardware'}->uuid;
            $host_store{'hostState'} = $host_view->{'summary.runtime'}->powerState->val;
            $host_store{'hostVersion'} = $host_view->{'config.product'}->version;
            $host_store{'hostBuild'} = $host_view->{'config.product'}->build;
            $host_store{'hostVendor'} = $host_view->{'summary.hardware'}->vendor;
            $host_store{'hostModel'} = $host_view->{'summary.hardware'}->model;
            $host_store{'hostCPUVendor'} = $host_view->{'summary.hardware'}->cpuModel;
            $host_store{'hostCPUSocket'} = $host_view->{'summary.hardware'}->numCpuPkgs;
            $host_store{'hostCPUCores'} = $host_view->{'summary.hardware'}->numCpuCores;
            $host_store{'hostCPUSpeed'} = $host_view->{'summary.hardware'}->cpuMhz;
            $host_store{'hostCPUUsage'} = $host_view->{'summary.quickStats'}->overallCpuUsage;
            $host_store{'hostCPUThread'} = $host_view->{'summary.hardware'}->numCpuThreads;
            $host_store{'hostMemSize'} = $host_view->{'summary.hardware'}->memorySize;
            $host_store{'hostMemUsage'} = $host_view->{'summary.quickStats'}->overallMemoryUsage;
            $host_store{'hostHBACount'} = $host_view->{'summary.hardware'}->numHBAs;
            $host_store{'hostNicCount'} = $host_view->{'summary.hardware'}->numNics;
            $host_store{'hostUptime'} = $host_view->{'summary.quickStats'}->uptime;

            $host_store{'hostDatastoreCount'} = scalar(@{Vim::get_views(mo_ref_array => $host_view->{'datastore'}, properties => ['name'])});
            $host_store{'hostVMCount'} = scalar(@{Vim::get_views(mo_ref_array => $host_view->{'vm'}, properties => ['name'])});

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

            $stat_store{'hostStats'}{$host_store{'hostUuid'}} = \%host_store;
            $stat_store{'hostCount'}++;
        }

        $stat_store{'lunCount'} = scalar(keys %lun_store);
        $stat_store{'lunStats'} = \%lun_store
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

            $ds_store{'datastoreName'} = $ds_view->{'info'}->name;
            $ds_store{'datastoreUuid'} = $stat_store{'instanceUuid'} . "-" . $ds_view->{'mo_ref'}->value;
            $ds_store{'datastoreType'} = $ds_view->{'summary'}->type;
            $ds_store{'datastoreSSD'} = "false";
            $ds_store{'datastoreVMFSVersion'} = "N/A";
            if ($ds_store{'datastoreType'} eq "VMFS") {
                $ds_store{'datastoreSSD'} = ($ds_view->{'info'}->vmfs->ssd ? "true" : "false");
                $ds_store{'datastoreVMFSVersion'} = $ds_view->{'info'}->vmfs->version;
            }
            $ds_store{'datastoreCapacity'} = $ds_view->{'summary'}->capacity;
            $ds_store{'datastoreFree'} = $ds_view->{'summary'}->freeSpace;
            $ds_store{'datastoreVMs'} = scalar(@{Vim::get_views(mo_ref_array => $ds_view->vm, properties => ['name'])});

            $stat_store{'datastoreStats'}{$ds_store{'datastoreUuid'}} = \%ds_store;
            $stat_store{'datastoreCount'}++;
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

            $cluster_store{'clusterName'} = $cluster_view->{'name'};
            $cluster_store{'clusterUuid'} = $stat_store{'instanceUuid'} . "-" . $cluster_view->{'mo_ref'}->value;
            $cluster_store{'clusterTotalCpu'} = $cluster_view->{'summary'}->totalCpu;
            $cluster_store{'clusterTotalMem'} = $cluster_view->{'summary'}->totalMemory;
            $cluster_store{'clusterAvailableCPU'} = $cluster_view->{'summary'}->effectiveCpu;
            $cluster_store{'clusterAvailableMemory'} = $cluster_view->{'summary'}->effectiveMemory;

            $cluster_store{'clusterHA'} = "N/A";
            $cluster_store{'clusterDRS'} = "N/A";

            if ($cluster_view->{'configurationEx'}->isa('ClusterConfigInfoEx')) {
                $cluster_store{'clusterHA'} = ($cluster_view->{'configurationEx'}->dasConfig->enabled ? "true" : "false");
                $cluster_store{'clusterDRS'} = ($cluster_view->{'configurationEx'}->drsConfig->enabled ? "true" : "false");
            }
            $cluster_store{'clusterHostCount'} = $cluster_view->{'summary'}->numHosts;
            $cluster_store{'clusterDatastoreCount'} = scalar(@{Vim::get_views(mo_ref_array => $cluster_view->{'datastore'}, properties => ['name'])});
            $cluster_store{'clusterVMCount'} = scalar(@{Vim::find_entity_views(view_type => 'VirtualMachine', begin_entity => $cluster_view, properties => ['name'])});

            $stat_store{'clusterStats'}{$cluster_store{'clusterUuid'}} = \%cluster_store;
            $stat_store{'clusterCount'}++;
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

