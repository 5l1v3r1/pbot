# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

package PBot::Logger;
use parent 'PBot::Class';

use warnings; use strict;
use feature 'unicode_strings';

use Scalar::Util qw/openhandle/;
use File::Basename;

sub initialize {
  my ($self, %conf) = @_;
  $self->{logfile} = $conf{filename} // Carp::croak "Missing logfile parameter in " . __FILE__;
  $self->{start} = time;

  my $path = dirname $self->{logfile};
  if (not -d $path) {
    print "Creating new logfile path: $path\n";
    mkdir $path or Carp::croak "Couldn't create logfile path: $!\n";
  }

  open LOGFILE, ">>$self->{logfile}" or Carp::croak "Couldn't open logfile $self->{logfile}: $!\n";
  LOGFILE->autoflush(1);

  $self->{pbot}->{atexit}->register(sub { $self->rotate_log; return; });
  return $self;
}

sub log {
  my ($self, $text) = @_;
  my $time = localtime;
  $text =~ s/(\P{PosixGraph})/my $ch = $1; if ($ch =~ m{[\s]}) { $ch } else { sprintf "\\x%02X", ord $ch }/ge;
  print LOGFILE "$time :: $text" if openhandle *LOGFILE;
  print "$time :: $text";
}

sub rotate_log {
  my ($self) = @_;
  my $time = localtime $self->{start};
  $time =~ s/\s+/_/g;

  # logfile has to be closed first for maximum compatibility with `rename`
  close LOGFILE;
  rename $self->{logfile}, $self->{logfile} . '-' . $time;

  # reopen renamed logfile to resume any needed logging
  open LOGFILE, ">>$self->{logfile}-$time" or Carp::carp "Couldn't re-open logfile $self->{logfile}-$time: $!\n";
  LOGFILE->autoflush(1) if openhandle *LOGFILE;
}

1;
