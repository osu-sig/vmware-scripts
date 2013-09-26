#!/usr/bin/perl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use JSON;
use POSIX qw(floor strftime);
use Time::Local qw(timelocal);
use Devel::Size qw(total_size);
use Time::HiRes qw(time);

use VMware::VIRuntime;
use SIG;

my $logfile = "$FindBin::Bin/logs/getvStats.log";
open my $log_fh, ">", $logfile;

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
        print "Writing to outfile...\n";
        print OUTFILE $encoded;
    } else {
        print $encoded;
    }

    close OUTFILE;
    close $log_fh;

    print "Finished.\n";
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

            if (defined $vm_view->{'summary.config'}->instanceUuid) {
                $vm_store{'uuid'} = $vm_view->{'summary.config'}->instanceUuid;
            } else {
                $vm_store{'uuid'} = '';
                print_log($log_fh, "missing vm uuid");
            }

            if (defined $vm_view->{'name'}) {
                $vm_store{'name'} = $vm_view->{'name'};
            } else {
                $vm_store{'name'} = '';
                print_log($log_fh, $vm_store{'uuid'}, "missing vm name");
            }

            if (defined $vm_view->{'guest.hostName'}) {
                $vm_store{'hostname'} = $vm_view->{'guest.hostName'};
            } else {
                $vm_store{'hostname'} = '';
                # do not print to log because hostname is not a required property
            }

            if (defined $vm_view->{'summary.runtime.powerState'}->val) {
                $vm_store{'powerState'} = $vm_view->{'summary.runtime.powerState'}->val;
            } else {
                $vm_store{'powerState'} = '';
                print_log($log_fh, $vm_store{'uuid'}, $vm_store{'name'}, "missing vm power state");
            }

            if (defined $vm_view->{'summary.config'}->guestFullName) {
                $vm_store{'guestOS'} = $vm_view->{'summary.config'}->guestFullName;
            } else {
                $vm_store{'guestOS'} = '';
                print_log($log_fh, $vm_store{'uuid'}, $vm_store{'name'}, "missing vm guest OS");
            }

            if (defined $vm_view->{'summary.config'}->numCpu) {
                $vm_store{'cpuCount'} = $vm_view->{'summary.config'}->numCpu + 0;
            } else {
                $vm_store{'cpuCount'} = 0;
                print_log($log_fh, $vm_store{'uuid'}, $vm_store{'name'}, "missing vm cpu count");
            }

            if (defined $vm_view->{'summary.quickStats'}->overallCpuUsage) {
                $vm_store{'cpuUsage'} = $vm_view->{'summary.quickStats'}->overallCpuUsage + 0;
            } else {
                $vm_store{'cpuUsage'} = 0;
                print_log($log_fh, $vm_store{'uuid'}, $vm_store{'name'}, "missing vm cpu usage");
            }

            if (defined $vm_view->{'summary.config'}->cpuReservation) {
                $vm_store{'cpuReservation'} = $vm_view->{'summary.config'}->cpuReservation + 0;
            } else {
                $vm_store{'cpuReservation'} = 0;
                print_log($log_fh, $vm_store{'uuid'}, $vm_store{'name'}, "missing vm cpu reservation");
            }

            if (defined $vm_view->{'summary.config'}->memorySizeMB) {
                $vm_store{'memSize'} = $vm_view->{'summary.config'}->memorySizeMB + 0;
            } else {
                $vm_store{'memSize'} = 0;
                print_log($log_fh, $vm_store{'uuid'}, $vm_store{'name'}, "missing vm mem size");
            }

            if (defined $vm_view->{'summary.quickStats'}->guestMemoryUsage) {
                $vm_store{'memUsage'} = $vm_view->{'summary.quickStats'}->guestMemoryUsage + 0;
            } else {
                $vm_store{'memUsage'} = 0;
                print_log($log_fh, $vm_store{'uuid'}, $vm_store{'name'}, "missing vm mem usage");
            }

            if (defined $vm_view->{'summary.config'}->memoryReservation) {
                $vm_store{'memReservation'} = $vm_view->{'summary.config'}->memoryReservation + 0;
            } else {
                $vm_store{'memReservation'} = 0;
                print_log($log_fh, $vm_store{'uuid'}, $vm_store{'name'}, "missing vm mem reservation");
            }

            if (defined $vm_view->{'summary.config'}->numEthernetCards) {
                $vm_store{'nicCount'} = $vm_view->{'summary.config'}->numEthernetCards + 0;
            } else {
                $vm_store{'nicCount'} = 0;
                print_log($log_fh, $vm_store{'uuid'}, $vm_store{'name'}, "missing vm nic count");
            }

            if (defined $vm_view->{'summary.config'}->numVirtualDisks) {
                $vm_store{'diskCount'} = $vm_view->{'summary.config'}->numVirtualDisks + 0;
            } else {
                $vm_store{'diskCount'} = 0;
                print_log($log_fh, $vm_store{'uuid'}, $vm_store{'name'}, "missing vm disk count");
            }

            if (defined $vm_view->{'summary.storage'}) {
                $vm_store{'storageSize'} = ($vm_view->{'summary.storage'}->committed + $vm_view->{'summary.storage'}->uncommitted) / 1024**2;
                $vm_store{'storageUsage'} = $vm_view->{'summary.storage'}->committed / 1024**2;
            } else {
                $vm_store{'storageSize'} = 0;
                $vm_store{'storageUsage'} = 0;
                print_log($log_fh, $vm_store{'uuid'}, $vm_store{'name'}, "missing vm storage values");
            }

            if (defined $vm_view->{'summary.quickStats'}->uptimeSeconds) {
                $vm_store{'uptime'} = ($vm_view->{'summary.quickStats'}->uptimeSeconds ? floor($vm_view->{'summary.quickStats'}->uptimeSeconds / 60) : "N/A");
            } else {
                $vm_store{'uptime'} = 0;
                print_log($log_fh, $vm_store{'uuid'}, $vm_store{'name'}, "missing vm uptime");
            }

            if (defined $vm_view->{'summary.runtime.faultToleranceState'}->val) {
                $vm_store{'faultToleranceState'} = $vm_view->{'summary.runtime.faultToleranceState'}->val;
            } else {
                $vm_store{'faultToleranceState'} = 0;
                print_log($log_fh, $vm_store{'uuid'}, $vm_store{'name'}, "missing vm fault tolerance state");
            }

            if (defined $vm_view->{'config.version'}) {
                $vm_store{'hardwareVersion'} = $vm_view->{'config.version'};
            } else {
                $vm_store{'hardwareVersion'} = 0;
                print_log($log_fh, $vm_store{'uuid'}, $vm_store{'name'}, "missing vm hardware version");
            }

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

            if (defined $host_view->{'summary.hardware'}->uuid) {
                $host_store{'uuid'} = $host_view->{'summary.hardware'}->uuid;
            } else {
                $host_store{'uuid'} = '';
                print_log($log_fh, "missing host uuid");
            }

            if (defined $host_view->{'name'}) {
                $host_store{'name'} = $host_view->{'name'};
            } else {
                $host_store{'name'} = '';
                print_log($log_fh, $host_store{'uuid'}, "missing host name");
            }

            if (defined $host_view->{'summary.runtime'}->powerState->val) {
                $host_store{'powerState'} = $host_view->{'summary.runtime'}->powerState->val;
            } else {
                $host_store{'powerState'} = '';
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host power state");
            }

            if (defined $host_view->{'config.product'}->version) {
                $host_store{'version'} = $host_view->{'config.product'}->version;
            } else {
                $host_store{'version'} = '';
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host version");
            }

            if (defined $host_view->{'config.product'}->build) {
                $host_store{'build'} = $host_view->{'config.product'}->build;
            } else {
                $host_store{'build'} = '';
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host build");
            }

            if (defined $host_view->{'summary.hardware'}->vendor) {
                $host_store{'vendor'} = $host_view->{'summary.hardware'}->vendor;
            } else {
                $host_store{'vendor'} = '';
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host vendor");
            }

            if (defined $host_view->{'summary.hardware'}->model) {
                $host_store{'model'} = $host_view->{'summary.hardware'}->model;
            } else {
                $host_store{'model'} = '';
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host model");
            }

            if (defined $host_view->{'summary.hardware'}->cpuModel) {
                $host_store{'cpuVendor'} = $host_view->{'summary.hardware'}->cpuModel;
            } else {
                $host_store{'cpuVendor'} = '';
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host cpu vendor");
            }

            if (defined $host_view->{'summary.hardware'}->numCpuPkgs) {
                $host_store{'cpuSocket'} = $host_view->{'summary.hardware'}->numCpuPkgs + 0;
            } else {
                $host_store{'cpuSocket'} = 0;
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host cpu socket count");
            }

            if (defined $host_view->{'summary.hardware'}->numCpuCores) {
                $host_store{'cpuCores'} = $host_view->{'summary.hardware'}->numCpuCores + 0;
            } else {
                $host_store{'cpuCores'} = 0;
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host cpu cores");
            }

            if (defined $host_view->{'summary.hardware'}->cpuMhz) {
                $host_store{'cpuSpeed'} = $host_view->{'summary.hardware'}->cpuMhz + 0;
            } else {
                $host_store{'cpuSpeed'} = 0;
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host cpu speed");
            }

            if (defined $host_view->{'summary.quickStats'}->overallCpuUsage) {
                $host_store{'cpuUsage'} = $host_view->{'summary.quickStats'}->overallCpuUsage + 0;
            } else {
                $host_store{'cpuUsage'} = 0;
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host cpu usage");
            }

            if (defined $host_view->{'summary.hardware'}->numCpuThreads) {
                $host_store{'cpuThread'} = $host_view->{'summary.hardware'}->numCpuThreads + 0;
            } else {
                $host_store{'cpuThread'} = 0;
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host cpu thread count");
            }

            if (defined $host_view->{'summary.hardware'}->memorySize) {
                $host_store{'memSize'} = $host_view->{'summary.hardware'}->memorySize / 1024**2;
            } else {
                $host_store{'memSize'} = 0;
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host mem size");
            }

            if (defined $host_view->{'summary.quickStats'}->overallMemoryUsage) {
                $host_store{'memUsage'} = $host_view->{'summary.quickStats'}->overallMemoryUsage + 0;
            } else {
                $host_store{'memUsage'} = 0;
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host mem usage");
            }

            if (defined $host_view->{'summary.hardware'}->numHBAs) {
                $host_store{'hbaCount'} = $host_view->{'summary.hardware'}->numHBAs + 0;
            } else {
                $host_store{'hbaCount'} = 0;
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host hba count");
            }

            if (defined $host_view->{'summary.hardware'}->numNics) {
                $host_store{'nicCount'} = $host_view->{'summary.hardware'}->numNics + 0;
            } else {
                $host_store{'nicCount'} = 0;
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host nic count");
            }

            if (defined $host_view->{'summary.quickStats'}->uptime) {
                $host_store{'uptime'} = floor($host_view->{'summary.quickStats'}->uptime / 60);
            } else {
                $host_store{'uptime'} = 0;
                print_log($log_fh, $host_store{'uuid'}, $host_store{'name'}, "missing host uptime");
            }

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

            if (defined $ds_view->{'mo_ref'}->value) {
                $ds_store{'uuid'} = $vcenter_uuid . "-" . $ds_view->{'mo_ref'}->value;
            } else {
                $ds_store{'uuid'} = '';
                print_log($log_fh, "missing datastore uuid");
            }

            if (defined $ds_view->{'info'}->name) {
                $ds_store{'name'} = $ds_view->{'info'}->name;
            } else {
                $ds_store{'name'} = '';
                print_log($log_fh, $ds_store{'uuid'}, "missing datastore name");
            }

            $ds_store{'isSSD'} = "false";
            $ds_store{'vmfsVersion'} = "N/A";

            if (defined $ds_view->{'summary'}->type) {
                $ds_store{'type'} = $ds_view->{'summary'}->type;

                if ($ds_store{'type'} eq "VMFS") {
                    $ds_store{'isSSD'} = ($ds_view->{'info'}->vmfs->ssd ? "true" : "false");
                    $ds_store{'vmfsVersion'} = $ds_view->{'info'}->vmfs->version;
                }
            } else {
                $ds_store{'type'} = '';
                print_log($log_fh, $ds_store{'uuid'}, $ds_store{'name'}, "missing datastore type");
            }

            if (defined $ds_view->{'summary'}->capacity) {
                $ds_store{'storageSize'} = $ds_view->{'summary'}->capacity / 1024**2;
            } else {
                $ds_store{'storageSize'} = 0;
                print_log($log_fh, $ds_store{'uuid'}, $ds_store{'name'}, "missing datastore size");
            }

            if (defined $ds_view->{'summary'}->freeSpace) {
                $ds_store{'storageAvailable'} = $ds_view->{'summary'}->freeSpace / 1024**2;
            } else {
                $ds_store{'storageAvailable'} = 0;
                print_log($log_fh, $ds_store{'uuid'}, $ds_store{'name'}, "missing datastore available space");
            }

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

            if (defined $cluster_view->{'mo_ref'}->value) {
                $cluster_store{'uuid'} = $vcenter_uuid . "-" . $cluster_view->{'mo_ref'}->value;
            } else {
                $cluster_store{'uuid'} = '';
                print_log($log_fh, "missing cluster uuid");
            }

            if (defined $cluster_view->{'name'}) {
                $cluster_store{'name'} = $cluster_view->{'name'};
            } else {
                $cluster_store{'name'} = '';
                print_log($log_fh, $cluster_store{'uuid'}, "missing cluster name");
            }

            if (defined $cluster_view->{'summary'}->totalCpu) {
                $cluster_store{'cpuTotal'} = $cluster_view->{'summary'}->totalCpu + 0;
            } else {
                $cluster_store{'cpuTotal'} = 0;
                print_log($log_fh, $cluster_store{'uuid'}, $cluster_store{'name'}, "missing cluster cpu total");
            }

            if (defined $cluster_view->{'summary'}->totalMemory) {
                $cluster_store{'memSize'} = $cluster_view->{'summary'}->totalMemory / 1024**2;
            } else {
                $cluster_store{'memSize'} = 0;
                print_log($log_fh, $cluster_store{'uuid'}, $cluster_store{'name'}, "missing cluster mem size");
            }

            if (defined $cluster_view->{'summary'}->effectiveCpu) {
                $cluster_store{'cpuAvailable'} = $cluster_view->{'summary'}->effectiveCpu + 0;
            } else {
                $cluster_store{'cpuAvailable'} = 0;
                print_log($log_fh, $cluster_store{'uuid'}, $cluster_store{'name'}, "missing cluster cpu available");
            }

            if (defined $cluster_view->{'summary'}->effectiveMemory) {
                $cluster_store{'memAvailable'} = $cluster_view->{'summary'}->effectiveMemory + 0;
            } else {
                $cluster_store{'memAvailable'} = 0;
                print_log($log_fh, $cluster_store{'uuid'}, $cluster_store{'name'}, "missing cluster mem available");
            }

            $cluster_store{'isHA'} = "N/A";
            $cluster_store{'isDRS'} = "N/A";

            if ($cluster_view->{'configurationEx'}->isa('ClusterConfigInfoEx')) {
                $cluster_store{'isHA'} = ($cluster_view->{'configurationEx'}->dasConfig->enabled ? "true" : "false");
                $cluster_store{'isDRS'} = ($cluster_view->{'configurationEx'}->drsConfig->enabled ? "true" : "false");
            }

            if (defined $cluster_view->{'summary'}->numHosts) {
                $cluster_store{'hostCount'} = $cluster_view->{'summary'}->numHosts + 0;
            } else {
                $cluster_store{'hostCount'} = 0;
                print_log($log_fh, $cluster_store{'uuid'}, $cluster_store{'name'}, "missing cluster host count");
            }

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
# print to logfile
#
sub print_log {
    my $fh = shift;

    my @time = localtime;
    my $t = strftime "%Y-%m-%d %T", @time;

    if (@_ > 1) {
        return say {$fh} "[$t]" . join(" ", @_);
    } else {
        return say {$fh} "[$t] " . shift(@_);
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

