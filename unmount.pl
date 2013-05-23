#!/usr/bin/perl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

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
    'unmount' => {
        type     => "",
        help     => "Required for the script to take action; otherwise it will display dry run output",
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
);

Opts::add_options(%opts);
Opts::parse();
Opts::validate();


Util::connect();
doIt();
Util::disconnect();

sub doIt {
    my %filter_hash = create_hash(Opts::get_option('ipaddress'),
        Opts::get_option('powerstatus'),
        Opts::get_option('guestos'));

#my ($start, $elapsed);
#$start = time();
    my $vm_views = SIG::AppUtil::VMUtil::get_vms_props('VirtualMachine',
        Opts::get_option ('vmname'),
        Opts::get_option ('datacenter'),
        Opts::get_option ('folder'),
        Opts::get_option ('pool'),
        Opts::get_option ('host'),
        \%filter_hash,
        ['name', 'guest', 'config.changeVersion', 'config.hardware']);
#$elapsed = time() - $start;

#printf("Total size of HostSystem (All Properties): %.2f KB in %.2fs\n", total_size($vm_views)/1024, $elapsed);

    if ($vm_views) {
        foreach (@$vm_views) {
            my $vm_view = $_;
            my ($vm_name, $vm_hostname);

            # parse results
            $vm_name = $vm_view->get_property('name');

            if (defined ($vm_view->get_property('guest.hostName'))) {
                $vm_hostname = $vm_view->get_property('guest.hostName');
            } else {
                $vm_hostname = "unknown";
            }

            my $hardware = $vm_view->get_property('config.hardware');
            my $devices = $hardware->device;
            foreach my $device (@$devices) {
                next unless ($device->isa ('VirtualCdrom'));
                if ($device->connectable->connected == 1) {
                    #print_out($vm_name, $vm_hostname, $vm_toolsStatusPretty, $vm_toolsInstallState);
                    if (defined (Opts::get_option('unmount'))) {
                        print_out("$vm_name -> found connected cdrom device, unmounting...");
                        $device->connectable->connected(0); # disconnect
                        my $spec = VirtualMachineConfigSpec->new(
                            changeVersion => $vm_view->get_property('config.changeVersion'),
                            deviceChange => [
                                VirtualDeviceConfigSpec->new(
                                    operation => VirtualDeviceConfigSpecOperation->new("edit"),
                                    device => $device
                                )
                            ]
                        );

                        my $vm_reconfig_task = $vm_view->ReconfigVM_Task(spec => $spec);
                        my $vm_reconfig_tasks;
                        push(@{$vm_reconfig_tasks}, $vm_reconfig_task);

                        while(!reconfig_tasks_completed($vm_reconfig_tasks)) {
                            sleep 5;
                            check_questions();
                        }

                        last;
                    } else {
                        print_out("$vm_name -> found connected cdrom device");
                    }
                }
            }
        }
    }
}


#
# check for reconfig tasks
#
sub reconfig_tasks_completed {
    my ($reconfig_task_refs) = @_;
    my $reconfig_task_views = Vim::get_views(mo_ref_array => $reconfig_task_refs);
    my $completed = 1;

    foreach (@{$reconfig_task_views}) {
        my $reconfig_task_state = $_->info->state;
        print "\t" . $_->info->entityName . ": ReconfigVM Task Status - " .$reconfig_task_state->{'val'} . "\n";
        if (($reconfig_task_state->{'val'} ne "error") &&($reconfig_task_state->{'val'} ne "success")) {
            $completed = 0;
        }
    }
    return($completed);
}

#
# check if there are outstanding ReconfigVM-related questions
#
sub check_questions {
    my $vm_views = Vim::find_entity_views(view_type => 'VirtualMachine', filter => { 'runtime.question.text' => qr/^msg\.cdromdisconnect\.locked/});

    foreach my $vm_view (@{$vm_views}) {
        if (defined($vm_view->runtime->question->id)) {
            print "\t" . $vm_view->config->name . " has locked CDROM, forcing unlock...\n";
            my $vm_question_info = $vm_view->runtime->question;
            my $vm_question_id = $vm_question_info->id;
            my $vm_question_answer_choice = '0'; # 0 - yes, 1 - no
            $vm_view->AnswerVM(questionId => $vm_question_id, answerChoice => $vm_question_answer_choice);
            sleep 5;
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

#TODO

=head1 NAME

unmount.pl - Disconnect/unmount CD-ROM devices from selected VMs

=head1 SYNOPSIS

 unmount.pl [options]

=head1 DESCRIPTION

This VI Perl command-line utility provides an interface for identifying
VMs with connected CD-ROM devices and disconnecting the identified
devices.

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

=item B<unmount>

Optional. Boolean. Disconnect CD-ROM devices, which includes forcing an
unmount if the guest OS has the CD-ROM locked (mounted). NOTE: if this option
is not specified, the script will produce dry run output.

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

=back

=head1 EXAMPLES

Lists VMs with mounted CD-ROM devices in the "OSU Dev" datacenter and "SIG"
folder to standard out.

 unmount.pl --url https://<ipaddress>:<port>/sdk/webService
            --username myuser --password mypassword --datacenter "OSU Dev"
            --folder "SIG"

Disconnects and unmounts CD-ROM devices from VMs in the "OSU Dev" datacenter
and "SIG" folder.

 unmount.pl --url https://<ipaddress>:<port>/sdk/webService
            --username myuser --password mypassword --datacenter "OSU Dev"
            --folder "SIG" --unmount

Sample Output:

 vi-admin@vMA:~/vmware-scripts[vCenter.server.somedomain]> ./unmount.pl --datacenter "OSU Dev" --folder "SIG"
 vmtoolstest -> found connected cdrom device
 zenoss-vd01 -> found connected cdrom device
 vi-admin@vMA:~/vmware-scripts[vCenter.server.somedomain]> ./unmount.pl --datacenter "OSU Dev" --folder "SIG" --unmount
 vmtoolstest -> found connected cdrom device, unmounting...
         vmtoolstest: ReconfigVM Task Status - running
         vmtoolstest: ReconfigVM Task Status - running
         vmtoolstest has locked CDROM, forcing unlock...
         vmtoolstest: ReconfigVM Task Status - success
 zenoss-vd01 -> found connected cdrom device, unmounting...
         zenoss-vd01: ReconfigVM Task Status - running
         zenoss-vd01 has locked CDROM, forcing unlock...
         zenoss-vd01: ReconfigVM Task Status - success
 vi-admin@vMA:~/vmware-scripts[vCenter.server.somedomain]>
