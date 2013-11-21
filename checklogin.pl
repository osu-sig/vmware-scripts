#!/usr/bin/perl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use Devel::Size qw(total_size);
use Time::HiRes qw(time);
use Data::Dumper;

use VMware::VIRuntime;
use SIG;

my %opts = (
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

Util::connect();
Util::disconnect();

# disable SSL hostname verification for vCenter self-signed certificate
BEGIN {
    $ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;
}


=head1 NAME

 checklogin.pl - Check logging in to vCenter

=head1 SYNOPSIS

 checklogin.pl [options]

=head1 DESCRIPTION

This VI Perl command-line utility attempts to log in to a vCenter server. If
the attempt is successful, a status code of 0 is returned. If the attempt
fails, a status code of 1 is returned.

=head1 EXAMPLES

  ./checklogin.pl --url https://vcenter.somewhere.com --username someuser
                  --password somepass
