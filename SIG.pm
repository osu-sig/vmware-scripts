#!/usr/bin/perl

use strict;
use warnings;

package SIG::AppUtil::VMUtil;
use parent 'AppUtil::VMUtil';

# This subroutine finds the VMs based on the selection criteria.
# Input Parameters:
# ----------------
# entity        : 'VirtualMachine'
# name          : Virtual machine name
# datacenter    : Datacenter name
# folder        : Folder name
# pool          : Reource pool name
# host          : host name
# filter_hash   : The hash map which contains the filter criteria for virtual machines
#                 based on the machines attributes like guest OS, powerstate etc.
# properties    : Array containing properties to return.
# 
# Output:
# ------
# It returns an array of virtual machines found as per the selection criteria

sub get_vms_props {
    my ($entity, $name, $datacenter, $folder, $pool, $host, $filter_ref, $props_ref) = @_;
    my $begin;
    my $entityViews;
    my %filter = %$filter_ref;
    my @props = @$props_ref;

    if (defined $datacenter) {
        # bug 299888
        my $dc_views = Vim::find_entity_views (view_type => 'Datacenter', filter => {name => $datacenter});

        unless (@$dc_views) {
            Util::trace(0, "Datacenter $datacenter not found.\n");
            return;
        }

        if ($#{$dc_views} != 0) {
            Util::trace(0, "Datacenter <$datacenter> not unique.\n");
            return;
        }
        $begin = shift (@$dc_views);
    } else {
        $begin = Vim::get_service_content()->rootFolder;
    }
    if (defined $folder) {
        my $vm_views = Vim::find_entity_views (view_type => 'Folder', begin_entity => $begin, filter => {name => $folder});
        unless (@$vm_views) {
            Util::trace(0, "Folder <$folder> not found.\n");
            return;
        }
        if ($#{$vm_views} != 0) {
            Util::trace(0, "Folder <$folder> not unique.\n");
            return;
        }
        $begin = shift (@$vm_views);
    }
    if (defined $pool) {
        my $vm_views = Vim::find_entity_views (view_type => 'ResourcePool', begin_entity => $begin, filter => {name => $pool});
        unless (@$vm_views) {
            Util::trace(0, "Resource pool <$pool> not found.\n");
            return;
        }
        if ($#{$vm_views} != 0) {
            Util::trace(0, "Resource pool <$pool> not unique.\n");
            return;
        }
        $begin = shift (@$vm_views);
    }
    if (defined $host) {
        my $hostView = Vim::find_entity_view (view_type => 'HostSystem', filter => {'name' => $host});
        unless ($hostView) {
            Util::trace(0, "Host $host not found.");
            return;
        }
        $filter{'name'} = $name if (defined $name);
        my $vmviews = Vim::find_entity_views (view_type => $entity, begin_entity => $begin, filter => \%filter, properties => \@props);
        my @retViews;
        foreach (@$vmviews) {
            my $host = Vim::get_view(mo_ref => $_->runtime->host);
            my $hostname = $host->name;
            if($hostname eq $hostView->name) {
                push @retViews,$_;
            }
        }
        if (@retViews) {
            return \@retViews;
        } else {
            Util::trace(0, "No Virtual Machine found.\n");
            return;
        }
    } elsif (defined $name) {
        $filter{'name'} = $name if (defined $name);
        $entityViews = Vim::find_entity_views (view_type => $entity, begin_entity => $begin, filter => \%filter, properties => \@props);
        unless (@$entityViews) {
            Util::trace(0, "Virtual Machine $name not found.\n");
            return;
        }
    } else {
        $entityViews = Vim::find_entity_views (view_type => $entity, begin_entity => $begin, filter => $filter_ref, properties => $props_ref);
        #$entityViews = Vim::find_entity_views (view_type => $entity, begin_entity => $begin, properties => ['name', 'guest.hostName']);
        unless (@$entityViews) {
            Util::trace(0, "No Virtual Machine found.\n");
            return;
        }
    }

    if ($entityViews) {return \@$entityViews;}
    else {return 0;}
}

1;
