#!/usr/bin/perl -w
#
# sbrock 2013.02.08 created script


use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../";

use VMware::VIRuntime;
use AppUtil::VMUtil;

$Util::script_version = "0.1";

sub create_hash;
sub get_vm_info;
sub print_log;

my %field_values = (
   'vmname'  => 'vmname',
   'version' => 'version',
   'numCpu'  =>  'numCpu',
   'memorysize' => 'memorysize' ,
   'virtualdisks' => 'virtualdisks',
   'cdromStatus' => 'cdromStatus',
   'template' => 'template',
   'vmPathName'=> 'vmPathName',
   'guestFullName'=> 'guestFullName',
   'guestId' => 'guestId',
   'hostName' => 'hostName',
   'ipAddress' => 'ipAddress',
   'toolsStatus' => 'toolsStatus',
   'toolsVersion' => 'toolsVersion',
   'overallCpuUsage' => 'overallCpuUsage',
   'hostMemoryUsage'=> 'hostMemoryUsage',
   'guestMemoryUsage'=> 'guestMemoryUsage',
   'overallStatus' => 'overallStatus',
);

my %toolsStatus = (
   'toolsNotInstalled' => 'VMware Tools has never been installed or has '
                           .'not run in the virtual machine.',
   'toolsNotRunning' => 'VMware Tools is not running.',
   'toolsOk' => 'VMware Tools is running and the version is current',
   'toolsOld' => 'VMware Tools is running, but the version is not current',
);

my %toolsVersion = (
   '9217' => 'esx/5.1p01',
   '9216' => 'esx/5.1',
   '8482' => '../unsupported/tools/esx/mn_next',
   '8394' => 'esx/5.0u2',
   '8389' => 'esx/5.0p04',
   '8389' => 'esx/5.0p03',
   '8389' => 'esx/5.0u1',
   '8384' => 'esx/5.0p02',
   '8384' => 'esx/5.0',
   '8306' => 'esx/4.1p07',
   '8305' => 'esx/4.1p06',
   '8300' => 'esx/4.1p05',
   '8300' => 'esx/4.1u2',
   '8300' => 'esx/4.1p04',
   '8295' => 'esx/4.1p03',
   '8295' => 'esx/4.1u1',
   '8300' => 'esx/4.1u2',
   '8305' => 'esx/4.1u3',
   '8290' => 'esx/4.1',
   '8289' => 'esx/4.1',
   '8288' => 'esx/4.1',
   '8197' => 'esx/4.0ep09',
   '8196' => 'esx/4.0p12',
   '8196' => 'esx/4.0p11',
   '8196' => 'esx/4.0u4',
   '8196' => 'esx/4.0p10',
   '8196' => 'esx/4.0u3',
   '8195' => 'esx/4.0u2',
   '8194' => 'esx/4.0u1',
   '8193' => 'esx/4.0',
   '8192' => 'esx/4.0',
   '7304' => 'esx/3.5p25',
   '7304' => 'esx/3.5p24',
   '7304' => 'esx/3.5u5',
   '7303' => 'esx/3.5u4',
   '7302' => 'esx/3.5u3',
);

my %overallStatus = (
   'gray' => 'The status is unknown',
   'green' => 'The entity is OK',
   'red' => 'The entity definitely has a problem',
   'yellow' => 'The entity might have a problem',
);

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
   'fields' => {
      type => "=s",
      help => "To specify vm properties for display",
      required => 0,
   },
   'out'=>{
      type => "=s",
      help => "The file name for storing the script output",
      required => 0,
   },
);

Opts::add_options(%opts);
Opts::parse();
Opts::validate(\&validate);

my @valid_properties;
my $filename;

Util::connect();
get_vm_info();
Util::disconnect();


