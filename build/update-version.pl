#!/usr/bin/perl

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

use warnings;
use strict;

use POSIX qw(strftime);

# my $svn_info = `svn info -r head` or die "Couldn't get revision: $!";
# my ($rev) = $svn_info =~ /Last Changed Rev: (\d+)/;

my $rev = `git rev-list --count HEAD`;
my $date = strftime "%Y-%m-%d", localtime;

$rev++;

print "New version: $rev $date\n";

open my $in, '<', "PBot/VERSION.pm" or die "Couldn't open VERSION.pm for reading: $!";
my @lines = <$in>;
close $in;

open my $out, '>', "PBot/VERSION.pm" or die "Couldn't open VERSION.pm for writing: $!";

foreach my $text (@lines) {
  $text =~ s/BUILD_NAME\s+=> ".*",/BUILD_NAME     => "PBot",/;
  $text =~ s/BUILD_REVISION\s+=> \d+,/BUILD_REVISION => $rev,/;
  $text =~ s/BUILD_DATE\s+=> ".*",/BUILD_DATE     => "$date",/;

  print $out $text;
}

close $out;