sub get_vm_info {
   my $filename;
   my %filter_hash = create_hash(Opts::get_option('ipaddress'),
                              Opts::get_option('powerstatus'),
                              Opts::get_option('guestos'));

   my $vm_views = VMUtils::get_vms ('VirtualMachine',
                                      Opts::get_option ('vmname'),
                                      Opts::get_option ('datacenter'),
                                      Opts::get_option ('folder'),
                                      Opts::get_option ('pool'),
                                      Opts::get_option ('host'),
                                     %filter_hash);
   if ($vm_views) {
      if (defined (Opts::get_option('out'))) {
         $filename = Opts::get_option('out');
         my $extension = lc substr($filename, length($filename)-4, 4);
         if($extension ne '.xml') {
            $filename =$filename.'.xml';
         }
      }
   foreach (@$vm_views) {
      my $vm_view = $_;
      if (defined (Opts::get_option('out'))) {
         print OUTFILE "<VM>\n";
      }
      else {
         Util::trace(0,"\nInformation of Virtual Machine ". $_->name." \n\n");
      }
      foreach (@valid_properties) {
         if ($_ eq 'vmname') {
            if (defined($vm_view->config) && defined ($vm_view->config->name)) {
               print_log($vm_view->config->name,"Name","Name");
            }
            else {
               print_log("Not Known","Name","Name");
            }
         }
         elsif($_ eq 'version') {
            if (defined($vm_view->config) && defined ($vm_view->config->version)) {
               print_log($vm_view->config->version,"HW Version","HW Version");
            }
            else {
               print_log("Not Known","HW Version","HW Version");
            }
         }
         elsif($_ eq 'numCpu') {
            if (defined ($vm_view->summary->config->numCpu)) {
               print_log($vm_view->summary->config->numCpu,
                                     "noCPU","No. of CPU(s)");
            }
            else {
               print_log("Not Known","noCPU","No. of CPU(s)");
            }
         }
         elsif($_ eq 'memorysize') {
            if (defined ($vm_view->summary->config->memorySizeMB)) {
               print_log($vm_view->summary->config->memorySizeMB,
                                            "memorySize","Memory Size");
            }
            else {
               print_log("Not Known","memorySize","Memory Size");
            }
         }
         elsif($_ eq 'virtualdisks') {
            if (defined ($vm_view->summary->config->numVirtualDisks)) {
               print_log($vm_view->summary->config->numVirtualDisks,
                                           "virtualDisks","Virtual Disks");
            }
            else {
               print_log("Not Known","virtualDisks","Virtual Disks");
            }
         }
         elsif($_ eq 'cdromStatus') {
             #print Dumper $vm_view->config->hardware->device{'VirtualCdrom'};
             my $devices = $vm_view->config->hardware->device;
             foreach my $device (@$devices) {
                 next unless ($device->isa ('VirtualCdrom'));
                 if ($device->connectable->connected == 1) {
                     print_log("connected","CDROM Status","CDROM Status");
                 }
                 else {
                     print_log("not connected","CDROM Status","CDROM Status");
                 }
             }
         }
         elsif($_ eq 'template') {
            if (defined ($vm_view->summary->config->template)) {
               print_log($vm_view->summary->config->template,"template","Template");
            }
            else {
               print_log("Not Known","template","Template");
            }
         }
         elsif($_ eq 'vmPathName') {
            if (defined ($vm_view->summary->config->vmPathName)) {
               print_log($vm_view->summary->config->vmPathName,
                                         "vmPathName","vmPathName");
            }
            else {
               print_log("Not Known","vmPathName","vmPathName");
            }
         }
         elsif($_ eq 'guestFullName') {
            if (defined ($vm_view->summary->guest->guestFullName)) {
               print_log($vm_view->summary->guest->guestFullName,"guestOS","Guest OS");
            }
            else {
               print_log("Not Known","guestOS","Guest OS");
            }
         }
         elsif($_ eq 'guestId') {
            if (defined ($vm_view->summary->guest->guestId)) {
               print_log($vm_view->summary->guest->guestId,"guestId","guestId");
            }
            else {
               print_log("Not Known","guestId","guestId");
            }
         }
         elsif($_ eq 'hostName') {
            if (defined ($vm_view->summary->guest->hostName)) {
               print_log($vm_view->summary->guest->hostName,"hostName","Host name");
            }
            else {
               print_log("Not Known","hostName","Host name");
            }
         }
         elsif($_ eq 'ipAddress') {
            if (defined ($vm_view->summary->guest->ipAddress)) {
               print_log($vm_view->summary->guest->ipAddress,"ipAddress","IP Address");
            }
            else {
               print_log("Not Known","ipAddress","IP Address");
            }
         }
         elsif($_ eq 'toolsStatus') {
            if (defined ($vm_view->summary->guest->toolsStatus)) {
               my $status = $vm_view->summary->guest->toolsStatus->val;
               print_log($toolsStatus{$status},"VMwareTools","VMware Tools");
            } else {
               print_log("Not Known","VMwareTools","VMware Tools");
            }
         }
         elsif($_ eq 'toolsVersion') {
            if (defined ($vm_view->config) && defined ($vm_view->config->tools) && defined ($vm_view->config->tools->toolsVersion)) {
               my $version = $vm_view->config->tools->toolsVersion;
               if ($version ne '0') {
                  print_log($toolsVersion{$version},"Tools Version","Tools Version");
               } else {
                  print_log("not installed","Tools Version","Tools Version");
               }
            } else {
               print_log("Not Known","Tools Version","Tools Version");
            }
         }
         elsif($_ eq 'overallCpuUsage') {
            if (defined ($vm_view->summary->quickStats->overallCpuUsage)) {
               print_log($vm_view->summary->quickStats->overallCpuUsage.
                                           " MHz","cpuUsage","Cpu usage");
            }
            else {
               print_log("Not Known","cpuUsage","Cpu usage");
            }
         }
         elsif($_ eq 'hostMemoryUsage') {
            if (defined ($vm_view->summary->quickStats->hostMemoryUsage)) {
               print_log($vm_view->summary->quickStats->hostMemoryUsage.
                               " MB","hostMemoryUsage","Host memory usage");
            }
            else {
               print_log("Not Known","hostMemoryUsage","Host memory usage");
            }
         }
         elsif($_ eq 'guestMemoryUsage') {
            if (defined ($vm_view->summary->quickStats->guestMemoryUsage)) {
               print_log($vm_view->summary->quickStats->guestMemoryUsage.
                             " MB","guestMemoryUsage","Guest memory usage");
            }
            else {
               print_log("Not Known","guestMemoryUsage","Guest memory usage");
            }
         }
         elsif ($_ eq 'overallStatus') {
            my $overall_status = $vm_view->summary->overallStatus->val;
            print_log($overallStatus{$overall_status},"overallStatus","Overall Status");
         }
         else {
            Util::trace(0, "$_ Not Supported\n");
         }
       }
       if (defined (Opts::get_option('out'))) {
          print OUTFILE  "</VM>\n";
       }
    }
    if (defined (Opts::get_option('out'))) {
       print OUTFILE  "</Root>\n";
    }
  }
}

sub print_log {
   my ($propvalue, $xmlprop, $prop) = @_;
   if (defined (Opts::get_option('out'))) {
      print OUTFILE  "<".$xmlprop.">" . $propvalue
                     ."</".$xmlprop.">\n";
   }
   else {
      Util::trace(0, $prop.":\t\t ".$propvalue." \n");
   }
}

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


# validate the host's fields to be displayed
# ===========================================
sub validate {
   my $valid = 1;
   my @properties_to_add;
   my $length =0;

   if (Opts::option_is_set('fields')) {
      my @filter_Array = split (',', Opts::get_option('fields'));
      foreach (@filter_Array) {
         if ($field_values{ $_ }) {
            $properties_to_add[$length] = $field_values{$_};
            $length++;
         }
         else {
            Util::trace(0, "\nInvalid property specified: " . $_ );
         }
      }
      @valid_properties =  @properties_to_add;
      if (!@valid_properties) {
         $valid = 0;
      }
   }
   else {
      @valid_properties = ("vmname",
                           "version",
                           "numCpu",
                           "memorysize",
                           "virtualdisks",
                           "cdromStatus",
                           "template",
                           "vmPathName",
                           "guestFullName",
                           "guestId",
                           "hostName",
                           "ipAddress",
                           "toolsStatus",
                           "toolsVersion",
                           "overallCpuUsage",
                           "hostMemoryUsage",
                           "guestMemoryUsage",
                           "overallStatus",
                            );
   }
   if (Opts::option_is_set('out')) {
     my $filename = Opts::get_option('out');
     if ((length($filename) == 0)) {
        Util::trace(0, "\n'$filename' Not Valid:\n$@\n");
        $valid = 0;
     }
     else {
        open(OUTFILE, ">$filename");
        if ((length($filename) == 0) ||
          !(-e $filename && -r $filename && -T $filename)) {
           Util::trace(0, "\n'$filename' Not Valid:\n$@\n");
           $valid = 0;
        }
        else {
           print OUTFILE  "<Root>\n";
        }
     }
  }
  return $valid;   
}   

# disable SSL hostname verification for vCenter self-signed certificate
BEGIN {
    $ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;
}

__END__

## bug 217605

=head1 NAME

vmextrainfo.pl - List the properties of the virtual machines.

=head1 SYNOPSIS

 vmextrainfo.pl [options]

=head1 DESCRIPTION

This VI Perl command-line utility provides an interface for displaying
the specified attributes of the virtual machine(s). If none are specified
then the predefined parameters are displayed.

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

Optional. Name of the resource pool of the virtual machine(s).
Parameters of the all the virtual machine(s) in the given pool will be displayed.

=item B<folder>

Optional. Name of the folder which contains the virtual machines

=item B<powerstatus>

Optional. Powerstatus of the virtual machine. If e.g. poweron is given
parameters of all the virtual machines which are powered on will be displayed

=item B<host>

Optional. Hostname for selecting the virtual machines. Parameters of all
the virtual machines in a particular host will be displayed.

=item B<fields>

Optional. Name of the fields whose value is to be displayed. The fields
are: 

  vmname
  version
  numCpu
  memorysize
  virtualdisks
  cdromStatus
  template
  vmPathName
  guestFullName
  guestId
  hostName
  ipAddress
  toolsStatus
  toolsVersion
  overallCpuUsage
  hostMemoryUsage
  guestMemoryUsage
  overallStatus

If the fields option is not specified then all the properties will be
displayed.

=item B<out>

Optional. Filename in which output is to be displayed. If the file option
is not given then output will be displayed on the console.

=back

=head1 EXAMPLES

Displays all the attributes the virtual machine myVM:

 vmextrainfo.pl --url https://<ipaddress>:<port>/sdk/webService
           --username myuser --password mypassword --vmname myVM

Displays all the attributes of all the virtual machines in folder myFolder:

 vmextrainfo.pl --url https://<ipaddress>:<port>/sdk/webService
           --username myuser --password mypassword --folder myFolder

Displays specified attributes of all them virtual machines in pool myPool:

 vmextrainfo.pl --url https://<ipaddress>:<port>/sdk/webService --username myuser --password mypassword --pool myPool
           --fields vmname,numCpu,guestFullName,hostName,ipAddress,toolsStatus,memorysize,hostMemoryUsage,guestMemoryUsage

Send the output in a file

 vmextrainfo.pl --url https://<ipaddress>:<port>/sdk/webService --username myuser
           --password mypassword  --host myHost --out output.xml

Sample Output

 Name:                    007
 No. of CPU(s):           1
 Memory Size:             784
 virtualdisks:            0
 template:                0
 vmPathName:              [storage1] 007/007.vmx
 Guest OS:                Microsoft Windows XP Professional
 Host name:               VM10.abc.info
 IP Address:              127.0.0.1
 VMware Tools:            VMware Tools is running and the version is current
 Host memory usage:       161 MB
 Guest memory usage:      23 MB
 Cpu usage:               45 MHz

=head1 SUPPORTED PLATFORMS

All operations work with VMware VirtualCenter 2.0.1 and VMware ESX 3.0.1.

